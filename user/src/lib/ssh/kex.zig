//! M51 SSH2 (#1169, ADR 0025 D2/D6): the SSH-2.0 transport key exchange.
//!
//! This is the client half of RFC 4253's transport handshake, layered over
//! the SSH1 stream adapter (`stream.zig`) and the M47 primitives:
//!
//!   1. **Version exchange** (RFC 4253 §4.2): we send
//!      `SSH-2.0-VirelaiOS_1.0\r\n`; the peer's identification line is read
//!      tolerating leading banner lines (bounded), accepting only `SSH-2.0-*`
//!      and `SSH-1.99-*`.
//!   2. **KEXINIT** (§7.1): one modern suite only (ADR 0025 D2) —
//!      `curve25519-sha256` + the `@libssh.org` alias, `ssh-ed25519`,
//!      `chacha20-poly1305@openssh.com` (so the MAC list is empty — the
//!      cipher is AEAD), `none`. The cookie is 16 bytes from `lib/rng.zig`;
//!      `first_kex_packet_follows` is false. The peer's KEXINIT is parsed
//!      and the intersection negotiated client-preference first; no common
//!      algorithm fails closed (never a fallback).
//!   3. **curve25519-sha256** (RFC 8731): a fresh X25519 ephemeral secret
//!      from `rng`, `SSH_MSG_KEX_ECDH_INIT` carries Q_C; the
//!      `SSH_MSG_KEX_ECDH_REPLY` carries the `ssh-ed25519` host-key blob,
//!      Q_S and the signature blob.
//!   4. **Host-key verification** (RFC 8709): the blob is
//!      `string "ssh-ed25519" || string <32-byte key>`, and the 64-byte
//!      signature must verify over the exchange hash **H** (RFC 4253 §8) —
//!      a wrong key, wrong signature, or a tampered transcript is a hard
//!      refusal (disconnect), never a warning.
//!   5. **KDF** (§7.2): keys come from K and H; for
//!      `chacha20-poly1305@openssh.com` the key is 64 bytes (the two 32-byte
//!      halves `ssh_cipher.zig` consumes) and the IV is empty — the cipher
//!      nonces with the packet sequence number (SSH-P2).
//!   6. **NEWKEYS** (§7.1): send/receive `SSH_MSG_NEWKEYS`, then install the
//!      keys and the continuing sequence numbers. `session_id = H` (the
//!      first KEX) is preserved for SSH3's userauth signature.
//!
//! The transport, entropy, and cipher seams are injected
//! (`stream.Ops`, `Entropy`, `ssh_cipher`), so the whole handshake runs
//! class-A on the host with a scripted peer and pinned keys — no VM.
//!
//! VECTOR PROVENANCE (honest): RFC 8731 defines no full-KEX test vector
//! (and neither does `draft-ietf-curdle-ssh-curves-11`), so the class-A
//! vector pins K from RFC 7748 §6.1 (the published X25519 exchange) and
//! builds a deterministic transcript with fixed ephemeral keys, fixed
//! KEXINITs, and the RFC 8032 §7.1 TEST 1 host key; **H and the derived
//! keys are pinned from an independent reference** (Python hashlib over the
//! same byte encodings) and the host signature is produced by OpenSSL
//! Ed25519, then verified here. No published vector is claimed that was
//! not used.

const std = @import("std");
const wire = @import("wire.zig");
const packet = @import("packet.zig");
const stream = @import("stream.zig");
// Module-mapped deps (the `ui` pattern): the ssh/ subdirectory cannot reach
// `../lib` by relative path when it is itself a unit-test module root, and
// the app build maps the same names.
const crypto = @import("crypto");
const rng = @import("rng");
const sha256 = crypto.sha256;
const x25519 = crypto.x25519;
const ed25519 = crypto.ed25519;
const ssh_cipher = crypto.ssh_cipher;
const ct = crypto.ct;

/// Our identification string, without CR LF (RFC 4253 §4.2).
pub const client_version = "SSH-2.0-VirelaiOS_1.0";

/// RFC 4253 §4.2: the identification string is at most 255 bytes including
/// CR LF.
pub const max_version_line: usize = 255;
/// Bounded banner tolerance: lines before the SSH identification string.
pub const max_banner_lines: usize = 64;
/// The largest peer KEXINIT/ECDH_REPLY payload accepted (they are tiny in
/// practice; this bounds the fixed caller scratch, not a protocol limit).
pub const message_max: usize = 4096;
/// Bounded wait rounds when the transport has no packet yet. A peer that
/// never delivers within the bound is treated as dead (fail closed).
pub const wait_limit: usize = 100_000;

// SSH message numbers (RFC 4253 §12).
pub const msg_disconnect: u8 = 1;
pub const msg_ignore: u8 = 2;
pub const msg_debug: u8 = 4;
pub const msg_kexinit: u8 = 20;
pub const msg_newkeys: u8 = 21;
pub const msg_kex_ecdh_init: u8 = 30;
pub const msg_kex_ecdh_reply: u8 = 31;

// The single negotiated suite (ADR 0025 D2).
pub const kex_curve25519 = "curve25519-sha256";
pub const kex_curve25519_libssh = "curve25519-sha256@libssh.org";
pub const hostkey_ed25519 = "ssh-ed25519";
pub const cipher_chacha20_poly1305 = "chacha20-poly1305@openssh.com";
pub const compression_none = "none";

/// Offered KEX algorithms, client preference order (RFC 4253 §7.1 picks the
/// first client entry the server also offers).
pub const offered_kex = [_][]const u8{ kex_curve25519, kex_curve25519_libssh };
pub const offered_hostkey = [_][]const u8{hostkey_ed25519};
pub const offered_cipher = [_][]const u8{cipher_chacha20_poly1305};
/// Empty: the negotiated cipher is AEAD, so its MAC is the cipher's own tag
/// and RFC 4253 §7.1's MAC negotiation is not used (SSH-P2).
pub const offered_mac = [_][]const u8{};
pub const offered_compression = [_][]const u8{compression_none};
pub const offered_language = [_][]const u8{};

pub const Error = stream.Error || wire.Error || packet.Error || error{
    /// A version line that is over the RFC 4253 §4.2 bound.
    VersionTooLong,
    /// A first `SSH-` line that is not SSH-2.0 / SSH-1.99.
    BadVersion,
    /// More banner lines than the bounded tolerance.
    TooManyBannerLines,
    /// A malformed KEXINIT, or one with trailing bytes.
    BadKexInit,
    /// No common KEX / host-key / cipher / compression algorithm.
    NoCommonKex,
    NoCommonHostKey,
    NoCommonCipher,
    NoCommonCompression,
    /// A malformed KEX_ECDH_REPLY or signature blob.
    BadKexReply,
    /// A host-key blob that is not a well-formed `ssh-ed25519` key.
    BadHostKey,
    /// The host-key signature does not verify over the exchange hash.
    BadSignature,
    /// Q_S is not 32 bytes (RFC 8731 §3).
    BadEphemeralKey,
    /// X25519 produced the all-zero shared secret (RFC 7748 §6.1 MUST).
    WeakSharedSecret,
    /// The entropy seam failed or made no progress.
    Entropy,
    /// The session identifier is not the H this KEX verified.
    SessionIdMismatch,
    /// A message that the KEX state machine does not expect.
    UnexpectedMessage,
    /// The peer sent SSH_MSG_DISCONNECT.
    PeerDisconnect,
};

