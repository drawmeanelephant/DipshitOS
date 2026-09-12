//! M51 SSH4 (#1171, ADR 0025 D6/D7): the encrypted SSH packet transport.
//!
//! This is the piece SSH3 deliberately deferred (`userauth.zig`'s
//! PRODUCTION BOUNDARY note): after `SSH_MSG_NEWKEYS`, every SSH packet is an
//! RFC 4253 §6 frame (`uint32 packet_length || payload || padding`) carried
//! as the OpenSSH AEAD wire shape
//!
//! ```
//! enc_length(4) || enc_payload(packet_length) || tag(16)
//! ```
//!
//! - **Send**: `packet.encode` frames the payload with entropy padding, then
//!   `ssh_cipher.seal` encrypts `length ‖ rest` in place (K_1 for the length,
//!   K_2 for the payload) and tags it; the sealed frame + tag go out as one
//!   `stream.send` (which paces ≤192-byte segments).
//! - **Receive**: take 4 bytes, `ssh_cipher.decryptLength` to learn
//!   `packet_length`, read that many + 16 tag bytes, `ssh_cipher.open`
//!   (tag-verified before any plaintext is trusted), then `packet.decode`.
//!
//! **Sequence numbers continue across NEWKEYS** (RFC 4253 §6.4): the caller
//! seeds the two `Cipher`s from `kex.Result.send/recv`, whose `seq` counts the
//! plaintext KEX packets (KEXINIT, ECDH_INIT, NEWKEYS = 3). This module never
//! resets a sequence number; `kex.zig`'s pinned class-A test asserts the
//! handoff value.
//!
//! **No rekey (ADR 0025 D7)**: the transport counts encrypted bytes and
//! packets in both directions and, at the documented bound below, sends
//! `SSH_MSG_DISCONNECT` (reason 11 `BY_APPLICATION`) and closes instead of
//! rekeying. A DISCONNECT from either side ends the session cleanly.
//!
//! HONEST LIMITS: `recvPayload` decrypts in place inside the `stream.zig`
//! buffer (the ChaCha20 stream XOR is byte-local, so an aliased in/out slice
//! is safe), which is why the stream buffer must be `packet.max_total + tag`
//! bytes — the 16 tag bytes ride outside the RFC 4253 total. A packet over the
//! cap or a tag mismatch fails closed (`stream.fail()` + TCP close), never
//! truncate-and-continue.

const std = @import("std");
const stream = @import("stream.zig");
const packet = @import("packet.zig");
const crypto = @import("crypto");
const ssh_cipher = crypto.ssh_cipher;

pub const tag_len = ssh_cipher.tag_len;
pub const key_len = ssh_cipher.key_len;

/// The documented M51 no-rekey bound (ADR 0025 D7): whichever comes first,
/// the session sends DISCONNECT at ~1 GiB of encrypted traffic per direction
/// or 2^20 packets per direction. Class-A tests shrink `Limits` to hit both.
pub const default_max_bytes: u64 = 1 << 30;
pub const default_max_packets: u64 = 1 << 20;

/// RFC 4253 §11.1 reason 11 `SSH_DISCONNECT_BY_APPLICATION`.
pub const disconnect_by_application: u32 = 11;
/// The reason text on a local policy disconnect; no version/secret detail.
pub const bound_description = "M51 no-rekey bound reached; reconnect to continue";
pub const desc_max: usize = 128;

pub const Error = packet.Error || error{
    /// The underlying stream failed or the pacing/wait bound was exhausted.
    Transport,
    /// A malformed frame or a tag mismatch (fail closed, disconnect).
    BadPacket,
    /// The padding entropy source failed or made no progress.
    Entropy,
    /// The peer sent SSH_MSG_DISCONNECT (a clean end).
    PeerDisconnect,
    /// The no-rekey byte/packet bound was reached: DISCONNECT was sent.
    NoRekey,
};

/// The injected entropy seam (the `kex.zig`/`userauth.zig` pattern).
pub const Entropy = struct {
    fill_fn: *const fn (out: []u8) i64,
};

/// The no-rekey bound. Defaults are the documented production values; the
/// class-A tests set tiny ones.
pub const Limits = struct {
    max_bytes: u64 = default_max_bytes,
    max_packets: u64 = default_max_packets,
};

