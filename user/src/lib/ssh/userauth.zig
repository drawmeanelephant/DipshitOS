//! M51 SSH3 (#1170, ADR 0025 D2/D3): SSH-2 user authentication.
//!
//! This is the client half of RFC 4252, layered on the completed KEX: it
//! consumes the SSH3 slice of `kex.Result` (`h`, `session_id`, `host_key`),
//! proves the host key against the `SSH/KNOWN_HOSTS` pin, and authenticates
//! the client with an Ed25519 `publickey` signature. It consumes the M47
//! primitives (`ed25519`, `ct`) and the M50 seams — `sys_secret_get` (slot
//! 70) and the ordinary file ABI (slots 23–27) for the plain pin file. No
//! kernel changes and no new syscall slot.
//!
//! Flow (fail closed at every step):
//!
//!   1. **Host-key pin FIRST** (ADR 0025 D3): read `SSH/KNOWN_HOSTS`
//!      through the file ABI and compare the KEX-verified 32-byte
//!      `host_key` with the pin for `host:port`. An absent pin and a
//!      mismatch are distinct fail-closed statuses; nothing is sent and no
//!      secret is read before the pin is proven.
//!   2. `SSH_MSG_SERVICE_REQUEST` (5) for `ssh-userauth`, then
//!      `SSH_MSG_SERVICE_ACCEPT` (6); IGNORE/DEBUG are skipped and a
//!      DISCONNECT fails closed (RFC 4252 §5).
//!   3. The `none` probe (RFC 4252 §5.2): `SSH_MSG_USERAUTH_REQUEST` (50)
//!      with the `none` method. A `USERAUTH_FAILURE` (51) yields the
//!      methods name-list and partial-success bool; if `publickey` is not
//!      offered the client fails closed. A `USERAUTH_SUCCESS` (52) means
//!      the peer accepted `none` and the seed is never read.
//!   4. `publickey` (RFC 4252 §7): the key blob is
//!      `string "ssh-ed25519" || string <32-byte pubkey>`. The client seed
//!      is read from the TS5 store (`ssh-user-ed25519`, 64 hex characters)
//!      exactly here — the latest point it is needed. The signature covers
//!      `string session_id || byte 50 || string user ||
//!      string "ssh-connection" || string "publickey" || boolean TRUE ||
//!      string "ssh-ed25519" || string key_blob`; the request adds the
//!      signature blob `string "ssh-ed25519" || string <64-byte sig>`.
//!      SUCCESS, FAILURE (=> `AuthRejected`), and interleaved BANNER (53)
//!      are handled.
//!   5. Every secret staging buffer (the hex credential, the decoded seed,
//!      the signature) is `ct.wipe`d before `run` returns, on every path,
//!      including errors.
//!
//! The seed must NEVER be logged: this module has no print/log path, emits
//! no serial, history, env, tombstone, or strace output (slot 70 is already
//! trace-excluded), and the class-A tests scan every captured byte.
//!
//! PRODUCTION BOUNDARY (honest): the injected transport seam carries
//! DECRYPTED SSH packet payloads. The encrypted RFC 4253 packet layer over
//! `kex.Result.send`/`recv` and `stream.zig` lands with SSH4's `SSH.BIN`,
//! which owns the packet stream; SSH3 stays a pure auth state machine and
//! the class-A tests drive it with a deterministic payload peer.
//!
//! VECTOR PROVENANCE: the layout is RFC 4252 §7; the pinned `session_id` and
//! host key come from `kex.zig`'s deterministic transcript (the RFC 8032
//! §7.1 TEST 1 host key), and the client seed is RFC 8032 §7.1 TEST 2. The
//! pinned 64-byte signature was produced over the exact signed bytes by
//! OpenSSL 3.6.4 Ed25519 (`pkeyutl -sign -rawin`) and verifies with the
//! derived public key. Ed25519 is deterministic, so the module's signature
//! must equal it byte-for-byte.

const std = @import("std");
const builtin = @import("builtin");
// Module-mapped deps (the `kex.zig`/`stream.zig` pattern): a file inside
// `ssh/` cannot path-import `../` outside its module root, so `ui` and
// `crypto` arrive as mapped modules; `wire.zig` is a sibling path import.
const abi = @import("ui").abi;
const wire = @import("wire.zig");
const crypto = @import("crypto");
const ed25519 = crypto.ed25519;
const ct = crypto.ct;

/// The TS5 secret key holding the client's Ed25519 seed as 64 hex chars
/// (ADR 0025 D3). 16 chars of key and 64 of value fit the store's 32/64
/// bounds exactly.
pub const key_user: []const u8 = "ssh-user-ed25519";
/// The plain share file with the `#v1` host-key pins (ADR 0025 D3).
pub const known_hosts_path: []const u8 = "SSH/KNOWN_HOSTS";

pub const seed_len: usize = ed25519.secret_key_len; // 32
pub const seed_hex_len: usize = seed_len * 2; // 64
pub const host_key_len: usize = ed25519.public_key_len; // 32
pub const sig_len: usize = ed25519.signature_len; // 64

/// Bounds (fail closed over them).
pub const user_max: usize = 64;
pub const host_max: usize = 255;
pub const known_hosts_max: usize = 4096;
pub const pin_line_max: usize = 512;
pub const pin_lines_max: usize = 64;
pub const message_max: usize = 2048;
pub const request_max: usize = 512;
pub const banner_max: usize = 256;
/// Bounded no-progress wait: a transport that never delivers fails closed.
pub const wait_limit: usize = 100_000;

// SSH message numbers (RFC 4252 §6, §11).
pub const msg_disconnect: u8 = 1;
pub const msg_ignore: u8 = 2;
pub const msg_debug: u8 = 4;
pub const msg_service_request: u8 = 5;
pub const msg_service_accept: u8 = 6;
pub const msg_userauth_request: u8 = 50;
pub const msg_userauth_failure: u8 = 51;
pub const msg_userauth_success: u8 = 52;
pub const msg_userauth_banner: u8 = 53;