/// The injected entropy seam (the `netauth.zig` Ops pattern). Production is
/// `sysEntropy()` over ADR 0007 slot 72; tests inject a pinned pool.
pub const Entropy = struct {
    /// Fill `out` and return the number of bytes written, or negative on a
    /// kernel error. A short fill is completed by further calls.
    fill_fn: *const fn (out: []u8) i64,
};

/// The production entropy seam: `lib/rng.zig` over `sys_getrandom` (slot 72).
pub fn sysEntropy() Entropy {
    return .{ .fill_fn = rng.getrandom };
}

/// The algorithms negotiated from a peer KEXINIT (all borrowed from the
/// payload copy the caller keeps).
pub const Negotiated = struct {
    kex: []const u8,
    host_key: []const u8,
    cipher_c2s: []const u8,
    cipher_s2c: []const u8,
    compression_c2s: []const u8,
    compression_s2c: []const u8,
    /// RFC 4253 §7.1: the peer guessed its preferred algorithms and the
    /// first KEX/host-key entries are not what negotiation chose, so its
    /// already-sent next packet must be ignored.
    ignore_next: bool,
};

/// A parsed SSH_MSG_KEXINIT payload. Name-lists borrow `payload`.
pub const KexInit = struct {
    cookie: [16]u8,
    kex: []const u8,
    host_key: []const u8,
    enc_c2s: []const u8,
    enc_s2c: []const u8,
    mac_c2s: []const u8,
    mac_s2c: []const u8,
    comp_c2s: []const u8,
    comp_s2c: []const u8,
    lang_c2s: []const u8,
    lang_s2c: []const u8,
    first_kex_packet_follows: bool,

    /// Strict RFC 4251/4253 parse: fixed field order, every name-list
    /// validated (no empty members), reserved must be zero, and trailing
    /// bytes fail closed.
    pub fn parse(payload: []const u8) Error!KexInit {
        var r = wire.Reader.init(payload);
        if (try r.readByte() != msg_kexinit) return error.BadKexInit;

        if (r.remaining() < 16) return error.BadKexInit;
        var cookie: [16]u8 = undefined;
        @memcpy(&cookie, payload[r.pos..][0..16]);
        r.pos += 16;

        const kex = try r.readNameList();
        try validateList(kex);
        const host_key = try r.readNameList();
        try validateList(host_key);
        const enc_c2s = try r.readNameList();
        try validateList(enc_c2s);
        const enc_s2c = try r.readNameList();
        try validateList(enc_s2c);
        const mac_c2s = try r.readNameList();
        try validateList(mac_c2s);
        const mac_s2c = try r.readNameList();
        try validateList(mac_s2c);
        const comp_c2s = try r.readNameList();
        try validateList(comp_c2s);
        const comp_s2c = try r.readNameList();
        try validateList(comp_s2c);
        const lang_c2s = try r.readNameList();
        try validateList(lang_c2s);
        const lang_s2c = try r.readNameList();
        try validateList(lang_s2c);

        const follows = try r.readBool();
        if (try r.readUint32() != 0) return error.BadKexInit;
        if (r.remaining() != 0) return error.BadKexInit;

        return .{
            .cookie = cookie,
            .kex = kex,
            .host_key = host_key,
            .enc_c2s = enc_c2s,
            .enc_s2c = enc_s2c,
            .mac_c2s = mac_c2s,
            .mac_s2c = mac_s2c,
            .comp_c2s = comp_c2s,
            .comp_s2c = comp_s2c,
            .lang_c2s = lang_c2s,
            .lang_s2c = lang_s2c,
            .first_kex_packet_follows = follows,
        };
    }
};

fn validateList(list: []const u8) Error!void {
    var it = wire.names(list);
    while (try it.next()) |_| {}
}

fn listFirst(list: []const u8) Error!?[]const u8 {
    var it = wire.names(list);
    return try it.next();
}

/// First member of `ours` that the peer's list also offers (RFC 4253 §7.1
/// client-preference order). `null` = no intersection.
fn firstMatch(ours: []const []const u8, peer: []const u8) Error!?[]const u8 {
    for (ours) |o| {
        var it = wire.names(peer);
        while (try it.next()) |name| {
            if (std.mem.eql(u8, name, o)) return o;
        }
    }
    return null;
}

fn negotiate(peer: *const KexInit) Error!Negotiated {
    const kex = (try firstMatch(&offered_kex, peer.kex)) orelse return error.NoCommonKex;
    const host_key = (try firstMatch(&offered_hostkey, peer.host_key)) orelse return error.NoCommonHostKey;
    const cipher_c2s = (try firstMatch(&offered_cipher, peer.enc_c2s)) orelse return error.NoCommonCipher;
    const cipher_s2c = (try firstMatch(&offered_cipher, peer.enc_s2c)) orelse return error.NoCommonCipher;
    const comp_c2s = (try firstMatch(&offered_compression, peer.comp_c2s)) orelse return error.NoCommonCompression;
    const comp_s2c = (try firstMatch(&offered_compression, peer.comp_s2c)) orelse return error.NoCommonCompression;

    var ignore_next = false;
    if (peer.first_kex_packet_follows) {
        const guess_kex = try listFirst(peer.kex);
        const guess_host_key = try listFirst(peer.host_key);
        ignore_next = guess_kex == null or guess_host_key == null or
            !std.mem.eql(u8, guess_kex.?, kex) or
            !std.mem.eql(u8, guess_host_key.?, host_key);
    }

    return .{
        .kex = kex,
        .host_key = host_key,
        .cipher_c2s = cipher_c2s,
        .cipher_s2c = cipher_s2c,
        .compression_c2s = comp_c2s,
        .compression_s2c = comp_s2c,
        .ignore_next = ignore_next,
    };
}

