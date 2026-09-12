//! M51 SSH4 (#1171, ADR 0025 D2/D6/D7): the RFC 4254 session channel.
//!
//! The client half of the SSH connection protocol, layered over the
//! encrypted packet transport (`transport.zig`) through an injected
//! `Transport` seam that carries **decrypted SSH payloads** (the SSH3
//! `userauth.zig` pattern), so the whole state machine runs class-A on the
//! host with a scripted peer and no VM.
//!
//! Supported surface (ADR 0025 D2 — one session channel, nothing else):
//!
//!   * `SSH_MSG_CHANNEL_OPEN` (90) type `session` → `OPEN_CONFIRMATION` (91)
//!     / `OPEN_FAILURE` (92);
//!   * `SSH_MSG_CHANNEL_REQUEST` (98) for `pty-req` (RFC 4254 §6.2,
//!     optional), `exec` and `shell` (§6.5), with `CHANNEL_SUCCESS` (99) /
//!     `CHANNEL_FAILURE` (100) replies;
//!   * `SSH_MSG_CHANNEL_WINDOW_ADJUST` (93), `CHANNEL_DATA` (94),
//!     `EXTENDED_DATA` (95 — stderr flows through as an event), `CHANNEL_EOF`
//!     (96), `CHANNEL_CLOSE` (97);
//!   * the server→client `exit-status` / `exit-signal` requests (§6.10) that
//!     carry a one-shot `exec`'s remote status; unknown requests with
//!     `want_reply` get a `CHANNEL_FAILURE`.
//!
//! Window accounting is exact (RFC 4254 §5.2):
//!
//!   * outbound data is sent in chunks of
//!     `min(remote_window, remote_max_packet)`; `WINDOW_ADJUST` adds credit;
//!     a zero window is waited out only inside a bounded loop — exhaustion
//!     fails closed (`error.WindowExhausted`), never spins;
//!   * inbound data over our advertised window is a protocol violation
//!     (`error.WindowViolation`); when the local window drops to half we emit
//!     a `WINDOW_ADJUST` back up to `initial_window`.
//!
//! Clean close: EOF from either side is tracked; `CHANNEL_CLOSE` is answered
//! exactly once; no message is sent after close.
//!
//! No rekey lives one layer down (`transport.zig`, ADR 0025 D7). This module
//! adds no syscall, reads no secret, and prints nothing.

const std = @import("std");
const wire = @import("wire.zig");

// SSH connection-protocol message numbers (RFC 4254 §9).
pub const msg_disconnect: u8 = 1;
pub const msg_ignore: u8 = 2;
pub const msg_debug: u8 = 4;
pub const msg_global_request: u8 = 80;
pub const msg_request_success: u8 = 81;
pub const msg_request_failure: u8 = 82;
pub const msg_channel_open: u8 = 90;
pub const msg_open_confirmation: u8 = 91;
pub const msg_open_failure: u8 = 92;
pub const msg_window_adjust: u8 = 93;
pub const msg_channel_data: u8 = 94;
pub const msg_extended_data: u8 = 95;
pub const msg_channel_eof: u8 = 96;
pub const msg_channel_close: u8 = 97;
pub const msg_channel_request: u8 = 98;
pub const msg_channel_success: u8 = 99;
pub const msg_channel_failure: u8 = 100;

/// The one channel type M51 opens (ADR 0025 D2).
pub const session_type = "session";
/// The one extended-data type (RFC 4254 §5.2): stderr.
pub const ext_stderr: u32 = 1;
// Request names (RFC 4254 §6.2/§6.5/§6.10).
pub const req_pty = "pty-req";
pub const req_shell = "shell";
pub const req_exec = "exec";
pub const req_exit_status = "exit-status";
pub const req_exit_signal = "exit-signal";

/// Our advertised local flow-control window (bytes) and the largest packet
/// we accept from the peer. RFC 4254 §5.1 requires accepting ≥ 32768-byte
/// packets; the caller's `msg` buffer must hold one.
pub const default_window: u32 = 1 << 17;
pub const default_max_packet: u32 = 32768;

/// Bounded no-progress wait when the injected transport stalls.
pub const wait_limit: usize = 100_000;

pub const Error = wire.Error || error{
    /// The injected transport failed or stalled, or a send was short.
    Transport,
    /// A malformed message, a bad recipient id, or trailing bytes.
    Protocol,
    /// The peer refused the channel (`OPEN_FAILURE`); reason is captured.
    OpenRejected,
    /// A request got `CHANNEL_FAILURE`, or an impossible state transition.
    BadState,
    /// The remote window is 0 and no adjustment arrived within the bound.
    WindowExhausted,
    /// The peer sent more data than the window it was given.
    WindowViolation,
    /// A destination slice is too small, or the message is over the local cap.
    Overlong,
    /// The peer sent SSH_MSG_DISCONNECT.
    PeerDisconnect,
};

/// The injected decrypted-payload transport (the `userauth.zig` seam shape).
/// `send_fn` returns the bytes accepted (must equal `payload.len`) or a
/// negative error; `recv_fn` returns a payload length, 0 for "nothing yet"
/// (the bounded-retry signal), or negative on error.
pub const Transport = struct {
    send_fn: *const fn (payload: []const u8) i64,
    recv_fn: *const fn (out: []u8) i64,
};