// The single M51 method and service (ADR 0025 D2).
pub const service_userauth: []const u8 = "ssh-userauth";
pub const service_connection: []const u8 = "ssh-connection";
pub const method_none: []const u8 = "none";
pub const method_publickey: []const u8 = "publickey";
pub const algo_ed25519: []const u8 = "ssh-ed25519";

pub const Error = wire.Error || error{
    /// The user name or host is empty or over the bounded maximum.
    BadTarget,
    /// The pin file is not the bounded `#v1` schema, or has too many
    /// lines / an over-long line.
    BadPinFile,
    /// A pin line for the target is malformed, or two entries disagree.
    BadPinLine,
    /// No `SSH/KNOWN_HOSTS` file, or no pin for the target `host:port`.
    MissingHostPin,
    /// The pin exists but does not equal the KEX-verified host key.
    HostKeyMismatch,
    /// The TS5 store has no `ssh-user-ed25519` entry for the caller.
    MissingCredential,
    /// The stored credential is not 64 hex characters.
    BadCredential,
    /// The injected transport failed or stalled.
    Transport,
    /// The peer sent SSH_MSG_DISCONNECT.
    PeerDisconnect,
    /// A message the state machine does not expect here.
    UnexpectedMessage,
    /// A malformed message (bad shape, trailing bytes, over-long payload).
    BadMessage,
    /// The service request was not answered with SERVICE_ACCEPT.
    ServiceRejected,
    /// The peer does not offer `publickey` authentication.
    NoSupportedAuth,
    /// The peer rejected the `publickey` request.
    AuthRejected,
    /// `h` and `session_id` are not the same verified exchange hash.
    SessionIdMismatch,
};

/// What authenticated the session. `.none` means the peer accepted the
/// `none` method and the client seed was never read.
pub const Success = enum { none, publickey };

/// The auth target: the SSH user name and the `host:port` the pin (and the
/// log/provisioning story) is keyed by.
pub const Target = struct {
    user: []const u8,
    host: []const u8,
    port: u16 = 22,
};

const sha256_len = 32;

/// The SSH3 slice of `kex.Result` (ADR 0025 D2/D6). SSH4 passes the three
/// fields directly: importing `kex.zig` would pull its `rng` module, whose
/// `ui/abi.zig` path import collides with this module's mapped `ui` in the
/// class-A test graph. The `h`/`session_id` equality check below is
/// `kex.Result.requireSessionId`'s handoff guard.
pub const Session = struct {
    /// The exchange hash H of this KEX (`kex.Result.h`).
    h: [sha256_len]u8,
    /// The SSH session identifier; on the first KEX it IS H
    /// (`kex.Result.session_id`), and M51 has no rekey.
    session_id: [sha256_len]u8,
    /// The KEX-verified raw `ssh-ed25519` host public key
    /// (`kex.Result.host_key`); the pin is compared against this.
    host_key: [host_key_len]u8,
};

/// The injected secret source seam (the `netauth.zig` `Source` pattern):
/// write the caller principal's value for `name` into `out` and return its
/// length, or null when absent.
pub const Source = struct {
    get_fn: *const fn (ctx: ?*anyopaque, name: []const u8, out: []u8) ?usize,
    ctx: ?*anyopaque = null,
};

/// The production secret source: `sys_secret_get` (slot 70), matching the
/// key name byte-exactly. The kernel already scopes records to the calling
/// principal. Mirrors `netauth.zig`'s reader for the same store.
pub fn storeSource(ctx: ?*anyopaque, name: []const u8, out: []u8) ?usize {
    _ = ctx;
    if (builtin.os.tag != .freestanding) return null;
    var buf: [abi.secret_entries_max * abi.secret_entry_bytes]u8 = undefined;
    defer ct.wipe(&buf);
    const rc = abi.secret_get(&buf);
    if (rc <= 0) return null;
    const count: usize = @intCast(@divTrunc(rc, abi.secret_entry_bytes));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const rec = @as(*align(1) const abi.SecretRecord, @ptrCast(&buf[i * abi.secret_entry_bytes]));
        if (!std.mem.eql(u8, rec.key[0..rec.key_len], name)) continue;
        const v = rec.val[0..rec.val_len];
        const take = @min(v.len, out.len);
        @memcpy(out[0..take], v[0..take]);
        return take;
    }
    return null;
}

/// The injected pin-file seam: read the whole `SSH/KNOWN_HOSTS` share file
/// into `out` and return its length, or null when absent/unreadable/over
/// the caller's bound (never a partial read).
pub const FileSource = struct {
    read_fn: *const fn (ctx: ?*anyopaque, out: []u8) ?usize,
    ctx: ?*anyopaque = null,
};

/// The production pin source: the ordinary file ABI (slots 23–27). The pin
/// file is deliberately NOT the secret class (ADR 0025 D3) — it is public,
/// human-editable, and seeded by tooling.
pub fn knownHostsSource() FileSource {
    return .{ .read_fn = knownHostsFile };
}

pub fn knownHostsFile(ctx: ?*anyopaque, out: []u8) ?usize {
    _ = ctx;
    if (builtin.os.tag != .freestanding) return null;
    const fd = abi.file_open(known_hosts_path, abi.MODE_READ);
    if (fd < 0) return null;
    defer abi.file_close(@intCast(fd));
    const n = abi.file_read(@intCast(fd), out);
    if (n < 0) return null;
    const len: usize = @intCast(n);
    if (len == out.len) {
        // The buffer is full: an over-cap file must not look like a short
        // one (a truncated tail could hide/alter a pin). Probe one byte.
        var probe: [1]u8 = undefined;
        if (abi.file_read(@intCast(fd), &probe) > 0) return null;
    }
    return len;
}

/// The injected transport seam: a full DECRYPTED SSH packet payload per
/// call. `send_fn` returns the bytes accepted (must equal `payload.len`) or
/// negative; `recv_fn` returns a payload length, 0 for "nothing yet"
/// (bounded by `wait_limit`), or negative on error.
pub const Transport = struct {
    send_fn: *const fn (payload: []const u8) i64,
    recv_fn: *const fn (out: []u8) i64,
};