/// One direction of the installed session cipher: the KDF-derived key plus
/// the packet sequence number the AEAD nonces with. The packet layer for
/// encrypted traffic lands with SSH3/SSH4; this is the state they consume.
pub const Cipher = struct {
    key: [ssh_cipher.key_len]u8 = [_]u8{0} ** ssh_cipher.key_len,
    seq: u64 = 0,
    active: bool = false,

    pub fn installed(key: *const [ssh_cipher.key_len]u8, seq: u64) Cipher {
        var c = Cipher{ .active = true };
        @memcpy(&c.key, key);
        c.seq = seq;
        return c;
    }

    /// Encrypt one `length ‖ payload` packet at this direction's next
    /// sequence number, then advance it.
    pub fn seal(self: *Cipher, ciphertext: []u8, tag: *[ssh_cipher.tag_len]u8, plaintext: []const u8) void {
        std.debug.assert(self.active);
        ssh_cipher.seal(ciphertext, tag, plaintext, self.seq, &self.key);
        self.seq +%= 1;
    }

    /// Authenticate and decrypt one packet at this direction's next
    /// sequence number, then advance it. A failed open returns false and
    /// the caller must disconnect (the stream is then unusable anyway).
    pub fn open(self: *Cipher, plaintext: []u8, ciphertext: []const u8, tag: *const [ssh_cipher.tag_len]u8) bool {
        std.debug.assert(self.active);
        const ok = ssh_cipher.open(plaintext, ciphertext, tag, self.seq, &self.key);
        self.seq +%= 1;
        return ok;
    }
};

/// The completed-KEX state handed to SSH3 and the packet layer: H, the
/// session identifier, the verified host key, and the installed ciphers.
pub const Result = struct {
    /// The exchange hash H of this KEX (RFC 4253 §8).
    h: [32]u8,
    /// The SSH session identifier. On the first KEX it IS H; M51 has no
    /// rekey (ADR 0025 D7), so `run` never completes with a different value.
    session_id: [32]u8,
    /// The verified raw `ssh-ed25519` host public key (32 bytes). SSH3
    /// compares it against the `SSH/KNOWN_HOSTS` pin.
    host_key: [32]u8,
    /// Outbound (client→server) cipher, sequence number ready for the next
    /// packet after NEWKEYS.
    send: Cipher,
    /// Inbound (server→client) cipher.
    recv: Cipher,

    /// The SSH3 handoff check: the caller's session identifier must be the
    /// H this KEX verified and installed. A mismatched identifier is
    /// rejected rather than signed over.
    pub fn requireSessionId(self: *const Result, session_id: *const [32]u8) Error!void {
        if (!ct.ctEq(&self.h, session_id) or !ct.ctEq(&self.h, &self.session_id))
            return error.SessionIdMismatch;
    }
};

/// Caller-owned working memory (the SSH1 "static BSS buffer" pattern): one
/// inbound packet at a time, the kept peer KEXINIT payload (needed for H),
/// and the peer's identification line.
pub const Scratch = struct {
    packet: [message_max]u8 = undefined,
    kexinit: [message_max]u8 = undefined,
    version: [max_version_line]u8 = undefined,
};