/// A request we sent and are awaiting a reply for.
pub const Request = enum { pty, shell, exec };

pub const State = enum { idle, opening, open, closing, closed };

/// A channel event. `data`/`extended.bytes`/`exit_signal` borrow the
/// channel's `msg` buffer and are invalidated by the next `next`/`poll`.
pub const Event = union(enum) {
    data: []const u8,
    extended: struct { code: u32, bytes: []const u8 },
    eof,
    close,
    exit_status: u32,
    exit_signal: []const u8,
    reply: struct { request: Request, ok: bool },
    window_adjust: u32,
    ignored,
};

/// A client session channel. All buffers are caller-owned (static BSS in the
/// app, stack in the tests).
pub const Channel = struct {
    transport: Transport,
    /// Receive scratch: one decrypted payload; also the `msg` slice that
    /// `Event` fields borrow. Must hold the largest incoming packet.
    msg: []u8,
    /// Send scratch: one outgoing message (open/request/data/eof/close).
    tx: []u8,
    local_id: u32,
    remote_id: u32 = 0,
    state: State = .idle,
    sent_eof: bool = false,
    recv_eof: bool = false,
    sent_close: bool = false,
    recv_close: bool = false,
    initial_window: u32 = default_window,
    local_max_packet: u32 = default_max_packet,
    /// Remaining credit we have advertised to the peer.
    local_window: u32 = 0,
    /// Bytes consumed since the last WINDOW_ADJUST we emitted.
    consumed: u32 = 0,
    /// Credit the peer has advertised to us, and its packet cap.
    remote_window: u32 = 0,
    remote_max_packet: u32 = 0,
    pending: ?Request = null,
    /// The last `exit-status` value the peer sent, if any.
    exit_status: ?u32 = null,
    /// The last `OPEN_FAILURE` reason code, if any.
    open_failure_reason: u32 = 0,
    failed: bool = false,

    pub fn init(transport: Transport, msg: []u8, tx: []u8, id: u32) Channel {
        return .{ .transport = transport, .msg = msg, .tx = tx, .local_id = id };
    }

    pub fn isOpen(self: *const Channel) bool {
        return self.state == .open;
    }

    fn fail(self: *Channel) void {
        self.failed = true;
    }

    fn sendRaw(self: *Channel, payload: []const u8) Error!void {
        if (self.failed) return error.Transport;
        const n = self.transport.send_fn(payload);
        if (n != @as(i64, @intCast(payload.len))) {
            self.fail();
            return error.Transport;
        }
    }

    /// One non-blocking transport poll: the payload, null for "nothing yet".
    fn tryRecv(self: *Channel) Error!?[]const u8 {
        if (self.failed) return error.Transport;
        const n = self.transport.recv_fn(self.msg);
        if (n < 0) {
            self.fail();
            return error.Transport;
        }
        if (n == 0) return null;
        const take: usize = @intCast(n);
        if (take > self.msg.len) {
            self.fail();
            return error.Overlong;
        }
        if (take == 0) return error.Protocol;
        return self.msg[0..take];
    }

    /// Send CHANNEL_OPEN for a `session` and wait for the confirmation.
    /// `OPEN_FAILURE` is `error.OpenRejected` with `open_failure_reason` set.
    pub fn open(self: *Channel) Error!void {
        if (self.state != .idle) return error.BadState;
        var w = wire.Writer.init(self.tx);
        try w.writeByte(msg_channel_open);
        try w.writeString(session_type);
        try w.writeUint32(self.local_id);
        try w.writeUint32(self.initial_window);
        try w.writeUint32(self.local_max_packet);
        try self.sendRaw(w.written());

        self.state = .opening;
        self.local_window = self.initial_window;
        var spins: usize = 0;
        while (true) {
            if (spins >= wait_limit) return error.Transport;
            const payload = (try self.tryRecv()) orelse {
                spins += 1;
                continue;
            };
            switch (payload[0]) {
                msg_ignore, msg_debug => continue,
                msg_disconnect => return error.PeerDisconnect,
                msg_open_confirmation => {
                    var r = wire.Reader.init(payload);
                    _ = try r.readByte();
                    const recipient = try r.readUint32();
                    if (recipient != self.local_id) return error.Protocol;
                    self.remote_id = try r.readUint32();
                    self.remote_window = try r.readUint32();
                    self.remote_max_packet = try r.readUint32();
                    // RFC 4254 §5.1: type-specific data MAY follow; ignored.
                    if (self.remote_max_packet == 0) return error.Protocol;
                    self.state = .open;
                    return;
                },
                msg_open_failure => {
                    var r = wire.Reader.init(payload);
                    _ = try r.readByte();
                    const recipient = try r.readUint32();
                    if (recipient != self.local_id) return error.Protocol;
                    self.open_failure_reason = try r.readUint32();
                    _ = try r.readString(); // description
                    _ = try r.readString(); // language tag
                    if (r.remaining() != 0) return error.Protocol;
                    self.state = .closed;
                    return error.OpenRejected;
                },
                else => return error.Protocol,
            }
        }
    }

    fn writeRequest(self: *Channel, kind: Request, body: []const u8) Error!void {
        if (self.state != .open) return error.BadState;
        if (self.pending != null) return error.BadState;
        if (self.remote_id == 0) return error.BadState;
        try self.sendRaw(body);
        self.pending = kind;
    }

    /// `pty-req` (RFC 4254 §6.2). `modes` is the raw terminal-modes string
    /// (empty is valid). The reply arrives as an `.reply` event.
    pub fn requestPty(
        self: *Channel,
        term: []const u8,
        cols: u32,
        rows: u32,
        width_px: u32,
        height_px: u32,
        modes: []const u8,
    ) Error!void {
        var w = wire.Writer.init(self.tx);
        try w.writeByte(msg_channel_request);
        try w.writeUint32(self.remote_id);
        try w.writeString(req_pty);
        try w.writeBool(true);
        try w.writeString(term);
        try w.writeUint32(cols);
        try w.writeUint32(rows);
        try w.writeUint32(width_px);
        try w.writeUint32(height_px);
        try w.writeString(modes);
        try self.writeRequest(.pty, w.written());
    }

    /// `shell` (RFC 4254 §6.5). The reply arrives as an `.reply` event.
    pub fn requestShell(self: *Channel) Error!void {
        var w = wire.Writer.init(self.tx);
        try w.writeByte(msg_channel_request);
        try w.writeUint32(self.remote_id);
        try w.writeString(req_shell);
        try w.writeBool(true);
        try self.writeRequest(.shell, w.written());
    }

    /// `exec` (RFC 4254 §6.5). The reply arrives as an `.reply` event.
    pub fn requestExec(self: *Channel, command: []const u8) Error!void {
        var w = wire.Writer.init(self.tx);
        try w.writeByte(msg_channel_request);
        try w.writeUint32(self.remote_id);
        try w.writeString(req_exec);
        try w.writeBool(true);
        try w.writeString(command);
        try self.writeRequest(.exec, w.written());
    }

    /// One bounded blocking step: the next user-visible event.
    pub fn next(self: *Channel) Error!Event {
        var spins: usize = 0;
        while (true) {
            if (spins >= wait_limit) return error.Transport;
            const payload = (try self.tryRecv()) orelse {
                spins += 1;
                continue;
            };
            if (try self.dispatch(payload)) |ev| return ev;
        }
    }

    /// One non-blocking step: the next user-visible event, or null.
    pub fn poll(self: *Channel) Error!?Event {
        var rounds: usize = 0;
        while (rounds < 64) : (rounds += 1) {
            const payload = (try self.tryRecv()) orelse return null;
            if (try self.dispatch(payload)) |ev| return ev;
        }
        return null;
    }

    /// Parse and apply one incoming payload. Internal messages (IGNORE,
    /// DEBUG, WINDOW_ADJUST bookkeeping, unknown requests) return null.
    fn dispatch(self: *Channel, payload: []const u8) Error!?Event {
        if (payload.len == 0) return error.Protocol;
        switch (payload[0]) {
            msg_ignore, msg_debug => return null,
            msg_disconnect => return error.PeerDisconnect,
            msg_global_request => {
                // We issue no global requests; answer per §4 and continue.
                var r = wire.Reader.init(payload);
                _ = try r.readByte();
                _ = try r.readString();
                const want_reply = try r.readBool();
                if (r.remaining() != 0) return error.Protocol;
                if (want_reply) try self.sendGlobalFailure();
                return .ignored;
            },
            msg_request_success, msg_request_failure => {
                if (payload.len != 1) return error.Protocol;
                return .ignored;
            },
            msg_window_adjust => {
                var r = wire.Reader.init(payload);
                _ = try r.readByte();
                const recipient = try r.readUint32();
                if (recipient != self.local_id) return error.Protocol;
                const add = try r.readUint32();
                if (r.remaining() != 0) return error.Protocol;
                const sum = @as(u64, self.remote_window) + add;
                if (sum > std.math.maxInt(u32)) return error.Protocol;
                self.remote_window = @intCast(sum);
                return .{ .window_adjust = add };
            },
            msg_channel_data => {
                const data = try self.readData(payload, null);
                return .{ .data = data };
            },
            msg_extended_data => {
                var code: u32 = 0;
                const data = try self.readData(payload, &code);
                return .{ .extended = .{ .code = code, .bytes = data } };
            },
            msg_channel_eof => {
                if (payload.len != 1) return error.Protocol;
                self.recv_eof = true;
                return .eof;
            },
            msg_channel_close => {
                var r = wire.Reader.init(payload);
                _ = try r.readByte();
                const recipient = try r.readUint32();
                if (recipient != self.local_id) return error.Protocol;
                if (r.remaining() != 0) return error.Protocol;
                self.recv_close = true;
                if (!self.sent_close) try self.sendClose();
                self.state = .closed;
                return .close;
            },
            msg_channel_request => return try self.readRequest(payload),
            msg_channel_success, msg_channel_failure => {
                var r = wire.Reader.init(payload);
                _ = try r.readByte();
                const recipient = try r.readUint32();
                if (recipient != self.local_id) return error.Protocol;
                if (r.remaining() != 0) return error.Protocol;
                const kind = self.pending orelse return error.Protocol;
                self.pending = null;
                return .{ .reply = .{ .request = kind, .ok = payload[0] == msg_channel_success } };
            },
            else => return error.Protocol,
        }
    }

    fn readData(self: *Channel, payload: []const u8, code_out: ?*u32) Error![]const u8 {
        var r = wire.Reader.init(payload);
        _ = try r.readByte();
        const recipient = try r.readUint32();
        if (recipient != self.local_id) return error.Protocol;
        if (code_out) |c| c.* = try r.readUint32();
        const data = try r.readString();
        if (r.remaining() != 0) return error.Protocol;
        if (data.len > self.local_window) return error.WindowViolation;
        self.local_window -= @intCast(data.len);
        self.consumed += @intCast(data.len);
        try self.maybeReplenish();
        return data;
    }

    /// Emit WINDOW_ADJUST once the local window has fallen to half.
    fn maybeReplenish(self: *Channel) Error!void {
        if (self.local_window > self.initial_window / 2) return;
        const add = self.initial_window - self.local_window;
        var w = wire.Writer.init(self.tx);
        try w.writeByte(msg_window_adjust);
        try w.writeUint32(self.remote_id);
        try w.writeUint32(add);
        try self.sendRaw(w.written());
        self.local_window += add;
        self.consumed = 0;
    }

    fn readRequest(self: *Channel, payload: []const u8) Error!?Event {
        var r = wire.Reader.init(payload);
        _ = try r.readByte();
        const recipient = try r.readUint32();
        if (recipient != self.local_id) return error.Protocol;
        const request = try r.readString();
        const want_reply = try r.readBool();

        if (std.mem.eql(u8, request, req_exit_status)) {
            if (want_reply) return error.Protocol;
            const status = try r.readUint32();
            if (r.remaining() != 0) return error.Protocol;
            self.exit_status = status;
            return .{ .exit_status = status };
        }
        if (std.mem.eql(u8, request, req_exit_signal)) {
            if (want_reply) return error.Protocol;
            const signal = try r.readString();
            _ = try r.readBool(); // core dumped
            _ = try r.readString(); // error message
            _ = try r.readString(); // language tag
            if (r.remaining() != 0) return error.Protocol;
            return .{ .exit_signal = signal };
        }
        if (want_reply) try self.sendFailure();
        return .ignored;
    }

    fn sendFailure(self: *Channel) Error!void {
        var w = wire.Writer.init(self.tx);
        try w.writeByte(msg_channel_failure);
        try w.writeUint32(self.remote_id);
        try self.sendRaw(w.written());
    }

    fn sendGlobalFailure(self: *Channel) Error!void {
        var w = wire.Writer.init(self.tx);
        try w.writeByte(msg_request_failure);
        try self.sendRaw(w.written());
    }

    /// Wait out a zero remote window, bounded. A peer that offers no credit
    /// and no adjustment fails closed; any non-adjust traffic while blocked
    /// is treated as exhaustion (the window is a hard safety net).
    fn awaitWindow(self: *Channel) Error!void {
        var spins: usize = 0;
        while (self.remote_window == 0) {
            if (spins >= wait_limit) return error.WindowExhausted;
            if (self.recv_close or self.recv_eof) return error.WindowExhausted;
            const payload = (try self.tryRecv()) orelse {
                spins += 1;
                continue;
            };
            switch (payload[0]) {
                msg_ignore, msg_debug => {},
                msg_disconnect => return error.PeerDisconnect,
                msg_window_adjust => {
                    if (try self.dispatch(payload)) |_| {}
                },
                else => return error.WindowExhausted,
            }
            spins += 1;
        }
    }

    /// Send channel data in chunks of ≤ min(remote_window, remote_max_packet).
    /// A zero window waits, bounded; exhaustion fails closed.
    pub fn sendData(self: *Channel, data: []const u8) Error!void {
        if (self.state != .open) return error.BadState;
        var off: usize = 0;
        while (off < data.len) {
            while (self.remote_window == 0) try self.awaitWindow();
            const take: usize = @min(
                data.len - off,
                @min(@as(usize, self.remote_window), @as(usize, self.remote_max_packet)),
            );
            var w = wire.Writer.init(self.tx);
            try w.writeByte(msg_channel_data);
            try w.writeUint32(self.remote_id);
            try w.writeString(data[off .. off + take]);
            try self.sendRaw(w.written());
            self.remote_window -= @intCast(take);
            off += take;
        }
    }

    /// Send CHANNEL_EOF exactly once.
    pub fn sendEof(self: *Channel) Error!void {
        if (self.state != .open and self.state != .closing) return error.BadState;
        if (self.sent_eof) return error.BadState;
        var w = wire.Writer.init(self.tx);
        try w.writeByte(msg_channel_eof);
        try w.writeUint32(self.remote_id);
        try self.sendRaw(w.written());
        self.sent_eof = true;
    }

    /// Send CHANNEL_CLOSE exactly once and mark the channel closed.
    pub fn sendClose(self: *Channel) Error!void {
        if (self.sent_close) return;
        if (self.remote_id == 0 and self.state != .closed) return error.BadState;
        var w = wire.Writer.init(self.tx);
        try w.writeByte(msg_channel_close);
        try w.writeUint32(self.remote_id);
        try self.sendRaw(w.written());
        self.sent_close = true;
        self.state = .closed;
    }
};