/// A parsed `USERAUTH_FAILURE` (RFC 4252 §5.1). `methods` borrows the
/// payload the caller passed to `parseFailure`.
pub const Failure = struct {
    /// RFC 4252 §5.1: "none" was accepted in part; the client must still
    /// continue with a real method.
    partial_success: bool,
    /// The comma-separated method name-list (validated; no empty members).
    methods: []const u8,
};

/// Parse and strictly validate a `USERAUTH_FAILURE` payload: exact shape,
/// a well-formed name-list, a true boolean octet, no trailing bytes.
pub fn parseFailure(payload: []const u8) Error!Failure {
    var r = wire.Reader.init(payload);
    if (try r.readByte() != msg_userauth_failure) return error.BadMessage;
    const methods = try r.readNameList();
    var it = wire.names(methods);
    while (try it.next()) |_| {}
    const partial = try r.readBool();
    if (r.remaining() != 0) return error.BadMessage;
    return .{ .partial_success = partial, .methods = methods };
}

/// Whether a validated name-list offers `name`.
pub fn offersMethod(methods: []const u8, name: []const u8) Error!bool {
    var it = wire.names(methods);
    while (try it.next()) |m| {
        if (std.mem.eql(u8, m, name)) return true;
    }
    return false;
}

/// Find the pin for `host:port` in `#v1` KNOWN_HOSTS text:
///
/// ```
/// #v1
/// host<TAB>port<TAB>ssh-ed25519<TAB><64-hex-pubkey>
/// ```
///
/// The first matching `host:port` entry wins; a second matching entry with
/// a different key is refused (`BadPinLine`) rather than silently trusting
/// the first. The schema must be `#v1` (`#` comment lines are allowed, but
/// `#v1` must precede the first entry). No match — or an absent/empty file
/// — is `MissingHostPin`.
pub fn findPin(text: []const u8, host: []const u8, port: u16, out: *[host_key_len]u8) Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var seen_header = false;
    var found = false;
    var key: [host_key_len]u8 = undefined;
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        if (line_no > pin_lines_max) return error.BadPinFile;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line.len > pin_line_max) return error.BadPinFile;
        if (line[0] == '#') {
            if (std.mem.eql(u8, line, "#v1")) seen_header = true;
            continue;
        }
        if (!seen_header) return error.BadPinFile;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const f_host = fields.next() orelse return error.BadPinLine;
        const f_port = fields.next() orelse return error.BadPinLine;
        const f_type = fields.next() orelse return error.BadPinLine;
        const f_hex = fields.next() orelse return error.BadPinLine;
        if (fields.next() != null) return error.BadPinLine;
        if (f_host.len == 0 or f_port.len == 0 or f_type.len == 0 or f_hex.len == 0)
            return error.BadPinLine;
        if (!std.mem.eql(u8, f_host, host)) continue;
        const p = std.fmt.parseInt(u16, f_port, 10) catch return error.BadPinLine;
        if (p != port) continue;
        if (!std.mem.eql(u8, f_type, algo_ed25519)) return error.BadPinLine;
        if (f_hex.len != host_key_len * 2) return error.BadPinLine;
        var got: [host_key_len]u8 = undefined;
        _ = std.fmt.hexToBytes(&got, f_hex) catch return error.BadPinLine;
        if (!found) {
            key = got;
            found = true;
        } else if (!ct.ctEq(&key, &got)) {
            return error.BadPinLine;
        }
    }
    if (!found) return error.MissingHostPin;
    out.* = key;
}