/// The client KEX state machine. `run` performs the full handshake once;
/// the caller keeps it (or its `Result`) and never reuses the stream before
/// SSH3's userauth.
pub const Kex = struct {
    s: *stream.Stream,
    ent: Entropy,
    scratch: *Scratch,
    complete: bool = false,
    /// Packet sequence numbers, continuing across NEWKEYS (RFC 4253 §6.4).
    send_seq: u64 = 0,
    recv_seq: u64 = 0,

    pub fn init(s: *stream.Stream, ent: Entropy, scratch: *Scratch) Kex {
        return .{ .s = s, .ent = ent, .scratch = scratch };
    }

    /// Run version exchange → KEXINIT → ECDH → host-key verify → KDF →
    /// NEWKEYS. Any error path fails the stream closed (disconnect).
    pub fn run(self: *Kex) Error!Result {
        errdefer self.s.fail();
        if (self.complete) return error.UnexpectedMessage;

        // 1. Version exchange.
        try self.sendVersion();
        const v_s = try self.readVersion(&self.scratch.version);

        // Entropy draw order (documented for deterministic tests):
        // cookie (16), ephemeral secret (32), then per-packet padding in
        // send order (KEXINIT, KEX_ECDH_INIT, NEWKEYS).
        var cookie: [16]u8 = undefined;
        try self.fillRandom(&cookie);
        var ephemeral: [32]u8 = undefined;
        try self.fillRandom(&ephemeral);
        defer ct.wipe(&ephemeral);

        // 2. KEXINIT.
        var i_c_buf: [512]u8 = undefined;
        const i_c = try buildKexInit(&i_c_buf, &cookie);
        try self.sendPacket(i_c);

        const i_s = try self.readKept(&self.scratch.kexinit);
        const peer = KexInit.parse(i_s) catch return error.BadKexInit;
        const neg = try negotiate(&peer);

        // 3. curve25519-sha256 ECDH init.
        var q_c: [32]u8 = undefined;
        x25519.scalarmultBase(&q_c, &ephemeral);

        var init_payload: [1 + 4 + 32]u8 = undefined;
        var iw = wire.Writer.init(&init_payload);
        try iw.writeByte(msg_kex_ecdh_init);
        try iw.writeString(&q_c);
        try self.sendPacket(iw.written());

        // RFC 4253 §7.1: when the peer guessed its algorithm preference and
        // guessed wrong, its guessed next packet must be silently ignored.
        if (neg.ignore_next) _ = try self.readMessage(&self.scratch.packet);

        // 4. ECDH reply: host-key blob, Q_S, signature blob.
        const reply = try self.readMessage(&self.scratch.packet);
        var rr = wire.Reader.init(reply);
        if (try rr.readByte() != msg_kex_ecdh_reply) return error.BadKexReply;
        const k_s = try rr.readString();
        const q_s = try rr.readString();
        const sig_blob = try rr.readString();
        if (rr.remaining() != 0) return error.BadKexReply;

        const host_key = try parseEd25519HostKey(k_s);
        if (q_s.len != 32) return error.BadEphemeralKey;
        var q_s_arr: [32]u8 = undefined;
        @memcpy(&q_s_arr, q_s);

        var k_raw: [32]u8 = undefined;
        defer ct.wipe(&k_raw);
        x25519.scalarmult(&k_raw, &ephemeral, &q_s_arr);
        if (allZero(&k_raw)) return error.WeakSharedSecret;

        // K as the RFC 8731 §3.1 mpint (network-order unsigned integer).
        var k_mpint_buf: [4 + 33]u8 = undefined;
        var kw = wire.Writer.init(&k_mpint_buf);
        try writeMpint(&kw, &k_raw);
        const k_mpint = kw.written();

        // Exchange hash H and host-key signature verification.
        var h: [32]u8 = undefined;
        exchangeHash(&h, client_version, v_s, i_c, i_s, k_s, &q_c, &q_s_arr, k_mpint);
        try verifyHostSignature(sig_blob, &h, &host_key);

        // 5. KDF (RFC 4253 §7.2): 64-byte key, empty IV for the OpenSSH AEAD.
        var key_c2s: [ssh_cipher.key_len]u8 = undefined;
        var key_s2c: [ssh_cipher.key_len]u8 = undefined;
        defer ct.wipe(&key_c2s);
        defer ct.wipe(&key_s2c);
        deriveKey(&key_c2s, k_mpint, &h, 'C', &h); // session_id = H (first KEX)
        deriveKey(&key_s2c, k_mpint, &h, 'D', &h);

        // 6. NEWKEYS, then install the ciphers with the continuing
        // sequence numbers (RFC 4253 §6.4: NEWKEYS is not renumbered).
        try self.sendPacket(&.{msg_newkeys});
        try self.awaitNewKeys();

        self.complete = true;
        return .{
            .h = h,
            .session_id = h,
            .host_key = host_key,
            .send = Cipher.installed(&key_c2s, self.send_seq),
            .recv = Cipher.installed(&key_s2c, self.recv_seq),
        };
    }

    fn sendVersion(self: *Kex) Error!void {
        var line: [client_version.len + 2]u8 = undefined;
        @memcpy(line[0..client_version.len], client_version);
        line[client_version.len] = '\r';
        line[client_version.len + 1] = '\n';
        try self.s.send(&line);
    }

    /// Read the peer identification line, skipping bounded banner lines.
    /// `out` receives the line without CR LF and is returned as a slice.
    fn readVersion(self: *Kex, out: []u8) Error![]const u8 {
        var banners: usize = 0;
        while (true) {
            const raw = try self.readLine(out);
            const line = if (raw.len != 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
            if (std.mem.indexOfScalar(u8, line, 0) != null) return error.BadVersion;
            if (line.len < 4 or !std.mem.eql(u8, line[0..4], "SSH-")) {
                banners += 1;
                if (banners > max_banner_lines) return error.TooManyBannerLines;
                continue;
            }
            if (std.mem.startsWith(u8, line, "SSH-2.0-") or std.mem.startsWith(u8, line, "SSH-1.99-"))
                return line;
            return error.BadVersion;
        }
    }

    /// Read one CR-LF-terminated line into `out`. Both the line bound and
    /// the no-progress bound fail closed. Reads through the SSH1 adapter's
    /// public buffer, before any packet-framed traffic.
    fn readLine(self: *Kex, out: []u8) Error![]const u8 {
        var spins: usize = 0;
        while (true) {
            if (self.s.failed) return error.Closed;
            const avail = self.s.buf[self.s.start..self.s.end];
            if (std.mem.indexOfScalar(u8, avail, '\n')) |nl| {
                const line = avail[0..nl];
                self.s.start += nl + 1;
                if (line.len > out.len) return error.VersionTooLong;
                @memcpy(out[0..line.len], line);
                return out[0..line.len];
            }
            if (avail.len > out.len) return error.VersionTooLong;
            try self.s.drain();
            spins += 1;
            if (spins >= wait_limit) return error.Closed;
        }
    }

    fn fillRandom(self: *Kex, out: []u8) Error!void {
        var off: usize = 0;
        while (off < out.len) {
            const n = self.ent.fill_fn(out[off..]);
            if (n <= 0) return error.Entropy;
            const take: usize = @intCast(n);
            if (take > out.len - off) return error.Entropy;
            off += take;
        }
    }

    fn buildKexInit(out: []u8, cookie: *const [16]u8) Error![]const u8 {
        var w = wire.Writer.init(out);
        try w.writeByte(msg_kexinit);
        for (cookie.*) |b| try w.writeByte(b);
        try w.writeNameList(&offered_kex);
        try w.writeNameList(&offered_hostkey);
        try w.writeNameList(&offered_cipher);
        try w.writeNameList(&offered_cipher);
        try w.writeNameList(&offered_mac);
        try w.writeNameList(&offered_mac);
        try w.writeNameList(&offered_compression);
        try w.writeNameList(&offered_compression);
        try w.writeNameList(&offered_language);
        try w.writeNameList(&offered_language);
        try w.writeBool(false);
        try w.writeUint32(0);
        return w.written();
    }

    /// Frame and send one plaintext packet, padding from entropy.
    fn sendPacket(self: *Kex, payload: []const u8) Error!void {
        const pad_len = packet.paddingLen(payload.len, .plaintext);
        var pad: [16]u8 = undefined;
        try self.fillRandom(pad[0..pad_len]);
        var frame: [512]u8 = undefined;
        const encoded = try packet.encode(&frame, payload, pad[0..pad_len], .plaintext);
        try self.s.send(encoded);
        self.send_seq +%= 1;
    }

    /// Read one complete packet payload into `out`, with a bounded wait.
    fn readPacket(self: *Kex, out: []u8) Error![]const u8 {
        var spins: usize = 0;
        while (true) {
            if (try self.s.parse()) |payload| {
                if (payload.len > out.len) return error.Overlong;
                @memcpy(out[0..payload.len], payload);
                self.recv_seq +%= 1;
                return out[0..payload.len];
            }
            spins += 1;
            if (spins >= wait_limit) return error.Closed;
        }
    }

    /// Read the next packet, skipping SSH_MSG_IGNORE/DEBUG. A disconnect
    /// fails closed; an empty payload is malformed.
    fn readMessage(self: *Kex, out: []u8) Error![]const u8 {
        while (true) {
            const payload = try self.readPacket(out);
            if (payload.len == 0) return error.UnexpectedMessage;
            switch (payload[0]) {
                msg_ignore, msg_debug => continue,
                msg_disconnect => return error.PeerDisconnect,
                else => return payload,
            }
        }
    }

    /// Read the next packet and keep a copy in `keep` (for I_S, which must
    /// survive the reply's read).
    fn readKept(self: *Kex, keep: []u8) Error![]const u8 {
        const payload = try self.readMessage(&self.scratch.packet);
        if (payload.len > keep.len) return error.Overlong;
        @memcpy(keep[0..payload.len], payload);
        return keep[0..payload.len];
    }

    /// Wait out any interleaved IGNORE/DEBUG until the peer's NEWKEYS. Any
    /// other message during this window fails closed.
    fn awaitNewKeys(self: *Kex) Error!void {
        const payload = try self.readMessage(&self.scratch.packet);
        if (payload.len != 1 or payload[0] != msg_newkeys) return error.UnexpectedMessage;
    }
};

/// RFC 4253 §8 exchange hash: SHA-256 over the seven SSH string fields and
/// the mpint K. Public so SSH5's host-side reference can pin the same H.
pub fn exchangeHash(
    out: *[32]u8,
    v_c: []const u8,
    v_s: []const u8,
    i_c: []const u8,
    i_s: []const u8,
    k_s: []const u8,
    q_c: []const u8,
    q_s: []const u8,
    k_mpint: []const u8,
) void {
    var h = sha256.Sha256.init();
    hashString(&h, v_c);
    hashString(&h, v_s);
    hashString(&h, i_c);
    hashString(&h, i_s);
    hashString(&h, k_s);
    hashString(&h, q_c);
    hashString(&h, q_s);
    h.update(k_mpint);
    h.final(out);
}

fn hashString(h: *sha256.Sha256, bytes: []const u8) void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(bytes.len), .big);
    h.update(&len_buf);
    h.update(bytes);
}