/// One direction's AEAD state: the KDF key plus the continuing sequence
/// number the cipher nonces with. Mirrors `kex.Cipher`'s layout and handoff
/// so the app can seed it from `kex.Result` without importing `kex.zig` here
/// (the class-A module graph has no `rng`/`ui` dependency in this file).
pub const Cipher = struct {
    key: [key_len]u8,
    seq: u64,

    pub fn init(key: *const [key_len]u8, seq: u64) Cipher {
        var c = Cipher{ .key = undefined, .seq = seq };
        @memcpy(&c.key, key);
        return c;
    }
};

/// The encrypted packet transport over `stream.Stream`.
pub const Transport = struct {
    s: *stream.Stream,
    ent: Entropy,
    /// Wire scratch: holds one encoded frame + tag. Must be at least
    /// `packet.max_total + tag_len`.
    tx: []u8,
    send: Cipher,
    recv: Cipher,
    limits: Limits = .{},
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    packets_in: u64 = 0,
    packets_out: u64 = 0,
    /// The peer sent SSH_MSG_DISCONNECT: the session ended cleanly.
    peer_disconnected: bool = false,
    peer_reason: u32 = 0,
    peer_desc: [desc_max]u8 = [_]u8{0} ** desc_max,
    peer_desc_len: usize = 0,
    /// We sent SSH_MSG_DISCONNECT (the no-rekey bound) or the stream died.
    disconnected: bool = false,

    pub fn init(
        s: *stream.Stream,
        ent: Entropy,
        tx: []u8,
        send_key: *const [key_len]u8,
        send_seq: u64,
        recv_key: *const [key_len]u8,
        recv_seq: u64,
    ) Transport {
        return .{
            .s = s,
            .ent = ent,
            .tx = tx,
            .send = Cipher.init(send_key, send_seq),
            .recv = Cipher.init(recv_key, recv_seq),
        };
    }

    /// The largest payload `sendPayload` accepts as one frame.
    pub fn maxPayload(tx_len: usize) usize {
        if (tx_len < packet.len_field + 1 + packet.min_padding + tag_len) return 0;
        return tx_len - tag_len - packet.len_field - 1 - packet.min_padding;
    }

    fn fillRandom(self: *Transport, out: []u8) Error!void {
        var off: usize = 0;
        while (off < out.len) {
            const n = self.ent.fill_fn(out[off..]);
            if (n <= 0) return error.Entropy;
            const take: usize = @intCast(n);
            if (take > out.len - off) return error.Entropy;
            off += take;
        }
    }

    fn wireLen(payload_len: usize) usize {
        return packet.len_field + 1 + payload_len + packet.paddingLen(payload_len) + tag_len;
    }

    /// Frame, seal and send one payload. No bound accounting: the caller is
    /// either `sendPayload` (which checks first) or `disconnect` (one final
    /// packet past the bound).
    fn sendRaw(self: *Transport, payload: []const u8) Error!void {
        if (payload.len > maxPayload(self.tx.len)) return error.Overlong;
        const frame_room = self.tx[0 .. self.tx.len - tag_len];
        const pad_len = packet.paddingLen(payload.len);
        var pad: [16]u8 = undefined;
        try self.fillRandom(pad[0..pad_len]);
        const frame = try packet.encode(frame_room, payload, pad[0..pad_len]);
        // In-place seal: xorStream reads input byte i before writing output
        // byte i, so an aliased ciphertext/plaintext slice round-trips.
        var tag: [tag_len]u8 = undefined;
        ssh_cipher.seal(frame, &tag, frame, self.send.seq, &self.send.key);
        self.send.seq +%= 1;
        @memcpy(self.tx[frame.len .. frame.len + tag_len], &tag);
        self.s.send(self.tx[0 .. frame.len + tag_len]) catch {
            self.disconnected = true;
            return error.Transport;
        };
    }

    /// Send one encrypted packet, disconnecting (not rekeying) when the next
    /// packet would cross the documented bound.
    pub fn sendPayload(self: *Transport, payload: []const u8) Error!void {
        if (self.peer_disconnected or self.disconnected) return error.Transport;
        const wire = wireLen(payload.len);
        if (self.bytes_out + wire > self.limits.max_bytes or
            self.packets_out + 1 > self.limits.max_packets)
        {
            self.disconnect(disconnect_by_application, bound_description);
            return error.NoRekey;
        }
        try self.sendRaw(payload);
        self.bytes_out += wire;
        self.packets_out += 1;
    }

    fn drain(self: *Transport) Error!void {
        if (self.s.failed) return error.Transport;
        self.s.drain() catch {
            self.s.fail();
            return error.Transport;
        };
    }

    fn avail(self: *const Transport) usize {
        return self.s.end - self.s.start;
    }

    /// Receive one decrypted payload into `out`. Returns null when no
    /// complete packet is buffered yet (the caller's bounded-retry signal),
    /// `error.PeerDisconnect` when the peer disconnected, and `error.Transport`
    /// when the stream died. A tampered tag/length or a malformed frame fails
    /// the stream closed.
    pub fn recvPayload(self: *Transport, out: []u8) Error!?[]const u8 {
        if (self.peer_disconnected) return error.PeerDisconnect;
        if (self.disconnected) return error.Transport;

        if (self.avail() < ssh_cipher.length_len) {
            try self.drain();
            if (self.avail() < ssh_cipher.length_len) return null;
        }
        var enc_len: [ssh_cipher.length_len]u8 = undefined;
        @memcpy(&enc_len, self.s.buf[self.s.start..][0..ssh_cipher.length_len]);
        const pl = ssh_cipher.decryptLength(&enc_len, self.recv.seq, &self.recv.key);
        if (pl > packet.max_packet_length) {
            self.s.fail();
            return error.Overlong;
        }
        const ct_len = ssh_cipher.length_len + @as(usize, pl);
        const wire = ct_len + tag_len;
        if (wire > self.s.buf.len) {
            // A length the bounded buffer can never hold: fail closed now.
            self.s.fail();
            return error.Overlong;
        }
        if (self.avail() < wire) {
            try self.drain();
            if (self.avail() < wire) return null;
        }

        const ct = self.s.buf[self.s.start..][0..ct_len];
        var tag: [tag_len]u8 = undefined;
        @memcpy(&tag, self.s.buf[self.s.start + ct_len ..][0..tag_len]);
        const seq = self.recv.seq;
        const ok = ssh_cipher.open(ct, ct, &tag, seq, &self.recv.key);
        self.recv.seq +%= 1;
        if (!ok) {
            self.s.fail();
            return error.BadPacket;
        }
        const payload = packet.decode(ct) catch {
            self.s.fail();
            return error.BadPacket;
        };
        if (payload.len == 0) {
            self.s.fail();
            return error.BadPacket;
        }
        self.s.start += wire;
        self.bytes_in += wire;
        self.packets_in += 1;
        if (self.bytes_in > self.limits.max_bytes or self.packets_in > self.limits.max_packets) {
            self.disconnect(disconnect_by_application, bound_description);
            return error.NoRekey;
        }
        if (payload[0] == msg_disconnect) {
            self.captureDisconnect(payload);
            self.peer_disconnected = true;
            return error.PeerDisconnect;
        }
        if (payload.len > out.len) {
            self.s.fail();
            return error.Overlong;
        }
        @memcpy(out[0..payload.len], payload);
        return out[0..payload.len];
    }

    const msg_disconnect: u8 = 1;

    fn captureDisconnect(self: *Transport, payload: []const u8) void {
        // byte 1 || uint32 reason || string description || string language.
        if (payload.len < 5) return;
        self.peer_reason = std.mem.readInt(u32, payload[1..5], .big);
        if (payload.len < 9) return;
        const n = std.mem.readInt(u32, payload[5..9], .big);
        const take = @min(@as(usize, n), @min(payload.len - 9, desc_max));
        @memcpy(self.peer_desc[0..take], payload[9 .. 9 + take]);
        self.peer_desc_len = take;
    }

    /// One final SSH_MSG_DISCONNECT at the current sequence number, then TCP
    /// close. Best-effort: if the frame cannot be sent, the close still
    /// happens. Idempotent.
    pub fn disconnect(self: *Transport, reason: u32, desc: []const u8) void {
        if (self.disconnected) return;
        self.disconnected = true;
        const dlen = @min(desc.len, desc_max);
        var buf: [1 + 4 + 4 + desc_max + 4]u8 = undefined;
        buf[0] = msg_disconnect;
        std.mem.writeInt(u32, buf[1..5], reason, .big);
        std.mem.writeInt(u32, buf[5..9], @intCast(dlen), .big);
        @memcpy(buf[9 .. 9 + dlen], desc[0..dlen]);
        std.mem.writeInt(u32, buf[9 + dlen ..][0..4], 0, .big);
        self.sendRaw(buf[0 .. 13 + dlen]) catch {};
        self.s.close();
    }

    /// Clean TCP close without a DISCONNECT (the peer already sent one).
    pub fn close(self: *Transport) void {
        self.disconnected = true;
        self.s.close();
    }
};