/// The client auth state machine. All working memory is caller-owned; the
/// secret staging fields are wiped by `scrub` on every `run` path and are
/// public only so the class-A tests can assert they are zero.
pub const Userauth = struct {
    source: Source,
    pins: FileSource,
    transport: Transport,
    /// The hex credential as read from the TS5 store (secret; wiped).
    cred: [seed_hex_len]u8 = [_]u8{0} ** seed_hex_len,
    cred_len: usize = 0,
    /// The decoded Ed25519 seed (secret; wiped).
    seed: [seed_len]u8 = [_]u8{0} ** seed_len,
    /// The 64-byte signature staging (wiped).
    sig: [sig_len]u8 = [_]u8{0} ** sig_len,
    /// The last USERAUTH_BANNER text (public server data; bounded copy).
    banner: [banner_max]u8 = [_]u8{0} ** banner_max,
    banner_len: usize = 0,
    /// The last USERAUTH_FAILURE partial-success bool seen.
    last_partial_success: bool = false,
    recv_buf: [message_max]u8 = undefined,

    pub fn init(source: Source, pins: FileSource, transport: Transport) Userauth {
        return .{ .source = source, .pins = pins, .transport = transport };
    }

    /// The production secret source (slot 70) and pin source (file ABI).
    pub fn sysSource() Source {
        return .{ .get_fn = storeSource };
    }

    pub fn sysPins() FileSource {
        return knownHostsSource();
    }

    /// Authenticate the session: pin check, service request, `none` probe,
    /// then `publickey`. Fails closed — no step proceeds on an unexpected
    /// message, and nothing is sent before the host pin is proven.
    pub fn run(self: *Userauth, session: *const Session, target: *const Target) Error!Success {
        defer self.scrub();

        // kex.Result.requireSessionId's guard: M51 has no rekey, so the
        // session identifier MUST be the H this KEX verified. A mismatched
        // pair is never signed over.
        if (!ct.ctEq(&session.h, &session.session_id)) return error.SessionIdMismatch;
        try validateTarget(target);

        // 1. The pin first: no packet, no secret, before the host is known.
        try self.checkPin(&session.host_key, target);

        // 2. Service request / accept.
        try self.sendServiceRequest();
        try self.awaitServiceAccept();

        // 3. The none probe.
        switch (try self.noneProbe(target.user)) {
            .success => return .none,
            .failure => {},
        }

        // 4. publickey.
        try self.publickeyAuth(&session.session_id, target.user);
        return .publickey;
    }

    fn scrub(self: *Userauth) void {
        ct.wipe(&self.cred);
        ct.wipe(&self.seed);
        ct.wipe(&self.sig);
        self.cred_len = 0;
    }

    fn validateTarget(target: *const Target) Error!void {
        if (target.user.len == 0 or target.user.len > user_max) return error.BadTarget;
        if (target.host.len == 0 or target.host.len > host_max) return error.BadTarget;
    }

    fn checkPin(self: *Userauth, host_key: *const [host_key_len]u8, target: *const Target) Error!void {
        var text: [known_hosts_max]u8 = undefined;
        const n = self.pins.read_fn(self.pins.ctx, &text) orelse return error.MissingHostPin;
        if (n > text.len) return error.MissingHostPin;
        var pin: [host_key_len]u8 = undefined;
        try findPin(text[0..n], target.host, target.port, &pin);
        if (!ct.ctEq(&pin, host_key)) return error.HostKeyMismatch;
    }

    fn send(self: *Userauth, payload: []const u8) Error!void {
        const n = self.transport.send_fn(payload);
        if (n != @as(i64, @intCast(payload.len))) return error.Transport;
    }

    fn recv(self: *Userauth, out: []u8) Error![]const u8 {
        var spins: usize = 0;
        while (true) {
            const n = self.transport.recv_fn(out);
            if (n < 0) return error.Transport;
            if (n > 0) {
                const take: usize = @intCast(n);
                if (take > out.len) return error.BadMessage;
                return out[0..take];
            }
            spins += 1;
            if (spins >= wait_limit) return error.Transport;
        }
    }

    fn sendServiceRequest(self: *Userauth) Error!void {
        var buf: [1 + 4 + service_userauth.len]u8 = undefined;
        var w = wire.Writer.init(&buf);
        try w.writeByte(msg_service_request);
        try w.writeString(service_userauth);
        try self.send(w.written());
    }

    fn awaitServiceAccept(self: *Userauth) Error!void {
        while (true) {
            const payload = try self.recv(&self.recv_buf);
            if (payload.len == 0) return error.BadMessage;
            switch (payload[0]) {
                msg_ignore, msg_debug => continue,
                msg_disconnect => return error.PeerDisconnect,
                msg_service_accept => {
                    var r = wire.Reader.init(payload);
                    _ = try r.readByte();
                    const name = try r.readString();
                    if (r.remaining() != 0) return error.BadMessage;
                    if (!std.mem.eql(u8, name, service_userauth)) return error.ServiceRejected;
                    return;
                },
                else => return error.ServiceRejected,
            }
        }
    }

    const Probe = enum { success, failure };

    fn noneProbe(self: *Userauth, user: []const u8) Error!Probe {
        var buf: [1 + 4 + user_max + 4 + service_connection.len + 4 + method_none.len]u8 = undefined;
        var w = wire.Writer.init(&buf);
        try w.writeByte(msg_userauth_request);
        try w.writeString(user);
        try w.writeString(service_connection);
        try w.writeString(method_none);
        try self.send(w.written());

        while (true) {
            const payload = try self.recv(&self.recv_buf);
            if (payload.len == 0) return error.BadMessage;
            switch (payload[0]) {
                msg_ignore, msg_debug => continue,
                msg_disconnect => return error.PeerDisconnect,
                msg_userauth_banner => {
                    try self.captureBanner(payload);
                    continue;
                },
                msg_userauth_failure => {
                    const f = try parseFailure(payload);
                    self.last_partial_success = f.partial_success;
                    if (!try offersMethod(f.methods, method_publickey)) return error.NoSupportedAuth;
                    return .failure;
                },
                msg_userauth_success => {
                    if (payload.len != 1) return error.BadMessage;
                    return .success;
                },
                else => return error.UnexpectedMessage,
            }
        }
    }

    /// Write the RFC 4252 §7 `publickey` request body (everything after the
    /// leading `string session identifier` the caller writes first). The
    /// signature covers exactly the resulting prefix.
    fn writePublickeyRequest(w: *wire.Writer, user: []const u8, key_blob: []const u8) Error!void {
        try w.writeByte(msg_userauth_request);
        try w.writeString(user);
        try w.writeString(service_connection);
        try w.writeString(method_publickey);
        try w.writeBool(true);
        try w.writeString(algo_ed25519);
        try w.writeString(key_blob);
    }

    fn publickeyAuth(self: *Userauth, session_id: *const [sha256_len]u8, user: []const u8) Error!void {
        // The credential is read exactly here — after the peer has refused
        // `none` and `publickey` is the remaining path; a peer that accepts
        // `none` never touches the store.
        const n = self.source.get_fn(self.source.ctx, key_user, &self.cred) orelse
            return error.MissingCredential;
        if (n != seed_hex_len) return error.BadCredential;
        self.cred_len = n;
        _ = std.fmt.hexToBytes(&self.seed, self.cred[0..seed_hex_len]) catch
            return error.BadCredential;

        var pubkey: [host_key_len]u8 = undefined;
        defer ct.wipe(&pubkey);
        ed25519.derivePublicKey(&pubkey, &self.seed);

        var blob_buf: [4 + algo_ed25519.len + 4 + host_key_len]u8 = undefined;
        var bw = wire.Writer.init(&blob_buf);
        try bw.writeString(algo_ed25519);
        try bw.writeString(&pubkey);

        // The signed message and the outgoing request share one buffer: the
        // prefix written before the signature IS `string session_id ||
        // request` (RFC 4252 §7), and the trailing signature string turns it
        // into the packet body.
        var req_buf: [request_max]u8 = undefined;
        var w = wire.Writer.init(&req_buf);
        try w.writeString(session_id);
        try writePublickeyRequest(&w, user, bw.written());

        ed25519.sign(&self.sig, w.written(), &self.seed);

        var sig_blob_buf: [4 + algo_ed25519.len + 4 + sig_len]u8 = undefined;
        var sw = wire.Writer.init(&sig_blob_buf);
        try sw.writeString(algo_ed25519);
        try sw.writeString(&self.sig);
        try w.writeString(sw.written());

        try self.send(w.written());

        while (true) {
            const payload = try self.recv(&self.recv_buf);
            if (payload.len == 0) return error.BadMessage;
            switch (payload[0]) {
                msg_ignore, msg_debug => continue,
                msg_disconnect => return error.PeerDisconnect,
                msg_userauth_banner => {
                    try self.captureBanner(payload);
                    continue;
                },
                msg_userauth_success => {
                    if (payload.len != 1) return error.BadMessage;
                    return;
                },
                msg_userauth_failure => {
                    const f = try parseFailure(payload);
                    self.last_partial_success = f.partial_success;
                    return error.AuthRejected;
                },
                else => return error.UnexpectedMessage,
            }
        }
    }

    fn captureBanner(self: *Userauth, payload: []const u8) Error!void {
        var r = wire.Reader.init(payload);
        _ = try r.readByte();
        const text = try r.readString();
        _ = try r.readString(); // language tag: not used
        if (r.remaining() != 0) return error.BadMessage;
        const take = @min(text.len, self.banner.len);
        @memcpy(self.banner[0..take], text[0..take]);
        self.banner_len = take;
    }
};