// ---------------------------------------------------------------------------
// Host tests (class A; injected transport, scripted peer, no VM)
// ---------------------------------------------------------------------------

/// The scripted peer harness: length-prefixed incoming payloads, captured
/// outgoing payloads with per-send boundaries (the `userauth.zig` pattern).
const TestPeer = struct {
    var tx: [8192]u8 = undefined;
    var tx_len: usize = 0;
    var tx_boundaries: [64]usize = undefined;
    var tx_count: usize = 0;

    var feed: [70000]u8 = undefined;
    var feed_len: usize = 0;
    var feed_pos: usize = 0;

    fn reset() void {
        tx_len = 0;
        tx_count = 0;
        feed_len = 0;
        feed_pos = 0;
        @memset(&tx, 0);
        @memset(&feed, 0);
    }

    /// Clear the script (the feed); use with `appendScript` when the frames
    /// share a scratch buffer (each append copies before the next write).
    fn scriptReset() void {
        feed_len = 0;
        feed_pos = 0;
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

    fn appendScript(frames: []const []const u8) void {
        for (frames) |f| {
            std.debug.assert(feed_len + 4 + f.len <= feed.len);
            std.mem.writeInt(u32, feed[feed_len..][0..4], @intCast(f.len), .big);
            feed_len += 4;
            @memcpy(feed[feed_len..][0..f.len], f);
            feed_len += f.len;
        }
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

    fn transport() Transport {
        return .{ .send_fn = sendFn, .recv_fn = recvFn };
    }

    fn sent(i: usize) []const u8 {
        const start: usize = if (i == 0) 0 else tx_boundaries[i - 1];
        return tx[start..tx_boundaries[i]];
    }
};

fn msg1(out: []u8, kind: u8, a: u32) []const u8 {
    var w = wire.Writer.init(out);
    w.writeByte(kind) catch unreachable;
    w.writeUint32(a) catch unreachable;
    return w.written();
}

fn openConfirmation(out: []u8, recipient: u32, sender: u32, window: u32, max_packet: u32) []const u8 {
    var w = wire.Writer.init(out);
    w.writeByte(msg_open_confirmation) catch unreachable;
    w.writeUint32(recipient) catch unreachable;
    w.writeUint32(sender) catch unreachable;
    w.writeUint32(window) catch unreachable;
    w.writeUint32(max_packet) catch unreachable;
    return w.written();
}

fn openFailure(out: []u8, recipient: u32, reason: u32) []const u8 {
    var w = wire.Writer.init(out);
    w.writeByte(msg_open_failure) catch unreachable;
    w.writeUint32(recipient) catch unreachable;
    w.writeUint32(reason) catch unreachable;
    w.writeString("no sessions") catch unreachable;
    w.writeString("en") catch unreachable;
    return w.written();
}

fn channelData(out: []u8, recipient: u32, data: []const u8) []const u8 {
    var w = wire.Writer.init(out);
    w.writeByte(msg_channel_data) catch unreachable;
    w.writeUint32(recipient) catch unreachable;
    w.writeString(data) catch unreachable;
    return w.written();
}

fn extendedData(out: []u8, recipient: u32, code: u32, data: []const u8) []const u8 {
    var w = wire.Writer.init(out);
    w.writeByte(msg_extended_data) catch unreachable;
    w.writeUint32(recipient) catch unreachable;
    w.writeUint32(code) catch unreachable;
    w.writeString(data) catch unreachable;
    return w.written();
}

fn windowAdjust(out: []u8, recipient: u32, add: u32) []const u8 {
    var w = wire.Writer.init(out);
    w.writeByte(msg_window_adjust) catch unreachable;
    w.writeUint32(recipient) catch unreachable;
    w.writeUint32(add) catch unreachable;
    return w.written();
}

fn exitStatus(out: []u8, recipient: u32, status: u32) []const u8 {
    var w = wire.Writer.init(out);
    w.writeByte(msg_channel_request) catch unreachable;
    w.writeUint32(recipient) catch unreachable;
    w.writeString(req_exit_status) catch unreachable;
    w.writeBool(false) catch unreachable;
    w.writeUint32(status) catch unreachable;
    return w.written();
}

fn requestReply(out: []u8, kind: u8, recipient: u32) []const u8 {
    var w = wire.Writer.init(out);
    w.writeByte(kind) catch unreachable;
    w.writeUint32(recipient) catch unreachable;
    return w.written();
}

const test_local_id = 7;

fn makeChannel() Channel {
    const S = struct {
        var msg: [70000]u8 = undefined;
        var tx: [4096]u8 = undefined;
    };
    return Channel.init(TestPeer.transport(), &S.msg, &S.tx, test_local_id);
}

const confirm_remote_id: u32 = 42;

test "channel: open -> exec -> data/extended/exit-status -> eof -> close" {
    TestPeer.reset();
    var cbuf: [256]u8 = undefined;
    const frames = [_][]const u8{
        openConfirmation(&cbuf, test_local_id, confirm_remote_id, 1 << 16, 32768),
    };
    TestPeer.setScript(&frames);

    var ch = makeChannel();
    try ch.open();
    try std.testing.expect(ch.isOpen());
    try std.testing.expectEqual(confirm_remote_id, ch.remote_id);

    // The OPEN packet is byte-exact: byte 90, string "session", our id,
    // our initial window, our max packet.
    {
        var want: [32]u8 = undefined;
        var w = wire.Writer.init(&want);
        try w.writeByte(msg_channel_open);
        try w.writeString(session_type);
        try w.writeUint32(test_local_id);
        try w.writeUint32(default_window);
        try w.writeUint32(default_max_packet);
        try std.testing.expectEqualSlices(u8, w.written(), TestPeer.sent(0));
    }

    // exec request -> CHANNEL_SUCCESS.
    var rbuf: [16]u8 = undefined;
    TestPeer.setScript(&.{requestReply(&rbuf, msg_channel_success, test_local_id)});
    try ch.requestExec("id -u");
    try std.testing.expectEqual(Request.exec, ch.pending.?);
    {
        var want: [128]u8 = undefined;
        var w = wire.Writer.init(&want);
        try w.writeByte(msg_channel_request);
        try w.writeUint32(confirm_remote_id);
        try w.writeString(req_exec);
        try w.writeBool(true);
        try w.writeString("id -u");
        try std.testing.expectEqualSlices(u8, w.written(), TestPeer.sent(1));
    }
    {
        const ev = try ch.next();
        try std.testing.expect(ev == .reply);
        try std.testing.expectEqual(Request.exec, ev.reply.request);
        try std.testing.expect(ev.reply.ok);
    }

    // Remote stdout, remote stderr, exit-status, EOF, CLOSE — in order.
    // Each frame is appended before the next one reuses `dbuf`, so no two
    // queued frames alias the same scratch.
    var dbuf: [256]u8 = undefined;
    TestPeer.scriptReset();
    TestPeer.appendScript(&.{channelData(&dbuf, test_local_id, "uid=1000\n")});
    TestPeer.appendScript(&.{extendedData(&dbuf, test_local_id, ext_stderr, "warning\n")});
    TestPeer.appendScript(&.{exitStatus(&dbuf, test_local_id, 3)});
    TestPeer.appendScript(&.{&.{msg_channel_eof}});
    TestPeer.appendScript(&.{msg1(&dbuf, msg_channel_close, test_local_id)});

    {
        const ev = try ch.next();
        try std.testing.expectEqualStrings("uid=1000\n", ev.data);
    }
    {
        const ev = try ch.next();
        try std.testing.expectEqual(ext_stderr, ev.extended.code);
        try std.testing.expectEqualStrings("warning\n", ev.extended.bytes);
    }
    {
        const ev = try ch.next();
        try std.testing.expectEqual(@as(u32, 3), ev.exit_status);
        try std.testing.expectEqual(@as(?u32, 3), ch.exit_status);
    }
    try std.testing.expect((try ch.next()) == .eof);
    try std.testing.expect(ch.recv_eof);
    try std.testing.expect((try ch.next()) == .close);
    try std.testing.expectEqual(State.closed, ch.state);
    // CLOSE was answered exactly once: OPEN, exec request, our CLOSE.
    try std.testing.expectEqual(@as(usize, 3), TestPeer.tx_count);
    {
        var want: [8]u8 = undefined;
        var w = wire.Writer.init(&want);
        try w.writeByte(msg_channel_close);
        try w.writeUint32(confirm_remote_id);
        try std.testing.expectEqualSlices(u8, w.written(), TestPeer.sent(2));
    }
    // Closed means closed: further sends are refused.
    try std.testing.expectError(error.BadState, ch.sendData("more"));
}

test "channel: OPEN_FAILURE fails closed with the reason code captured" {
    TestPeer.reset();
    var fbuf: [64]u8 = undefined;
    TestPeer.setScript(&.{openFailure(&fbuf, test_local_id, 1)});
    var ch = makeChannel();
    try std.testing.expectError(error.OpenRejected, ch.open());
    try std.testing.expectEqual(@as(u32, 1), ch.open_failure_reason);
    try std.testing.expectEqual(State.closed, ch.state);
}

test "channel: pty-req and shell dispatch the exact RFC 4254 §6.2/§6.5 bytes" {
    TestPeer.reset();
    var cbuf: [256]u8 = undefined;
    var rbuf: [16]u8 = undefined;
    const frames = [_][]const u8{
        openConfirmation(&cbuf, test_local_id, confirm_remote_id, 1 << 16, 32768),
    };
    TestPeer.setScript(&frames);
    var ch = makeChannel();
    try ch.open();

    TestPeer.setScript(&.{
        requestReply(&rbuf, msg_channel_success, test_local_id),
        requestReply(&rbuf, msg_channel_success, test_local_id),
    });
    try ch.requestPty("xterm", 80, 24, 640, 480, "");
    try std.testing.expectEqual(Request.pty, ch.pending.?);
    {
        var want: [128]u8 = undefined;
        var w = wire.Writer.init(&want);
        try w.writeByte(msg_channel_request);
        try w.writeUint32(confirm_remote_id);
        try w.writeString(req_pty);
        try w.writeBool(true);
        try w.writeString("xterm");
        try w.writeUint32(80);
        try w.writeUint32(24);
        try w.writeUint32(640);
        try w.writeUint32(480);
        try w.writeString("");
        try std.testing.expectEqualSlices(u8, w.written(), TestPeer.sent(1));
    }
    {
        const ev = try ch.next();
        try std.testing.expectEqual(Request.pty, ev.reply.request);
        try std.testing.expect(ev.reply.ok);
    }

    try ch.requestShell();
    {
        var want: [64]u8 = undefined;
        var w = wire.Writer.init(&want);
        try w.writeByte(msg_channel_request);
        try w.writeUint32(confirm_remote_id);
        try w.writeString(req_shell);
        try w.writeBool(true);
        try std.testing.expectEqualSlices(u8, w.written(), TestPeer.sent(2));
    }
    {
        const ev = try ch.next();
        try std.testing.expectEqual(Request.shell, ev.reply.request);
        try std.testing.expect(ev.reply.ok);
    }

    // A second request while one is pending is a state error.
    try ch.requestExec("x");
    try std.testing.expectError(error.BadState, ch.requestShell());
}

test "channel: a refused request surfaces ok=false with the request kind" {
    TestPeer.reset();
    var cbuf: [256]u8 = undefined;
    var rbuf: [16]u8 = undefined;
    TestPeer.setScript(&.{openConfirmation(&cbuf, test_local_id, confirm_remote_id, 1 << 16, 32768)});
    var ch = makeChannel();
    try ch.open();
    TestPeer.setScript(&.{requestReply(&rbuf, msg_channel_failure, test_local_id)});
    try ch.requestExec("false");
    const ev = try ch.next();
    try std.testing.expect(!ev.reply.ok);
    try std.testing.expectEqual(Request.exec, ev.reply.request);
}

test "channel: data chunks to min(remote window, remote max packet) and honors WINDOW_ADJUST" {
    TestPeer.reset();
    var cbuf: [256]u8 = undefined;
    // Remote offers 100 bytes of window with a 40-byte packet cap.
    TestPeer.setScript(&.{openConfirmation(&cbuf, test_local_id, confirm_remote_id, 100, 40)});
    var ch = makeChannel();
    try ch.open();
    try std.testing.expectEqual(@as(u32, 40), ch.remote_max_packet);

    var data: [150]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xff);

    // The first 100 bytes fit (40 + 40 + 20), then the window is zero and
    // the peer grants 60 more mid-send.
    var abuf: [16]u8 = undefined;
    TestPeer.setScript(&.{
        windowAdjust(&abuf, test_local_id, 60),
        windowAdjust(&abuf, test_local_id, 60),
    });
    try ch.sendData(&data);

    // 100 + 60 credit granted, 150 sent: exactly 10 bytes of credit remain.
    try std.testing.expectEqual(@as(u32, 10), ch.remote_window);
    // Outgoing sends: OPEN was 1; the data packets are 40, 40, 20, 40, 10.
    try std.testing.expectEqual(@as(usize, 6), TestPeer.tx_count);
    const sizes = [_]usize{ 40, 40, 20, 40, 10 };
    for (sizes, 0..) |size, i| {
        const payload = TestPeer.sent(i + 1);
        try std.testing.expectEqual(@as(u8, msg_channel_data), payload[0]);
        try std.testing.expectEqual(@as(usize, 1 + 4 + 4 + size), payload.len);
        try std.testing.expectEqual(@as(u32, confirm_remote_id), std.mem.readInt(u32, payload[1..5], .big));
        try std.testing.expectEqual(@as(u32, @intCast(size)), std.mem.readInt(u32, payload[5..9], .big));
    }
    // And the bytes reassemble exactly.
    var joined: [150]u8 = undefined;
    var off: usize = 0;
    for (sizes, 0..) |size, i| {
        const payload = TestPeer.sent(i + 1);
        @memcpy(joined[off .. off + size], payload[9 .. 9 + size]);
        off += size;
    }
    try std.testing.expectEqualSlices(u8, &data, &joined);
}

test "channel: window exhaustion fails closed (no adjustment, no spin)" {
    TestPeer.reset();
    var cbuf: [256]u8 = undefined;
    TestPeer.setScript(&.{openConfirmation(&cbuf, test_local_id, confirm_remote_id, 10, 40)});
    var ch = makeChannel();
    try ch.open();

    var data: [100]u8 = undefined;
    @memset(&data, 0x5a);
    // 10 bytes go out; the window is then zero and the transport returns
    // "nothing yet" forever: a bounded fail-closed, not an infinite loop.
    try std.testing.expectError(error.WindowExhausted, ch.sendData(&data));
    try std.testing.expectEqual(@as(usize, 2), TestPeer.tx_count);
    try std.testing.expectEqual(@as(u32, 0), ch.remote_window);
}

test "channel: inbound data over the advertised window fails closed" {
    TestPeer.reset();
    var cbuf: [256]u8 = undefined;
    TestPeer.setScript(&.{openConfirmation(&cbuf, test_local_id, confirm_remote_id, 1 << 16, 32768)});
    var ch = makeChannel();
    try ch.open();
    // Shrink our advertised window so the peer's data must violate it.
    ch.initial_window = 4;
    ch.local_window = 4;
    var dbuf: [64]u8 = undefined;
    TestPeer.setScript(&.{channelData(&dbuf, test_local_id, "too-much")});
    try std.testing.expectError(error.WindowViolation, ch.next());
}

test "channel: WINDOW_ADJUST replenishes our local window exactly once at half" {
    TestPeer.reset();
    var cbuf: [256]u8 = undefined;
    TestPeer.setScript(&.{openConfirmation(&cbuf, test_local_id, confirm_remote_id, 1 << 16, 32768)});
    var ch = makeChannel();
    try ch.open();
    const full = ch.initial_window;

    // A half-window's worth of data triggers exactly one adjust back to full.
    var dbuf: [default_window / 2 + 64]u8 = undefined;
    var big: [default_window / 2]u8 = undefined;
    @memset(&big, 0x41);
    TestPeer.setScript(&.{channelData(&dbuf, test_local_id, &big)});
    const ev = try ch.next();
    try std.testing.expectEqual(@as(usize, big.len), ev.data.len);
    try std.testing.expectEqual(@as(u32, full), ch.local_window);
    try std.testing.expectEqual(@as(usize, 2), TestPeer.tx_count); // OPEN + ADJUST
    {
        const payload = TestPeer.sent(1);
        try std.testing.expectEqual(@as(u8, msg_window_adjust), payload[0]);
        try std.testing.expectEqual(@as(u32, confirm_remote_id), std.mem.readInt(u32, payload[1..5], .big));
        try std.testing.expectEqual(@as(u32, full / 2), std.mem.readInt(u32, payload[5..9], .big));
    }
}

test "channel: EOF/close clean order — we send EOF, answer CLOSE once" {
    TestPeer.reset();
    var cbuf: [256]u8 = undefined;
    TestPeer.setScript(&.{openConfirmation(&cbuf, test_local_id, confirm_remote_id, 1 << 16, 32768)});
    var ch = makeChannel();
    try ch.open();

    try ch.sendEof();
    try std.testing.expectError(error.BadState, ch.sendEof());
    try ch.sendClose();
    try ch.sendClose(); // idempotent

    var dbuf: [64]u8 = undefined;
    TestPeer.setScript(&.{
        &.{msg_channel_eof},
        msg1(&dbuf, msg_channel_close, test_local_id),
    });
    try std.testing.expect((try ch.next()) == .eof);
    try std.testing.expect((try ch.next()) == .close);
    try std.testing.expectEqual(State.closed, ch.state);
}

test "channel: unknown requests get CHANNEL_FAILURE; exit-signal is surfaced" {
    TestPeer.reset();
    var cbuf: [256]u8 = undefined;
    TestPeer.setScript(&.{openConfirmation(&cbuf, test_local_id, confirm_remote_id, 1 << 16, 32768)});
    var ch = makeChannel();
    try ch.open();

    var rbuf: [256]u8 = undefined;
    var w = wire.Writer.init(&rbuf);
    try w.writeByte(msg_channel_request);
    try w.writeUint32(test_local_id);
    try w.writeString("xon-xoff");
    try w.writeBool(true);
    try w.writeBool(true);
    TestPeer.setScript(&.{w.written()});
    try std.testing.expect((try ch.next()) == .ignored);
    {
        const payload = TestPeer.sent(1);
        try std.testing.expectEqual(@as(u8, msg_channel_failure), payload[0]);
        try std.testing.expectEqual(@as(u32, confirm_remote_id), std.mem.readInt(u32, payload[1..5], .big));
    }

    // exit-signal: want_reply false, surfaces the signal name.
    var sbuf: [256]u8 = undefined;
    var sw = wire.Writer.init(&sbuf);
    try sw.writeByte(msg_channel_request);
    try sw.writeUint32(test_local_id);
    try sw.writeString(req_exit_signal);
    try sw.writeBool(false);
    try sw.writeString("SIGKILL");
    try sw.writeBool(false);
    try sw.writeString("killed");
    try sw.writeString("");
    TestPeer.setScript(&.{sw.written()});
    const ev = try ch.next();
    try std.testing.expectEqualStrings("SIGKILL", ev.exit_signal);
}

test "channel: malformed messages and wrong recipient ids fail closed" {
    TestPeer.reset();
    var cbuf: [256]u8 = undefined;
    TestPeer.setScript(&.{openConfirmation(&cbuf, test_local_id, confirm_remote_id, 1 << 16, 32768)});
    var ch = makeChannel();
    try ch.open();

    // Data addressed to another channel.
    var dbuf: [64]u8 = undefined;
    TestPeer.setScript(&.{channelData(&dbuf, test_local_id + 1, "x")});
    try std.testing.expectError(error.Protocol, ch.next());

    // A truncated window-adjust.
    TestPeer.reset();
    TestPeer.setScript(&.{openConfirmation(&cbuf, test_local_id, confirm_remote_id, 1 << 16, 32768)});
    var ch2 = makeChannel();
    try ch2.open();
    TestPeer.setScript(&.{&.{ msg_window_adjust, 0, 0 }});
    try std.testing.expectError(error.ShortRead, ch2.next());

    // An unsolicited CHANNEL_SUCCESS with no pending request.
    const rbuf = [_]u8{ msg_channel_success, 0, 0, 0, test_local_id };
    TestPeer.setScript(&.{&rbuf});
    try std.testing.expectError(error.Protocol, ch2.next());
}

test "channel: a peer DISCONNECT fails closed with its own status" {
    TestPeer.reset();
    var cbuf: [256]u8 = undefined;
    TestPeer.setScript(&.{openConfirmation(&cbuf, test_local_id, confirm_remote_id, 1 << 16, 32768)});
    var ch = makeChannel();
    try ch.open();

    const disconnect = [_]u8{ msg_disconnect, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0 };
    TestPeer.setScript(&.{&disconnect});
    try std.testing.expectError(error.PeerDisconnect, ch.next());
}

test "channel: a stalled transport fails closed at the bound" {
    TestPeer.reset();
    var ch = makeChannel();
    // No scripted replies at all.
    try std.testing.expectError(error.Transport, ch.open());
}