// ---------------------------------------------------------------------------
// Host tests (class A; injected transport + entropy, pinned keys, no VM)
// ---------------------------------------------------------------------------

/// The transport harness: feed chunks in (default 192 bytes, the kernel
/// payload cap), capture TX bytes, count closes, serve a pinned entropy pool.
const Harness = struct {
    var feed: [41000]u8 = undefined;
    var feed_len: usize = 0;
    var feed_pos: usize = 0;
    var recv_chunk: usize = stream.chunk_max;
    var feed_error: bool = false;

    var tx: [8192]u8 = undefined;
    var tx_len: usize = 0;

    var pool: [512]u8 = undefined;
    var pool_len: usize = 0;
    var pool_pos: usize = 0;

    var closed: usize = 0;

    fn reset() void {
        feed_len = 0;
        feed_pos = 0;
        recv_chunk = stream.chunk_max;
        feed_error = false;
        tx_len = 0;
        pool_len = 0;
        pool_pos = 0;
        closed = 0;
        @memset(&feed, 0);
        @memset(&tx, 0);
        @memset(&pool, 0);
    }

    fn setFeed(bytes: []const u8) void {
        std.debug.assert(bytes.len <= feed.len);
        @memcpy(feed[0..bytes.len], bytes);
        feed_len = bytes.len;
        feed_pos = 0;
    }

    fn setPool(bytes: []const u8) void {
        std.debug.assert(bytes.len <= pool.len);
        @memcpy(pool[0..bytes.len], bytes);
        pool_len = bytes.len;
        pool_pos = 0;
    }

    fn recvFn(out: []u8) i64 {
        if (feed_error) return -1;
        const left = feed_len - feed_pos;
        if (left == 0) return 0;
        const take = @min(@min(left, out.len), recv_chunk);
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

const wire_max = packet.max_total + tag_len;

/// A deterministic key of the right shape (not a KDF output; the KAT tie is
/// `ssh_cipher`'s and `kex.zig`'s, this module tests the framing/state).
fn testKey(seed: u8) [key_len]u8 {
    var key: [key_len]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast((i * 7 + seed) & 0xff);
    return key;
}

test "transport: a sealed payload opens with the matching key/sequence and decode recovers it" {
    var key = testKey(0x11);
    const payload = "channel-data: hello virelai";

    // Sender at the post-NEWKEYS continuing sequence number (3, pinned by
    // kex.zig's transcript test: KEXINIT=0, ECDH_INIT=1, NEWKEYS=2).
    Harness.reset();
    Harness.setPool("padpadpadpadpadpadpadpad");
    var s1buf: [stream.capacity + tag_len]u8 = undefined;
    var s1 = stream.Stream.init(&s1buf, Harness.ops());
    var tx_buf: [wire_max]u8 = undefined;
    var w = Transport.init(&s1, Harness.entropy(), &tx_buf, &key, 3, &key, 3);
    try w.sendPayload(payload);
    try std.testing.expectEqual(@as(u64, 4), w.send.seq);
    try std.testing.expectEqual(@as(u64, 1), w.packets_out);

    // Capture the wire, then feed it to a receiver seeded with the same keys
    // and continuing sequence numbers.
    var wire: [wire_max]u8 = undefined;
    const n = Harness.tx_len;
    @memcpy(wire[0..n], Harness.tx[0..n]);

    Harness.reset();
    Harness.setFeed(wire[0..n]);
    var s2buf: [stream.capacity + tag_len]u8 = undefined;
    var s2 = stream.Stream.init(&s2buf, Harness.ops());
    var rx_buf: [wire_max]u8 = undefined;
    var r = Transport.init(&s2, Harness.entropy(), &rx_buf, &key, 3, &key, 3);

    var out: [packet.max_total]u8 = undefined;
    const got = (try r.recvPayload(&out)).?;
    try std.testing.expectEqualStrings(payload, got);
    try std.testing.expectEqual(@as(u64, 4), r.recv.seq);
    try std.testing.expectEqual(@as(u64, 1), r.packets_in);
    try std.testing.expectEqual(@as(usize, 0), Harness.closed);
}

test "transport: a split wire frame reassembles one 192-byte chunk at a time" {
    var key = testKey(0x22);
    const payload = "split-across-segments";

    Harness.reset();
    Harness.setPool("padpadpadpadpadpadpadpad");
    var s1buf: [stream.capacity + tag_len]u8 = undefined;
    var s1 = stream.Stream.init(&s1buf, Harness.ops());
    var tx_buf: [wire_max]u8 = undefined;
    var w = Transport.init(&s1, Harness.entropy(), &tx_buf, &key, 7, &key, 7);
    try w.sendPayload(payload);
    var wire: [wire_max]u8 = undefined;
    @memcpy(wire[0..Harness.tx_len], Harness.tx[0..Harness.tx_len]);
    const n = Harness.tx_len;

    Harness.reset();
    Harness.setFeed(wire[0..n]);
    Harness.recv_chunk = 3; // a frame arriving in 3-byte pieces
    var s2buf: [stream.capacity + tag_len]u8 = undefined;
    var s2 = stream.Stream.init(&s2buf, Harness.ops());
    var rx_buf: [wire_max]u8 = undefined;
    var r = Transport.init(&s2, Harness.entropy(), &rx_buf, &key, 7, &key, 7);

    var out: [packet.max_total]u8 = undefined;
    var got: ?[]const u8 = null;
    var spins: usize = 0;
    while (got == null and spins < 10000) : (spins += 1) {
        got = try r.recvPayload(&out);
    }
    try std.testing.expectEqualStrings(payload, got.?);
    try std.testing.expectEqual(@as(u64, 8), r.recv.seq);
}

test "transport: tampered length/payload/tag fail closed" {
    var key = testKey(0x33);
    const payload = "tamper-me";

    Harness.reset();
    Harness.setPool("padpadpadpadpadpadpadpad");
    var s1buf: [stream.capacity + tag_len]u8 = undefined;
    var s1 = stream.Stream.init(&s1buf, Harness.ops());
    var tx_buf: [wire_max]u8 = undefined;
    var w = Transport.init(&s1, Harness.entropy(), &tx_buf, &key, 3, &key, 3);
    try w.sendPayload(payload);
    var good: [wire_max]u8 = undefined;
    @memcpy(good[0..Harness.tx_len], Harness.tx[0..Harness.tx_len]);
    const n = Harness.tx_len;

    // The encrypted length field, one payload byte, and both ends of the tag.
    const sites = [_]usize{ 0, n - tag_len - 1, n - tag_len, n - 1 };
    for (sites) |site| {
        Harness.reset();
        var bad: [wire_max]u8 = undefined;
        @memcpy(bad[0..n], good[0..n]);
        bad[site] ^= 0x01;
        Harness.setFeed(bad[0..n]);
        var s2buf: [stream.capacity + tag_len]u8 = undefined;
        var s2 = stream.Stream.init(&s2buf, Harness.ops());
        var rx_buf: [wire_max]u8 = undefined;
        var r = Transport.init(&s2, Harness.entropy(), &rx_buf, &key, 3, &key, 3);
        var out: [packet.max_total]u8 = undefined;
        const e = r.recvPayload(&out);
        try std.testing.expect(e == error.BadPacket or e == error.Overlong);
        try std.testing.expectEqual(@as(usize, 1), Harness.closed);
    }
}

test "transport: sequence numbers continue across the NEWKEYS boundary (never reset)" {
    // The plaintext KEX sent three packets at sequence 0/1/2; kex.zig pins
    // `Result.send.seq == 3` after NEWKEYS. A transport built from that
    // handoff must seal at 3; a peer that had reset to 2 cannot open it.
    var key = testKey(0x44);
    const payload = "after-newkeys";

    Harness.reset();
    Harness.setPool("padpadpadpadpadpadpadpad");
    var s1buf: [stream.capacity + tag_len]u8 = undefined;
    var s1 = stream.Stream.init(&s1buf, Harness.ops());
    var tx_buf: [wire_max]u8 = undefined;
    var w = Transport.init(&s1, Harness.entropy(), &tx_buf, &key, 3, &key, 3);
    try w.sendPayload(payload);
    var wire: [wire_max]u8 = undefined;
    @memcpy(wire[0..Harness.tx_len], Harness.tx[0..Harness.tx_len]);
    const n = Harness.tx_len;

    // The wire length field is bound to sequence 3: at seq 2 it decrypts to
    // something else, so a peer that had reset cannot even agree on the
    // frame shape.
    var enc_len: [ssh_cipher.length_len]u8 = undefined;
    @memcpy(&enc_len, wire[0..ssh_cipher.length_len]);
    const want_pl = packet.paddingLen(payload.len) + 1 + payload.len;
    try std.testing.expectEqual(@as(u32, @intCast(want_pl)), ssh_cipher.decryptLength(&enc_len, 3, &key));
    try std.testing.expect(ssh_cipher.decryptLength(&enc_len, 2, &key) != @as(u32, @intCast(want_pl)));

    // A receiver at 2 (the "reset" bug) cannot authenticate the packet: an
    // over-cap garbage length fails at the header, otherwise the tag check
    // fails once exactly that many bytes are present. Either way: fail closed.
    Harness.reset();
    const wrong_pl = ssh_cipher.decryptLength(&enc_len, 2, &key);
    var wrong_wire: [wire_max]u8 = undefined;
    var wrong_len: usize = undefined;
    if (wrong_pl > packet.max_packet_length) {
        @memcpy(wrong_wire[0..n], wire[0..n]);
        wrong_len = n;
    } else {
        const need = ssh_cipher.length_len + @as(usize, wrong_pl) + tag_len;
        @memcpy(wrong_wire[0..n], wire[0..n]);
        if (need > n) @memset(wrong_wire[n..need], 0xa5);
        wrong_len = need;
    }
    Harness.setFeed(wrong_wire[0..wrong_len]);
    var s2buf: [stream.capacity + tag_len]u8 = undefined;
    var s2 = stream.Stream.init(&s2buf, Harness.ops());
    var rx_buf: [wire_max]u8 = undefined;
    var wrong = Transport.init(&s2, Harness.entropy(), &rx_buf, &key, 3, &key, 2);
    var out: [packet.max_total]u8 = undefined;
    if (wrong.recvPayload(&out)) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(err == error.BadPacket or err == error.Overlong);
    }
    try std.testing.expectEqual(@as(usize, 1), Harness.closed);

    // A receiver at the continuing 3 authenticates and advances to 4.
    Harness.reset();
    Harness.setFeed(wire[0..n]);
    var s3buf: [stream.capacity + tag_len]u8 = undefined;
    var s3 = stream.Stream.init(&s3buf, Harness.ops());
    var rx2_buf: [wire_max]u8 = undefined;
    var right = Transport.init(&s3, Harness.entropy(), &rx2_buf, &key, 2, &key, 3);
    try std.testing.expectEqualStrings(payload, (try right.recvPayload(&out)).?);
    try std.testing.expectEqual(@as(u64, 4), right.recv.seq);
}

test "transport: the packet bound disconnects (BY_APPLICATION) instead of rekeying" {
    var key = testKey(0x55);

    Harness.reset();
    Harness.setPool("padpadpadpadpadpadpadpadpadpadpadpadpadpadpadpad");
    var s1buf: [stream.capacity + tag_len]u8 = undefined;
    var s1 = stream.Stream.init(&s1buf, Harness.ops());
    var tx_buf: [wire_max]u8 = undefined;
    var w = Transport.init(&s1, Harness.entropy(), &tx_buf, &key, 3, &key, 3);
    w.limits.max_packets = 2;

    try w.sendPayload("one");
    try w.sendPayload("two");
    try std.testing.expectError(error.NoRekey, w.sendPayload("three"));
    try std.testing.expect(w.disconnected);
    try std.testing.expectEqual(@as(usize, 1), Harness.closed);
    try std.testing.expectEqual(@as(u64, 2), w.packets_out);

    // The mirror reads the two payloads, then the DISCONNECT (reason 11) —
    // the session ends cleanly, not with an exception.
    var wire: [wire_max]u8 = undefined;
    @memcpy(wire[0..Harness.tx_len], Harness.tx[0..Harness.tx_len]);
    const n = Harness.tx_len;
    Harness.reset();
    Harness.setFeed(wire[0..n]);
    var s2buf: [stream.capacity + tag_len]u8 = undefined;
    var s2 = stream.Stream.init(&s2buf, Harness.ops());
    var rx_buf: [wire_max]u8 = undefined;
    var r = Transport.init(&s2, Harness.entropy(), &rx_buf, &key, 3, &key, 3);
    var out: [packet.max_total]u8 = undefined;
    try std.testing.expectEqualStrings("one", (try r.recvPayload(&out)).?);
    try std.testing.expectEqualStrings("two", (try r.recvPayload(&out)).?);
    try std.testing.expectError(error.PeerDisconnect, r.recvPayload(&out));
    try std.testing.expectEqual(disconnect_by_application, r.peer_reason);
    try std.testing.expectEqualStrings(bound_description, r.peer_desc[0..r.peer_desc_len]);
}

test "transport: the byte bound also disconnects, and the peer's DISCONNECT ends cleanly" {
    var key = testKey(0x66);

    Harness.reset();
    Harness.setPool("padpadpadpadpadpadpadpadpadpadpadpad");
    var s1buf: [stream.capacity + tag_len]u8 = undefined;
    var s1 = stream.Stream.init(&s1buf, Harness.ops());
    var tx_buf: [wire_max]u8 = undefined;
    var w = Transport.init(&s1, Harness.entropy(), &tx_buf, &key, 3, &key, 3);
    w.limits.max_bytes = 8; // smaller than any single frame
    try std.testing.expectError(error.NoRekey, w.sendPayload("x"));
    try std.testing.expectEqual(@as(usize, 1), Harness.closed);
    try std.testing.expect(Harness.tx_len > 0); // the DISCONNECT went out

    // The peer reads the DISCONNECT: recvPayload reports PeerDisconnect and
    // does NOT fail the stream closed (a clean end, reason 11).
    var wire: [wire_max]u8 = undefined;
    @memcpy(wire[0..Harness.tx_len], Harness.tx[0..Harness.tx_len]);
    const n = Harness.tx_len;
    Harness.reset();
    Harness.setFeed(wire[0..n]);
    var s2buf: [stream.capacity + tag_len]u8 = undefined;
    var s2 = stream.Stream.init(&s2buf, Harness.ops());
    var rx_buf: [wire_max]u8 = undefined;
    var r = Transport.init(&s2, Harness.entropy(), &rx_buf, &key, 3, &key, 3);
    var out: [packet.max_total]u8 = undefined;
    try std.testing.expectError(error.PeerDisconnect, r.recvPayload(&out));
    try std.testing.expect(r.peer_disconnected);
    try std.testing.expectEqual(disconnect_by_application, r.peer_reason);
    try std.testing.expectEqual(@as(usize, 0), Harness.closed);
}

test "transport: entropy failure fails closed without touching the wire" {
    var key = testKey(0x77);
    Harness.reset();
    // No pool: the first padding fill returns negative.
    var s1buf: [stream.capacity + tag_len]u8 = undefined;
    var s1 = stream.Stream.init(&s1buf, Harness.ops());
    var tx_buf: [wire_max]u8 = undefined;
    var w = Transport.init(&s1, Harness.entropy(), &tx_buf, &key, 3, &key, 3);
    try std.testing.expectError(error.Entropy, w.sendPayload("x"));
    try std.testing.expectEqual(@as(usize, 0), Harness.tx_len);
}

test "transport: an over-cap payload is refused before any encryption" {
    var key = testKey(0x88);
    Harness.reset();
    Harness.setPool("padpadpadpad");
    var s1buf: [stream.capacity + tag_len]u8 = undefined;
    var s1 = stream.Stream.init(&s1buf, Harness.ops());
    var tx_buf: [64]u8 = undefined; // far too small for the payload
    var w = Transport.init(&s1, Harness.entropy(), &tx_buf, &key, 3, &key, 3);
    var big: [128]u8 = undefined;
    try std.testing.expectError(error.Overlong, w.sendPayload(&big));
    try std.testing.expectEqual(@as(usize, 0), Harness.tx_len);
}