// ---------------------------------------------------------------------------
// Host tests (class A; injected source/pin/transport, deterministic peer)
// ---------------------------------------------------------------------------

/// The pinned deterministic vector. `session_id` and `host_pk` are the
/// RFC 8032 §7.1 TEST 1 values pinned in `kex.zig`'s transcript; the client
/// seed is RFC 8032 §7.1 TEST 2. The signed bytes are the RFC 4252 §7
/// layout; the signature was produced by OpenSSL 3.6.4 Ed25519 over those
/// exact bytes (see the module header).
const Vector = struct {
    const session_id = hex("15c9cacbd36588f06a5189f221597e1e4d13f2f8c1fe9951f62b85afb957136d");
    const host_pk = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    const user_seed = hex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb");
    const user_seed_hex = "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb";
    const user_pk = hex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c");
    /// A second RFC 8032 TEST 3 seed whose public key differs (the "wrong
    /// user key" case).
    const wrong_seed_hex = "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7";
    const wrong_pk = hex("fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025");

    const user = "virelai";
    const host = "pin.example";
    const port: u16 = 2222;

    const key_blob = hex("0000000b7373682d65643235353139000000203d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c");
    const service_request = hex("050000000c7373682d7573657261757468");
    const none_request = hex("3200000007766972656c61690000000e7373682d636f6e6e656374696f6e000000046e6f6e65");

    /// `string session_id || byte 50 || string user || string
    /// "ssh-connection" || string "publickey" || TRUE || string
    /// "ssh-ed25519" || string key_blob` — the exact signed bytes.
    const signed = hex("0000002015c9cacbd36588f06a5189f221597e1e4d13f2f8c1fe9951f62b85afb957136d" ++
        "3200000007766972656c61690000000e7373682d636f6e6e656374696f6e000000097075626c69636b657901" ++
        "0000000b7373682d6564323535313900000033" ++
        "0000000b7373682d65643235353139000000203d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c");
    const sig = hex("e51e41d7670cbbae44e868b6a961badae27a6172bce46f944233dfa47900fe7124f0c51c05acc9ebe309d32691455c1608c729a41f99dada6b263d4b488f490f");
    const publickey_request = hex("0000002015c9cacbd36588f06a5189f221597e1e4d13f2f8c1fe9951f62b85afb957136d" ++
        "3200000007766972656c61690000000e7373682d636f6e6e656374696f6e000000097075626c69636b657901" ++
        "0000000b7373682d6564323535313900000033" ++
        "0000000b7373682d65643235353139000000203d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c" ++
        "00000053" ++
        "0000000b7373682d6564323535313900000040e51e41d7670cbbae44e868b6a961badae27a6172bce46f944233dfa47900fe7124f0c51c05acc9ebe309d32691455c1608c729a41f99dada6b263d4b488f490f");

    const service_accept = hex("060000000c7373682d7573657261757468");
    const failure_publickey_password = hex("33000000127075626c69636b65792c70617373776f726400");
    const failure_password_only = hex("330000000870617373776f726400");
    const success = hex("34");
    const banner = hex("3500000013417574686f72697a656420757365206f6e6c7900000002656e");

    const known_hosts = "#v1\npin.example\t2222\tssh-ed25519\t" ++
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a\n";
};

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