/// RFC 4253 §7.2 key derivation. The first block is
/// `HASH(K || H || letter || session_id)`; longer keys extend with
/// `HASH(K || H || key-so-far)`. K and the session identifier enter raw
/// here because `k_mpint` already carries its SSH string length.
pub fn deriveKey(out: []u8, k_mpint: []const u8, h: *const [32]u8, letter: u8, session_id: *const [32]u8) void {
    std.debug.assert(out.len >= sha256.digest_len);
    var first = sha256.Sha256.init();
    first.update(k_mpint);
    first.update(h);
    var letter_buf = [1]u8{letter};
    first.update(&letter_buf);
    first.update(session_id);
    first.final(out[0..sha256.digest_len]);
    var off: usize = sha256.digest_len;
    while (off < out.len) : (off += sha256.digest_len) {
        var next = sha256.Sha256.init();
        next.update(k_mpint);
        next.update(h);
        next.update(out[0..off]);
        next.final(out[off..][0..sha256.digest_len]);
    }
}

/// RFC 8731 §3.1: the 32-byte X25519 output is the network-order unsigned
/// integer K, minimally encoded as an mpint (RFC 4251 §5).
fn writeMpint(w: *wire.Writer, raw: *const [32]u8) Error!void {
    var start: usize = 0;
    while (start < raw.len and raw[start] == 0) start += 1;
    const body = raw[start..];
    if (body.len != 0 and (body[0] & 0x80) != 0) {
        var padded: [33]u8 = undefined;
        padded[0] = 0;
        @memcpy(padded[1 .. 1 + body.len], body);
        try w.writeMpintBytes(padded[0 .. 1 + body.len]);
        return;
    }
    try w.writeMpintBytes(body);
}

/// RFC 8709 §3: `string "ssh-ed25519" || string <32-byte public key>`.
fn parseEd25519HostKey(blob: []const u8) Error![32]u8 {
    var r = wire.Reader.init(blob);
    if (!std.mem.eql(u8, try r.readString(), hostkey_ed25519)) return error.BadHostKey;
    const pubkey = try r.readString();
    if (pubkey.len != ed25519.public_key_len) return error.BadHostKey;
    if (r.remaining() != 0) return error.BadHostKey;
    var out: [32]u8 = undefined;
    @memcpy(&out, pubkey);
    return out;
}

/// RFC 4253 §6.6 / RFC 8709 §3: `string "ssh-ed25519" || string <64-byte
/// signature>`, verified over H. A wrong format, key, or signature is a
/// hard refusal.
fn verifyHostSignature(blob: []const u8, h: *const [32]u8, host_key: *const [32]u8) Error!void {
    var r = wire.Reader.init(blob);
    if (!std.mem.eql(u8, try r.readString(), hostkey_ed25519)) return error.BadSignature;
    const raw_sig = try r.readString();
    if (raw_sig.len != ed25519.signature_len) return error.BadSignature;
    if (r.remaining() != 0) return error.BadSignature;
    var sig: [ed25519.signature_len]u8 = undefined;
    @memcpy(&sig, raw_sig);
    if (!ed25519.verify(&sig, h, host_key)) return error.BadSignature;
}

fn allZero(bytes: []const u8) bool {
    var acc: u8 = 0;
    for (bytes) |b| acc |= b;
    return acc == 0;
}

// ---------------------------------------------------------------------------
// Host tests (class A; injected transport + entropy, scripted peer, no VM)
// ---------------------------------------------------------------------------