/// The scripted peer + injected seams. All state is static (the kex.zig
/// `TestNet` pattern): the transcript is deterministic so the whole script
/// is precomputed.
const TestPeer = struct {
    var tx: [4096]u8 = undefined;
    var tx_len: usize = 0;
    var tx_boundaries: [16]usize = undefined;
    var tx_count: usize = 0;

    var feed: [4096]u8 = undefined;
    var feed_len: usize = 0;
    var feed_pos: usize = 0;

    var cred: [seed_hex_len]u8 = undefined;
    var cred_len: usize = 0;
    var cred_present: bool = false;
    var cred_calls: usize = 0;

    var pin_text: [known_hosts_max]u8 = undefined;
    var pin_len: usize = 0;
    var pin_present: bool = false;
    var pin_calls: usize = 0;

    fn reset() void {
        tx_len = 0;
        tx_count = 0;
        feed_len = 0;
        feed_pos = 0;
        cred_len = 0;
        cred_present = false;
        cred_calls = 0;
        pin_len = 0;
        pin_present = false;
        pin_calls = 0;
        @memset(&tx, 0);
        @memset(&feed, 0);
        @memset(&cred, 0);
        @memset(&pin_text, 0);
    }

    fn setCred(bytes: []const u8) void {
        std.debug.assert(bytes.len <= cred.len);
        @memcpy(cred[0..bytes.len], bytes);
        cred_len = bytes.len;
        cred_present = true;
    }

    fn setPins(text: []const u8) void {
        std.debug.assert(text.len <= pin_text.len);
        @memcpy(pin_text[0..text.len], text);
        pin_len = text.len;
        pin_present = true;
    }

    /// Queue response payloads, each length-prefixed (uint32 BE).
    fn setScript(frames: []const []const u8) void {
        feed_len = 0;
        for (frames) |f| {
            std.debug.assert(feed_len + 4 + f.len <= feed.len);
            std.mem.writeInt(u32, feed[feed_len..][0..4], @intCast(f.len), .big);
            feed_len += 4;
            @memcpy(feed[feed_len..][0..f.len], f);
            feed_len += f.len;
        }
        feed_pos = 0;
    }

    fn sendFn(payload: []const u8) i64 {
        if (tx_len + payload.len > tx.len) return -1;
        @memcpy(tx[tx_len..][0..payload.len], payload);
        tx_len += payload.len;
        if (tx_count < tx_boundaries.len) {
            tx_boundaries[tx_count] = tx_len;
            tx_count += 1;
        }
        return @intCast(payload.len);
    }

    fn recvFn(out: []u8) i64 {
        if (feed_pos >= feed_len) return 0;
        const n = std.mem.readInt(u32, feed[feed_pos..][0..4], .big);
        feed_pos += 4;
        if (n > out.len) return -1;
        @memcpy(out[0..n], feed[feed_pos..][0..n]);
        feed_pos += n;
        return @intCast(n);
    }

    fn sourceFn(ctx: ?*anyopaque, name: []const u8, out: []u8) ?usize {
        _ = ctx;
        cred_calls += 1;
        if (!cred_present) return null;
        if (!std.mem.eql(u8, name, key_user)) return null;
        const take = @min(cred_len, out.len);
        @memcpy(out[0..take], cred[0..take]);
        return take;
    }

    fn pinFn(ctx: ?*anyopaque, out: []u8) ?usize {
        _ = ctx;
        pin_calls += 1;
        if (!pin_present) return null;
        const take = @min(pin_len, out.len);
        @memcpy(out[0..take], pin_text[0..take]);
        return take;
    }

    fn transport() Transport {
        return .{ .send_fn = sendFn, .recv_fn = recvFn };
    }

    fn source() Source {
        return .{ .get_fn = sourceFn };
    }

    fn pins() FileSource {
        return .{ .read_fn = pinFn };
    }

    fn sentPayload(i: usize) []const u8 {
        const start: usize = if (i == 0) 0 else tx_boundaries[i - 1];
        return tx[start..tx_boundaries[i]];
    }
};

fn runWith(script_frames: []const []const u8) Error!Success {
    TestPeer.setScript(script_frames);
    var ua = Userauth.init(TestPeer.source(), TestPeer.pins(), TestPeer.transport());
    const session = Session{ .h = Vector.session_id, .session_id = Vector.session_id, .host_key = Vector.host_pk };
    const target = Target{ .user = Vector.user, .host = Vector.host, .port = Vector.port };
    return ua.run(&session, &target);
}

fn expectZero(bytes: []const u8) !void {
    for (bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "userauth: pinned none -> publickey flow, exact RFC 4252 §7 layout" {
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    const frames = [_][]const u8{ &Vector.service_accept, &Vector.failure_publickey_password, &Vector.success };
    TestPeer.setScript(&frames);

    var ua = Userauth.init(TestPeer.source(), TestPeer.pins(), TestPeer.transport());
    const session = Session{ .h = Vector.session_id, .session_id = Vector.session_id, .host_key = Vector.host_pk };
    const target = Target{ .user = Vector.user, .host = Vector.host, .port = Vector.port };
    try std.testing.expectEqual(Success.publickey, try ua.run(&session, &target));

    // Exactly three payloads: service request, none probe, publickey.
    try std.testing.expectEqual(@as(usize, 3), TestPeer.tx_count);

    // Each outgoing payload is byte-exact against the pinned vector.
    try std.testing.expectEqualSlices(u8, &Vector.service_request, TestPeer.sentPayload(0));
    try std.testing.expectEqualSlices(u8, &Vector.none_request, TestPeer.sentPayload(1));
    try std.testing.expectEqualSlices(u8, &Vector.publickey_request, TestPeer.sentPayload(2));

    // The signed bytes are `session_id || request prefix`, asserted
    // byte-for-byte, and the pinned signature verifies with the derived key.
    const signed_wire = TestPeer.sentPayload(2)[0..Vector.signed.len];
    try std.testing.expectEqualSlices(u8, &Vector.signed, signed_wire);
    // The signed layout ends with `string <key blob>`, and the key blob is
    // `string "ssh-ed25519" || string <32-byte pubkey>`.
    try std.testing.expectEqualSlices(u8, &Vector.key_blob, signed_wire[signed_wire.len - Vector.key_blob.len ..]);
    var pk: [host_key_len]u8 = undefined;
    ed25519.derivePublicKey(&pk, &Vector.user_seed);
    try std.testing.expectEqualSlices(u8, &Vector.user_pk, &pk);
    try std.testing.expect(ed25519.verify(&Vector.sig, signed_wire, &pk));

    // Secret hygiene: every staging buffer is zero, and the seed (raw and
    // hex) never appears in any captured byte.
    try expectZero(&ua.cred);
    try expectZero(&ua.seed);
    try expectZero(&ua.sig);
    try std.testing.expectEqual(@as(usize, 0), ua.cred_len);
    try std.testing.expect(std.mem.indexOf(u8, TestPeer.tx[0..TestPeer.tx_len], &Vector.user_seed) == null);
    try std.testing.expect(std.mem.indexOf(u8, TestPeer.tx[0..TestPeer.tx_len], Vector.user_seed_hex) == null);
}

test "userauth: the peer's `none` acceptance short-circuits without the seed" {
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    const frames = [_][]const u8{ &Vector.service_accept, &Vector.success };
    TestPeer.setScript(&frames);

    var ua = Userauth.init(TestPeer.source(), TestPeer.pins(), TestPeer.transport());
    const session = Session{ .h = Vector.session_id, .session_id = Vector.session_id, .host_key = Vector.host_pk };
    const target = Target{ .user = Vector.user, .host = Vector.host, .port = Vector.port };
    try std.testing.expectEqual(Success.none, try ua.run(&session, &target));

    // Two payloads; the store was never read and the staging stays zero.
    try std.testing.expectEqual(@as(usize, 2), TestPeer.tx_count);
    try std.testing.expectEqual(@as(usize, 0), TestPeer.cred_calls);
    try expectZero(&ua.seed);
}

test "userauth: a missing/absent host pin fails closed before anything" {
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    // No pin file at all.
    try std.testing.expectError(error.MissingHostPin, runWith(&.{}));
    try std.testing.expectEqual(@as(usize, 0), TestPeer.tx_len); // nothing sent
    try std.testing.expectEqual(@as(usize, 0), TestPeer.cred_calls); // no secret
    try std.testing.expectEqual(@as(usize, 1), TestPeer.pin_calls);
}

test "userauth: a host-pin mismatch fails closed with its own status" {
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    // The pin names a DIFFERENT key than the one the KEX verified.
    TestPeer.setPins("#v1\npin.example\t2222\tssh-ed25519\t" ++
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c\n");
    try std.testing.expectError(error.HostKeyMismatch, runWith(&.{}));
    try std.testing.expectEqual(@as(usize, 0), TestPeer.tx_len); // nothing sent
    try std.testing.expectEqual(@as(usize, 0), TestPeer.cred_calls); // no secret
}

test "userauth: a missing credential fails closed with its own status" {
    TestPeer.reset();
    TestPeer.setPins(Vector.known_hosts);
    // The store has no `ssh-user-ed25519` entry.
    const frames = [_][]const u8{ &Vector.service_accept, &Vector.failure_publickey_password };
    try std.testing.expectError(error.MissingCredential, runWith(&frames));
    // Service request + none probe only: no publickey packet was sent.
    try std.testing.expectEqual(@as(usize, 2), TestPeer.tx_count);
    try std.testing.expectEqual(@as(usize, 1), TestPeer.cred_calls);
}

test "userauth: a malformed credential fails closed with its own status" {
    TestPeer.reset();
    TestPeer.setPins(Vector.known_hosts);
    TestPeer.setCred("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz");
    const frames = [_][]const u8{ &Vector.service_accept, &Vector.failure_publickey_password };
    try std.testing.expectError(error.BadCredential, runWith(&frames));

    // A short-but-valid-hex value is also refused.
    TestPeer.reset();
    TestPeer.setPins(Vector.known_hosts);
    TestPeer.setCred("4ccd089b28ff96da9db6c346ec114e0f");
    try std.testing.expectError(error.BadCredential, runWith(&frames));
}

test "userauth: a server rejection after a valid publickey is AuthRejected" {
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    var partial_failure = Vector.failure_publickey_password;
    partial_failure[partial_failure.len - 1] = 1; // partial success = true
    const frames = [_][]const u8{ &Vector.service_accept, &Vector.failure_publickey_password, &partial_failure };
    TestPeer.setScript(&frames);

    var ua = Userauth.init(TestPeer.source(), TestPeer.pins(), TestPeer.transport());
    const session = Session{ .h = Vector.session_id, .session_id = Vector.session_id, .host_key = Vector.host_pk };
    const target = Target{ .user = Vector.user, .host = Vector.host, .port = Vector.port };
    try std.testing.expectError(error.AuthRejected, ua.run(&session, &target));

    // The publickey packet WAS sent, and the final partial-success bool was
    // parsed and surfaced.
    try std.testing.expectEqual(@as(usize, 3), TestPeer.tx_count);
    try std.testing.expect(ua.last_partial_success);
}

test "userauth: a wrong user key is refused (signature does not verify)" {
    TestPeer.reset();
    TestPeer.setCred(Vector.wrong_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    const frames = [_][]const u8{ &Vector.service_accept, &Vector.failure_publickey_password, &Vector.failure_publickey_password };
    TestPeer.setScript(&frames);

    var ua = Userauth.init(TestPeer.source(), TestPeer.pins(), TestPeer.transport());
    const session = Session{ .h = Vector.session_id, .session_id = Vector.session_id, .host_key = Vector.host_pk };
    const target = Target{ .user = Vector.user, .host = Vector.host, .port = Vector.port };
    try std.testing.expectError(error.AuthRejected, ua.run(&session, &target));

    // The peer's pinned key (TEST 2) does NOT verify the request signed
    // with the wrong (TEST 3) seed; the wrong key does. That is the
    // server-side "wrong user key refused", observed on the wire.
    const req = TestPeer.sentPayload(2);
    const signed_wire = req[0..Vector.signed.len];
    const sig_wire: [sig_len]u8 = req[req.len - sig_len ..][0..sig_len].*;
    try std.testing.expect(!ed25519.verify(&sig_wire, signed_wire, &Vector.user_pk));
    try std.testing.expect(ed25519.verify(&sig_wire, signed_wire, &Vector.wrong_pk));
}

test "userauth: the service request must be accepted (DISCONNECT fails closed)" {
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    const disconnect = [_]u8{ msg_disconnect, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const frames = [_][]const u8{&disconnect};
    try std.testing.expectError(error.PeerDisconnect, runWith(&frames));
    try std.testing.expectEqual(@as(usize, 1), TestPeer.tx_count);

    // A non-ACCEPT, non-DISCONNECT reply is ServiceRejected.
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    const wrong = [_]u8{ msg_userauth_failure, 0, 0, 0, 0, 0 };
    const frames2 = [_][]const u8{&wrong};
    try std.testing.expectError(error.ServiceRejected, runWith(&frames2));
}

test "userauth: a methods list without publickey fails closed" {
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    const frames = [_][]const u8{ &Vector.service_accept, &Vector.failure_password_only };
    try std.testing.expectError(error.NoSupportedAuth, runWith(&frames));
    try std.testing.expectEqual(@as(usize, 2), TestPeer.tx_count);
}

test "userauth: interleaved banners are skipped and captured" {
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    const frames = [_][]const u8{ &Vector.service_accept, &Vector.banner, &Vector.failure_publickey_password, &Vector.banner, &Vector.success };
    TestPeer.setScript(&frames);

    var ua = Userauth.init(TestPeer.source(), TestPeer.pins(), TestPeer.transport());
    const session = Session{ .h = Vector.session_id, .session_id = Vector.session_id, .host_key = Vector.host_pk };
    const target = Target{ .user = Vector.user, .host = Vector.host, .port = Vector.port };
    try std.testing.expectEqual(Success.publickey, try ua.run(&session, &target));
    try std.testing.expectEqualStrings("Authorized use only", ua.banner[0..ua.banner_len]);
}

test "userauth: a mismatched h/session_id handoff is rejected before any I/O" {
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    var ua = Userauth.init(TestPeer.source(), TestPeer.pins(), TestPeer.transport());
    var session = Session{ .h = Vector.session_id, .session_id = Vector.session_id, .host_key = Vector.host_pk };
    session.session_id[0] ^= 1;
    const target = Target{ .user = Vector.user, .host = Vector.host, .port = Vector.port };
    try std.testing.expectError(error.SessionIdMismatch, ua.run(&session, &target));
    try std.testing.expectEqual(@as(usize, 0), TestPeer.tx_len);
    try std.testing.expectEqual(@as(usize, 0), TestPeer.pin_calls);
    try std.testing.expectEqual(@as(usize, 0), TestPeer.cred_calls);
}

test "userauth: malformed userauth replies fail closed" {
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    // USERAUTH_SUCCESS with a trailing byte.
    const bad_success = [_]u8{ msg_userauth_success, 0x00 };
    const frames = [_][]const u8{ &Vector.service_accept, &Vector.failure_publickey_password, &bad_success };
    try std.testing.expectError(error.BadMessage, runWith(&frames));

    // A malformed FAILURE (bad boolean octet).
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    const bad_failure = [_]u8{ msg_userauth_failure, 0, 0, 0, 1, 'a', 0x02 };
    const frames2 = [_][]const u8{ &Vector.service_accept, &bad_failure };
    try std.testing.expectError(error.BadBool, runWith(&frames2));

    // A KEX message during userauth (a phase violation) is refused.
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    const kexinit = [_]u8{20};
    const frames3 = [_][]const u8{ &Vector.service_accept, &kexinit };
    try std.testing.expectError(error.UnexpectedMessage, runWith(&frames3));
}

test "userauth: a stalled transport fails closed at the bound" {
    TestPeer.reset();
    TestPeer.setCred(Vector.user_seed_hex);
    TestPeer.setPins(Vector.known_hosts);
    // No scripted replies: recv reports "nothing yet" forever.
    try std.testing.expectError(error.Transport, runWith(&.{}));
}

test "userauth: findPin enforces the #v1 schema and the target match" {
    var out: [host_key_len]u8 = undefined;

    // Header required before the first entry.
    try std.testing.expectError(error.BadPinFile, findPin("pin.example\t2222\tssh-ed25519\t" ++
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a\n", "pin.example", 2222, &out));

    // Hex, key type, and port all fail closed for the matching host.
    try std.testing.expectError(error.BadPinLine, findPin("#v1\npin.example\t2222\tssh-rsa\t" ++
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a\n", "pin.example", 2222, &out));
    try std.testing.expectError(error.BadPinLine, findPin("#v1\npin.example\t2222\tssh-ed25519\tzz\n", "pin.example", 2222, &out));
    try std.testing.expectError(error.BadPinLine, findPin("#v1\npin.example\tnotaport\tssh-ed25519\t" ++
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a\n", "pin.example", 2222, &out));

    // A missing target entry (wrong host or wrong port) is MissingHostPin.
    try std.testing.expectError(error.MissingHostPin, findPin(Vector.known_hosts, "other.example", 2222, &out));
    try std.testing.expectError(error.MissingHostPin, findPin(Vector.known_hosts, "pin.example", 2223, &out));

    // A duplicate entry for the same host:port with a different key is
    // ambiguous and refused.
    try std.testing.expectError(error.BadPinLine, findPin(Vector.known_hosts ++
        "pin.example\t2222\tssh-ed25519\t" ++
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c\n", "pin.example", 2222, &out));

    // Comments, blank lines, and CR LF are tolerated; the pin parses.
    const text = "# generated by tooling\r\n\r\n#v1\r\n# comment\r\npin.example\t2222\tssh-ed25519\t" ++
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a\r\n";
    try findPin(text, "pin.example", 2222, &out);
    try std.testing.expectEqualSlices(u8, &Vector.host_pk, &out);

    // A duplicate with the SAME key is harmless.
    try findPin(Vector.known_hosts ++ "#v1\npin.example\t2222\tssh-ed25519\t" ++
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a\n", "pin.example", 2222, &out);
}

test "userauth: parseFailure is strict" {
    const f = try parseFailure(&Vector.failure_publickey_password);
    try std.testing.expectEqualStrings("publickey,password", f.methods);
    try std.testing.expect(!f.partial_success);
    try std.testing.expect(try offersMethod(f.methods, "publickey"));
    try std.testing.expect(!try offersMethod(f.methods, "hostbased"));

    // Wrong message type, trailing bytes, and a bad boolean all fail.
    try std.testing.expectError(error.BadMessage, parseFailure(&.{msg_userauth_success}));
    try std.testing.expectError(error.BadMessage, parseFailure(&.{ msg_userauth_failure, 0, 0, 0, 0, 0, 0 }));
    try std.testing.expectError(error.BadBool, parseFailure(&.{ msg_userauth_failure, 0, 0, 0, 0, 0x02 }));
}