/// The pinned deterministic vector. Provenance: K, Q_C, Q_S and the host key
/// are RFC-published (RFC 7748 §6.1, RFC 8032 §7.1 TEST 1); H, the KDF keys
/// and the transcript bytes were computed by an independent reference
/// (Python hashlib) and the signature was produced by OpenSSL Ed25519 over
/// that H. See the module header.
const Vector = struct {
    const v_s_line = "SSH-2.0-OpenSSH_9.6";

    const i_c = hex("14000102030405060708090a0b0c0d0e0f0000002e637572766532353531392d7368613235" ++
        "362c637572766532353531392d736861323536406c69627373682e6f72670000000b7373682d65643235" ++
        "3531390000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d0000001d6368" ++
        "6163686132302d706f6c7931333035406f70656e7373682e636f6d0000000000000000000000046e6f6e" ++
        "65000000046e6f6e6500000000000000000000000000");

    const i_s = hex("14f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff0000002e637572766532353531392d7368613235" ++
        "362c637572766532353531392d736861323536406c69627373682e6f72670000000b7373682d65643235" ++
        "3531390000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d0000001d6368" ++
        "6163686132302d706f6c7931333035406f70656e7373682e636f6d00000017686d61632d736861322d32" ++
        "35362c686d61632d7368613100000017686d61632d736861322d3235362c686d61632d73686131000000" ++
        "046e6f6e65000000046e6f6e6500000000000000000000000000");

    const q_c = hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
    const q_s = hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
    const k_raw = hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");
    const k_mpint = hex("000000204a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");

    const host_seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    const host_pk = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    const k_s = hex("0000000b7373682d6564323535313900000020d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    const sig = hex("c1b0702fd849722c5c05b28966e64bfc7ee94a2b2639f8f1cf1baab0ce4734019e88a52a430d12a8ec94363a340e1dd6fbaa7fdb3bc61b104aba877ba5deca0d");
    const sig_blob = hex("0000000b7373682d6564323535313900000040c1b0702fd849722c5c05b28966e64bfc7ee94a2b2639f8f1cf1baab0ce4734019e88a52a430d12a8ec94363a340e1dd6fbaa7fdb3bc61b104aba877ba5deca0d");

    const h = hex("15c9cacbd36588f06a5189f221597e1e4d13f2f8c1fe9951f62b85afb957136d");
    const key_c2s = hex("205c0be510c7725ad0588a426feab9a7a35f56ef9377fb131b97f146f65ee8ea4ce1f50dd2da22701781fe559f36f83216d87a049c88d00dbeb1ed81a1579a12");
    const key_s2c = hex("dea53158377f125f836602073e10929e33f1efb1112b4947f8b57c3e4c43c099b3591a8bd466ddbffafe013263081f35813b9ba4277d52c72105cce6bb452a4f");

    /// Injected entropy draws in implementation order: cookie (16),
    /// ephemeral secret (RFC 7748 Alice, 32), then padding for KEXINIT (10),
    /// KEX_ECDH_INIT (6) and NEWKEYS (10), all 0x5a.
    const pool = hex("000102030405060708090a0b0c0d0e0f77076d0a7318a57d3c16c17251b26645df4c2f87" ++
        "ebc0992ab177fba51db92c2a" ++
        "5a5a5a5a5a5a5a5a5a5a" ++ // KEXINIT padding
        "5a5a5a5a5a5a" ++ // KEX_ECDH_INIT padding
        "5a5a5a5a5a5a5a5a5a5a"); // NEWKEYS padding
};

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

/// The scripted peer's transport + entropy state, the stream.zig harness
/// pattern (a fully precomputed server script because the transcript is
/// deterministic).
const TestNet = struct {
    var feed: [2048]u8 = undefined;
    var feed_len: usize = 0;
    var feed_pos: usize = 0;
    var tx: [2048]u8 = undefined;
    var tx_len: usize = 0;
    var closed: usize = 0;
    var pool: [256]u8 = undefined;
    var pool_len: usize = 0;
    var pool_pos: usize = 0;

    fn reset() void {
        feed_len = 0;
        feed_pos = 0;
        tx_len = 0;
        closed = 0;
        pool_len = 0;
        pool_pos = 0;
        @memset(&feed, 0);
        @memset(&tx, 0);
    }

    fn setFeed(bytes: []const u8) void {
        @memcpy(feed[0..bytes.len], bytes);
        feed_len = bytes.len;
        feed_pos = 0;
    }

    fn setPool(bytes: []const u8) void {
        @memcpy(pool[0..bytes.len], bytes);
        pool_len = bytes.len;
        pool_pos = 0;
    }

    fn recvFn(out: []u8) i64 {
        const left = feed_len - feed_pos;
        if (left == 0) return 0;
        const take = @min(left, out.len);
        @memcpy(out[0..take], feed[feed_pos .. feed_pos + take]);
        feed_pos += take;
        return @intCast(take);
    }

    fn sendFn(data: []const u8) i64 {
        if (tx_len + data.len > tx.len) return -1;
        @memcpy(tx[tx_len .. tx_len + data.len], data);
        tx_len += data.len;
        return @intCast(data.len);
    }

    fn txPendingFn() bool {
        return false;
    }

    fn closeFn() void {
        closed += 1;
    }

    fn entropyFn(out: []u8) i64 {
        if (pool_pos >= pool_len) return -1;
        const take = @min(pool_len - pool_pos, out.len);
        @memcpy(out[0..take], pool[pool_pos .. pool_pos + take]);
        pool_pos += take;
        return @intCast(take);
    }

    fn ops() stream.Ops {
        return .{ .recv_fn = recvFn, .send_fn = sendFn, .tx_pending_fn = txPendingFn, .close_fn = closeFn };
    }

    fn entropy() Entropy {
        return .{ .fill_fn = entropyFn };
    }
};

/// A growing server-script buffer; frames are padded with 0xaa.
const Script = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,

    fn init() Script {
        return .{};
    }

    fn raw(self: *Script, data: []const u8) void {
        std.debug.assert(self.len + data.len <= self.buf.len);
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn frame(self: *Script, payload: []const u8) void {
        const pad_len = packet.paddingLen(payload.len, .plaintext);
        var pad: [16]u8 = undefined;
        @memset(pad[0..pad_len], 0xaa);
        const encoded = packet.encode(self.buf[self.len..], payload, pad[0..pad_len], .plaintext) catch unreachable;
        self.len += encoded.len;
    }

    fn bytes(self: *Script) []const u8 {
        return self.buf[0..self.len];
    }
};

fn testKexInit(
    out: []u8,
    cookie: [16]u8,
    kex: []const u8,
    host_key: []const u8,
    cipher: []const u8,
    mac: []const u8,
    compression: []const u8,
    guess: bool,
) []const u8 {
    var w = wire.Writer.init(out);
    w.writeByte(msg_kexinit) catch unreachable;
    for (cookie) |b| w.writeByte(b) catch unreachable;
    w.writeString(kex) catch unreachable;
    w.writeString(host_key) catch unreachable;
    w.writeString(cipher) catch unreachable;
    w.writeString(cipher) catch unreachable;
    w.writeString(mac) catch unreachable;
    w.writeString(mac) catch unreachable;
    w.writeString(compression) catch unreachable;
    w.writeString(compression) catch unreachable;
    w.writeString("") catch unreachable;
    w.writeString("") catch unreachable;
    w.writeBool(guess) catch unreachable;
    w.writeUint32(0) catch unreachable;
    return w.written();
}

fn testReply(out: []u8, k_s: []const u8, q_s: []const u8, sig_blob: []const u8) []const u8 {
    var w = wire.Writer.init(out);
    w.writeByte(msg_kex_ecdh_reply) catch unreachable;
    w.writeString(k_s) catch unreachable;
    w.writeString(q_s) catch unreachable;
    w.writeString(sig_blob) catch unreachable;
    return w.written();
}

fn buildVectorScript(script: *Script, i_s: []const u8, sig_blob: []const u8) void {
    script.raw("VirelaiOS test peer ready\r\n");
    script.raw(Vector.v_s_line);
    script.raw("\r\n");
    script.frame(i_s);
    var reply_buf: [256]u8 = undefined;
    script.frame(testReply(&reply_buf, &Vector.k_s, &Vector.q_s, sig_blob));
    script.frame(&.{msg_newkeys});
}

fn runScript() Error!Result {
    var stream_buf: [stream.capacity]u8 = undefined;
    var s = stream.Stream.init(&stream_buf, TestNet.ops());
    var scratch: Scratch = undefined;
    var k = Kex.init(&s, TestNet.entropy(), &scratch);
    return try k.run();
}

test "kex: pinned deterministic transcript — H, KDF keys, NEWKEYS install" {
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    var script = Script.init();
    buildVectorScript(&script, &Vector.i_s, &Vector.sig_blob);
    TestNet.setFeed(script.bytes());

    var res = try runScript();

    // H, session_id, host key and both KDF keys are byte-exact.
    try std.testing.expectEqualSlices(u8, &Vector.h, &res.h);
    try std.testing.expectEqualSlices(u8, &Vector.h, &res.session_id);
    try std.testing.expectEqualSlices(u8, &Vector.host_pk, &res.host_key);
    try std.testing.expectEqualSlices(u8, &Vector.key_c2s, &res.send.key);
    try std.testing.expectEqualSlices(u8, &Vector.key_s2c, &res.recv.key);
    try std.testing.expect(res.send.active and res.recv.active);
    // Three packets sent (KEXINIT, ECDH_INIT, NEWKEYS), three received.
    try std.testing.expectEqual(@as(u64, 3), res.send.seq);
    try std.testing.expectEqual(@as(u64, 3), res.recv.seq);

    // The client transcript is byte-exact: version line + three frames.
    const line = client_version ++ "\r\n";
    try std.testing.expectEqualSlices(u8, line, TestNet.tx[0..line.len]);
    var off: usize = line.len;

    const h1 = try packet.decodeHeader(TestNet.tx[off..], .plaintext);
    try std.testing.expectEqualSlices(u8, &Vector.i_c, try packet.decode(TestNet.tx[off..][0..h1.total()], .plaintext));
    off += h1.total();

    var init_payload: [1 + 4 + 32]u8 = undefined;
    var iw = wire.Writer.init(&init_payload);
    try iw.writeByte(msg_kex_ecdh_init);
    try iw.writeString(&Vector.q_c);
    const h2 = try packet.decodeHeader(TestNet.tx[off..], .plaintext);
    try std.testing.expectEqualSlices(u8, iw.written(), try packet.decode(TestNet.tx[off..][0..h2.total()], .plaintext));
    off += h2.total();

    const h3 = try packet.decodeHeader(TestNet.tx[off..], .plaintext);
    try std.testing.expectEqualSlices(u8, &.{msg_newkeys}, try packet.decode(TestNet.tx[off..][0..h3.total()], .plaintext));

    // The installed send cipher seals at the continuing sequence number
    // with the pinned C→S key.
    var plain = [_]u8{ 0, 0, 0, 4, 1, 0xaa, 0xbb, 0xcc };
    var cipher: [plain.len]u8 = undefined;
    var tag: [ssh_cipher.tag_len]u8 = undefined;
    res.send.seal(&cipher, &tag, &plain);
    var back: [plain.len]u8 = undefined;
    try std.testing.expect(ssh_cipher.open(&back, &cipher, &tag, 3, &Vector.key_c2s));
    try std.testing.expectEqualSlices(u8, &plain, &back);
    try std.testing.expectEqual(@as(u64, 4), res.send.seq);
}

test "kex: a mismatched session_id is rejected by the SSH3 handoff check" {
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    var script = Script.init();
    buildVectorScript(&script, &Vector.i_s, &Vector.sig_blob);
    TestNet.setFeed(script.bytes());

    const res = try runScript();
    try res.requireSessionId(&Vector.h);

    var wrong = Vector.h;
    wrong[0] ^= 1;
    try std.testing.expectError(error.SessionIdMismatch, res.requireSessionId(&wrong));
}

test "kex: a wrong host-key signature is a hard refusal" {
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    var bad_sig = Vector.sig_blob;
    bad_sig[bad_sig.len - 1] ^= 1;
    var script = Script.init();
    buildVectorScript(&script, &Vector.i_s, &bad_sig);
    TestNet.setFeed(script.bytes());

    try std.testing.expectError(error.BadSignature, runScript());
    try std.testing.expectEqual(@as(usize, 1), TestNet.closed);
}

test "kex: a tampered transcript (recomputed H) is rejected" {
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    // Flip one byte of the server KEXINIT cookie: it stays well-formed, but
    // the client's H differs from the signed one.
    var bad_i_s = Vector.i_s;
    bad_i_s[2] ^= 0x40;
    var script = Script.init();
    buildVectorScript(&script, &bad_i_s, &Vector.sig_blob);
    TestNet.setFeed(script.bytes());

    try std.testing.expectError(error.BadSignature, runScript());
    try std.testing.expectEqual(@as(usize, 1), TestNet.closed);
}

test "kex: an unnegotiable peer fails closed (kex, host key, cipher)" {
    // KEX: only a group exchange the client does not offer.
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    var i_s_buf: [512]u8 = undefined;
    const i_s = testKexInit(&i_s_buf, [_]u8{0x11} ** 16, "diffie-hellman-group14-sha256", hostkey_ed25519, cipher_chacha20_poly1305, "", compression_none, false);
    var script = Script.init();
    buildVectorScript(&script, i_s, &Vector.sig_blob);
    TestNet.setFeed(script.bytes());
    try std.testing.expectError(error.NoCommonKex, runScript());
    try std.testing.expectEqual(@as(usize, 1), TestNet.closed);

    // Host key: only ssh-rsa.
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    const i_s2 = testKexInit(&i_s_buf, [_]u8{0x22} ** 16, kex_curve25519, "rsa-sha2-256", cipher_chacha20_poly1305, "", compression_none, false);
    var script2 = Script.init();
    buildVectorScript(&script2, i_s2, &Vector.sig_blob);
    TestNet.setFeed(script2.bytes());
    try std.testing.expectError(error.NoCommonHostKey, runScript());
    try std.testing.expectEqual(@as(usize, 1), TestNet.closed);

    // Cipher: only an AES mode.
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    const i_s3 = testKexInit(&i_s_buf, [_]u8{0x33} ** 16, kex_curve25519, hostkey_ed25519, "aes256-ctr", "", compression_none, false);
    var script3 = Script.init();
    buildVectorScript(&script3, i_s3, &Vector.sig_blob);
    TestNet.setFeed(script3.bytes());
    try std.testing.expectError(error.NoCommonCipher, runScript());
    try std.testing.expectEqual(@as(usize, 1), TestNet.closed);
}

test "kex: an oversize packet fails closed through the SSH1 layer" {
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    var script = Script.init();
    script.raw(Vector.v_s_line);
    script.raw("\r\n");
    // A declared total over the fixed cap: the stream layer must fail closed.
    script.raw(&.{ 0xff, 0xff, 0xff, 0xff, 4 });
    TestNet.setFeed(script.bytes());

    try std.testing.expectError(error.Overlong, runScript());
    try std.testing.expectEqual(@as(usize, 1), TestNet.closed);
}

test "kex: trailing garbage in a KEXINIT fails closed" {
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    var padded_i_s: [Vector.i_s.len + 1]u8 = undefined;
    @memcpy(padded_i_s[0..Vector.i_s.len], &Vector.i_s);
    padded_i_s[Vector.i_s.len] = 0x00;
    var script = Script.init();
    script.raw(Vector.v_s_line);
    script.raw("\r\n");
    script.frame(&padded_i_s);
    TestNet.setFeed(script.bytes());

    try std.testing.expectError(error.BadKexInit, runScript());
    try std.testing.expectEqual(@as(usize, 1), TestNet.closed);
}

test "kex: banner lines are skipped; SSH-1.99 peers are accepted" {
    const v_s_199 = "SSH-1.99-OpenSSH_7.6";
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    var h_199: [32]u8 = undefined;
    exchangeHash(&h_199, client_version, v_s_199, &Vector.i_c, &Vector.i_s, &Vector.k_s, &Vector.q_c, &Vector.q_s, &Vector.k_mpint);
    var sig_199: [64]u8 = undefined;
    ed25519.sign(&sig_199, &h_199, &Vector.host_seed);
    var sig_blob_buf: [4 + 11 + 4 + 64]u8 = undefined;
    var sw = wire.Writer.init(&sig_blob_buf);
    try sw.writeString(hostkey_ed25519);
    try sw.writeString(&sig_199);

    var script = Script.init();
    script.raw("Welcome to the deterministic test peer\r\n");
    script.raw("this line is a banner, not a version\r\n");
    script.raw(v_s_199);
    script.raw("\r\n");
    script.frame(&Vector.i_s);
    var reply_buf: [256]u8 = undefined;
    script.frame(testReply(&reply_buf, &Vector.k_s, &Vector.q_s, sw.written()));
    script.frame(&.{msg_newkeys});
    TestNet.setFeed(script.bytes());

    const res = try runScript();
    try std.testing.expectEqualSlices(u8, &Vector.host_pk, &res.host_key);
    try std.testing.expectEqualSlices(u8, &h_199, &res.h);
}

test "kex: a non-2.0/1.99 version line is refused" {
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    var script = Script.init();
    script.raw("SSH-1.5-old-peer\r\n");
    script.raw(Vector.v_s_line);
    script.raw("\r\n");
    TestNet.setFeed(script.bytes());

    try std.testing.expectError(error.BadVersion, runScript());
    try std.testing.expectEqual(@as(usize, 1), TestNet.closed);
}

test "kex: the libssh.org alias negotiates when it is the only offer" {
    var i_s_buf: [512]u8 = undefined;
    const i_s = testKexInit(&i_s_buf, [_]u8{0x44} ** 16, kex_curve25519_libssh, hostkey_ed25519, cipher_chacha20_poly1305, "", compression_none, false);
    var h_alias: [32]u8 = undefined;
    exchangeHash(&h_alias, client_version, Vector.v_s_line, &Vector.i_c, i_s, &Vector.k_s, &Vector.q_c, &Vector.q_s, &Vector.k_mpint);
    var sig_alias: [64]u8 = undefined;
    ed25519.sign(&sig_alias, &h_alias, &Vector.host_seed);
    var sig_blob_buf: [4 + 11 + 4 + 64]u8 = undefined;
    var sw = wire.Writer.init(&sig_blob_buf);
    try sw.writeString(hostkey_ed25519);
    try sw.writeString(&sig_alias);

    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    var script = Script.init();
    script.raw(Vector.v_s_line);
    script.raw("\r\n");
    script.frame(i_s);
    var reply_buf: [256]u8 = undefined;
    script.frame(testReply(&reply_buf, &Vector.k_s, &Vector.q_s, sw.written()));
    script.frame(&.{msg_newkeys});
    TestNet.setFeed(script.bytes());

    const res = try runScript();
    try std.testing.expectEqualSlices(u8, &h_alias, &res.h);
    try std.testing.expectEqualSlices(u8, &Vector.host_pk, &res.host_key);
}

test "kex: a wrong first_kex_packet_follows guess skips one packet" {
    var i_s_buf: [512]u8 = undefined;
    // Peer's first KEX is the alias, but negotiation picks the client-first
    // curve25519-sha256, so its guessed next packet must be ignored.
    const i_s = testKexInit(&i_s_buf, [_]u8{0x55} ** 16, kex_curve25519_libssh ++ "," ++ kex_curve25519, hostkey_ed25519, cipher_chacha20_poly1305, "", compression_none, true);
    var h_guess: [32]u8 = undefined;
    exchangeHash(&h_guess, client_version, Vector.v_s_line, &Vector.i_c, i_s, &Vector.k_s, &Vector.q_c, &Vector.q_s, &Vector.k_mpint);
    var sig_guess: [64]u8 = undefined;
    ed25519.sign(&sig_guess, &h_guess, &Vector.host_seed);
    var sig_blob_buf: [4 + 11 + 4 + 64]u8 = undefined;
    var sw = wire.Writer.init(&sig_blob_buf);
    try sw.writeString(hostkey_ed25519);
    try sw.writeString(&sig_guess);

    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    var script = Script.init();
    script.raw(Vector.v_s_line);
    script.raw("\r\n");
    script.frame(i_s);
    script.frame(&.{msg_kex_ecdh_init}); // the wrong guess: must be ignored
    var reply_buf: [256]u8 = undefined;
    script.frame(testReply(&reply_buf, &Vector.k_s, &Vector.q_s, sw.written()));
    script.frame(&.{msg_newkeys});
    TestNet.setFeed(script.bytes());

    const res = try runScript();
    try std.testing.expectEqualSlices(u8, &h_guess, &res.h);
    try std.testing.expectEqualSlices(u8, &Vector.host_pk, &res.host_key);
}

test "kex: a correct first_kex_packet_follows guess does not skip" {
    var i_s_buf: [512]u8 = undefined;
    const i_s = testKexInit(&i_s_buf, [_]u8{0x66} ** 16, kex_curve25519 ++ "," ++ kex_curve25519_libssh, hostkey_ed25519, cipher_chacha20_poly1305, "", compression_none, true);

    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    var script = Script.init();
    script.raw(Vector.v_s_line);
    script.raw("\r\n");
    script.frame(i_s);
    // The next packet is treated as ECDH_REPLY (the guess was right): a
    // KEXINIT there is malformed and must not be skipped.
    script.frame(i_s);
    TestNet.setFeed(script.bytes());

    try std.testing.expectError(error.BadKexReply, runScript());
    try std.testing.expectEqual(@as(usize, 1), TestNet.closed);
}

test "kex: malformed host key and Q_S fail closed" {
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    // K_S with the wrong key type.
    var bad_k_s_buf: [128]u8 = undefined;
    var kw = wire.Writer.init(&bad_k_s_buf);
    try kw.writeString("ssh-rsa");
    try kw.writeString(&Vector.host_pk);
    var script = Script.init();
    script.raw(Vector.v_s_line);
    script.raw("\r\n");
    script.frame(&Vector.i_s);
    var reply_buf: [256]u8 = undefined;
    script.frame(testReply(&reply_buf, kw.written(), &Vector.q_s, &Vector.sig_blob));
    script.frame(&.{msg_newkeys});
    TestNet.setFeed(script.bytes());
    try std.testing.expectError(error.BadHostKey, runScript());
    try std.testing.expectEqual(@as(usize, 1), TestNet.closed);

    // Q_S of the wrong length.
    TestNet.reset();
    TestNet.setPool(&Vector.pool);
    const short_q_s = [_]u8{1} ** 31;
    var script2 = Script.init();
    script2.raw(Vector.v_s_line);
    script2.raw("\r\n");
    script2.frame(&Vector.i_s);
    var reply_buf2: [256]u8 = undefined;
    script2.frame(testReply(&reply_buf2, &Vector.k_s, &short_q_s, &Vector.sig_blob));
    script2.frame(&.{msg_newkeys});
    TestNet.setFeed(script2.bytes());
    try std.testing.expectError(error.BadEphemeralKey, runScript());
    try std.testing.expectEqual(@as(usize, 1), TestNet.closed);
}

test "kex: entropy failure fails closed" {
    TestNet.reset();
    // No pool: the first fill returns negative.
    var script = Script.init();
    buildVectorScript(&script, &Vector.i_s, &Vector.sig_blob);
    TestNet.setFeed(script.bytes());

    try std.testing.expectError(error.Entropy, runScript());
    try std.testing.expectEqual(@as(usize, 1), TestNet.closed);
}
