//! The TCP → TLS stream adapter (card TLS13-C7).
//!
//! The kernel TCP seam (`sys_tcp_connect/send/recv/close`, slots 30–33) is
//! single-connection, has **no reassembly**, and exposes a **one-slot RX
//! buffer** of `chunk_max = 192` bytes. A TLS record is variable-length and
//! routinely much larger (a server's Certificate flight is several kilobytes),
//! so the adapter has to bridge a framed byte stream onto a chunked,
//! loss-recoverable seam:
//!
//!   * **reads accumulate**: `recv` returns at most 192 bytes, so `read`
//!     loops, appending into a bounded caller-owned accumulator, until it can
//!     satisfy the client's request;
//!   * **`0` means "nothing yet"**, not EOF — the kernel's retransmit slot is
//!     what recovers a dropped segment — so a zero poll is retried up to
//!     `idle_limit` times before the peer is declared dead;
//!   * **writes are paced**: the kernel's TX retransmit buffer holds exactly
//!     one segment, so each ≤192-byte send is followed by a drain so the next
//!     segment is not clobbered. Bytes that arrive during the drain are
//!     *stashed*, never discarded;
//!   * **fails closed**: an over-cap chunk, a failed accumulator, or a
//!     negative seam return is an error, never a truncate-and-continue.
//!
//! The seam is injected (`Ops`), mirroring `ssh/stream.zig`, so every
//! property above is host-testable without a NIC. Production wires it to
//! `sys_tcp_*` via `sysOps()`.

const std = @import("std");
const tls_client = @import("client.zig");

/// Mirror of `kernel/src/tcp.zig` `payload_max`: the largest chunk
/// `sys_tcp_recv` returns and `sys_tcp_send` accepts.
pub const chunk_max: usize = 192;

/// Default bound on consecutive empty polls before the peer is declared dead.
pub const default_idle_limit: usize = 200_000;

pub const Error = error{
    /// The seam failed, or the peer stopped producing within `idle_limit`.
    Closed,
    /// The bounded accumulator cannot hold what the peer sent (fail closed).
    Overflow,
};

/// The injected transport seam (function pointers, the `netauth.zig` pattern).
pub const Ops = struct {
    recv_fn: *const fn (out: []u8) i64,
    send_fn: *const fn (data: []const u8) i64,
    close_fn: *const fn () void,
};

/// Guest: the real `sys_tcp_*` slots. Not referenced by the host tests.
pub fn sysOps() Ops {
    const ui = @import("ui");
    return .{ .recv_fn = struct {
        fn f(out: []u8) i64 {
            return ui.tcp_recv(out);
        }
    }.f, .send_fn = struct {
        fn f(data: []const u8) i64 {
            return ui.tcp_send(data);
        }
    }.f, .close_fn = struct {
        fn f() void {
            _ = ui.tcp_close();
        }
    }.f };
}

/// The adapter. `buf` is caller-owned (a static BSS array in the app) and
/// bounds how much unread data may be held.
pub const Stream = struct {
    ops: Ops,
    buf: []u8,
    len: usize = 0,
    failed: bool = false,
    idle_limit: usize = default_idle_limit,

    pub fn init(ops: Ops, buf: []u8) Stream {
        return .{ .ops = ops, .buf = buf };
    }

    /// The vtable the TLS client consumes. `self` must outlive the client.
    pub fn transport(self: *Stream) tls_client.Transport {
        return .{ .ctx = self, .readFn = readFn, .writeFn = writeFn };
    }

    fn readFn(ctx: ?*anyopaque, out: []u8) anyerror!usize {
        const s: *Stream = @ptrCast(@alignCast(ctx.?));
        return s.read(out);
    }

    fn writeFn(ctx: ?*anyopaque, data: []const u8) anyerror!usize {
        const s: *Stream = @ptrCast(@alignCast(ctx.?));
        return s.write(data);
    }

    /// Fill `out`, pulling from the seam as needed. A short read only happens
    /// on failure, in which case what was already read is returned.
    pub fn read(self: *Stream, out: []u8) !usize {
        var got: usize = 0;
        while (got < out.len) {
            if (self.len == 0) {
                self.pumpOnce() catch |e| {
                    self.failed = true;
                    if (got > 0) return got;
                    return e;
                };
            }
            const take = @min(self.len, out.len - got);
            @memcpy(out[got..][0..take], self.buf[0..take]);
            std.mem.copyForwards(u8, self.buf[0..], self.buf[take..self.len]);
            self.len -= take;
            got += take;
        }
        return got;
    }

    /// Poll the seam until one non-empty chunk arrives, then accumulate it.
    fn pumpOnce(self: *Stream) !void {
        var chunk: [chunk_max]u8 = undefined;
        var idle: usize = 0;
        while (true) {
            const n = self.ops.recv_fn(&chunk);
            if (n < 0) return Error.Closed;
            if (n == 0) {
                idle += 1;
                if (idle >= self.idle_limit) return Error.Closed;
                continue;
            }
            const count: usize = @intCast(n);
            if (count > chunk_max) return Error.Overflow;
            if (count > self.buf.len - self.len) return Error.Overflow;
            @memcpy(self.buf[self.len..][0..count], chunk[0..count]);
            self.len += count;
            return;
        }
    }

    /// Send everything, one ≤192-byte segment at a time, draining between
    /// segments so the single TX retransmit slot is freed and any arriving
    /// RX bytes are stashed rather than lost.
    pub fn write(self: *Stream, data: []const u8) !usize {
        var off: usize = 0;
        while (off < data.len) {
            const take = @min(chunk_max, data.len - off);
            const n = self.ops.send_fn(data[off..][0..take]);
            if (n <= 0) {
                self.failed = true;
                return if (off > 0) off else Error.Closed;
            }
            off += @intCast(n);
            try self.drainOnce();
        }
        return off;
    }

    fn drainOnce(self: *Stream) !void {
        var chunk: [chunk_max]u8 = undefined;
        const n = self.ops.recv_fn(&chunk);
        if (n < 0) {
            self.failed = true;
            return Error.Closed;
        }
        if (n == 0) return;
        const count: usize = @intCast(n);
        if (count > chunk_max) return Error.Overflow;
        if (count > self.buf.len - self.len) {
            self.failed = true;
            return Error.Overflow;
        }
        @memcpy(self.buf[self.len..][0..count], chunk[0..count]);
        self.len += count;
    }

    pub fn close(self: *Stream) void {
        self.ops.close_fn();
    }
};

// ---------------------------------------------------------------------------
// Host tests: the seam is injected, so the chunking behaviour is provable
// without a NIC.
// ---------------------------------------------------------------------------

/// A fake seam that replays a byte stream in chunks of a chosen size, with an
/// optional "nothing yet" (0) response every N polls.
const FakeSeam = struct {
    stream: []const u8,
    pos: usize = 0,
    chunk: usize,
    poll_every: usize = 0,
    polls: usize = 0,
    sent: [4096]u8 = undefined,
    sent_len: usize = 0,
    max_send: usize = 0,
    fail_after: usize = std.math.maxInt(usize),
    closed: bool = false,

    fn recv(self: *FakeSeam, out: []u8) i64 {
        if (self.closed) return -1;
        self.polls += 1;
        if (self.poll_every != 0 and self.polls % self.poll_every == 0) return 0; // "nothing yet"
        if (self.pos >= self.stream.len) return 0;
        const take = @min(@min(self.chunk, out.len), self.stream.len - self.pos);
        @memcpy(out[0..take], self.stream[self.pos..][0..take]);
        self.pos += take;
        return @intCast(take);
    }

    fn send(self: *FakeSeam, data: []const u8) i64 {
        if (self.closed) return -1;
        if (self.sent_len + data.len > self.sent.len) return -1;
        if (data.len > self.max_send) self.max_send = data.len;
        @memcpy(self.sent[self.sent_len..][0..data.len], data);
        self.sent_len += data.len;
        if (self.sent_len > self.fail_after) self.closed = true;
        return @intCast(data.len);
    }

    fn closeFn() void {}

    fn ops() Ops {
        return .{ .recv_fn = recvTramp, .send_fn = sendTramp, .close_fn = closeTramp };
    }
    var g_self: ?*FakeSeam = null;
    fn recvTramp(out: []u8) i64 {
        return g_self.?.recv(out);
    }
    fn sendTramp(data: []const u8) i64 {
        return g_self.?.send(data);
    }
    fn closeTramp() void {
        FakeSeam.closeFn();
    }
};

test "tls stream: a 192-byte-chunked stream is reassembled byte-exactly" {
    // 5000 bytes delivered in 192-byte segments, the kernel's slot size.
    var payload: [5000]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    var seam = FakeSeam{ .stream = &payload, .chunk = chunk_max };
    FakeSeam.g_self = &seam;
    var acc: [4096]u8 = undefined;
    var s = Stream.init(FakeSeam.ops(), &acc);

    var got: [5000]u8 = undefined;
    const n = try s.read(&got);
    try std.testing.expectEqual(@as(usize, 5000), n);
    try std.testing.expectEqualSlices(u8, &payload, &got);
}

test "tls stream: whole records survive when the seam only yields short chunks" {
    // The client calls read with an exact length (a record header, then the
    // body). Deliver 1 byte at a time to prove the adapter does not depend on
    // chunk boundaries.
    const msg = "TLS record header and body";
    for ([_]usize{ 1, 2, 3, 17, 64, 192 }) |c| {
        var seam = FakeSeam{ .stream = msg, .chunk = c };
        FakeSeam.g_self = &seam;
        var acc: [256]u8 = undefined;
        var s = Stream.init(FakeSeam.ops(), &acc);
        var hdr: [5]u8 = undefined;
        _ = try s.read(&hdr);
        try std.testing.expectEqualSlices(u8, msg[0..5], &hdr);
        var rest: [msg.len - 5]u8 = undefined;
        _ = try s.read(&rest);
        try std.testing.expectEqualSlices(u8, msg[5..], &rest);
    }
}

test "tls stream: a zero poll is 'nothing yet', not EOF" {
    // Every third poll returns 0, as the kernel does when the retransmit slot
    // has not been refilled. The read must still complete.
    var payload: [600]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);
    var seam = FakeSeam{ .stream = &payload, .chunk = 100, .poll_every = 3 };
    FakeSeam.g_self = &seam;
    var acc: [2048]u8 = undefined;
    var s = Stream.init(FakeSeam.ops(), &acc);
    var got: [600]u8 = undefined;
    const n = try s.read(&got);
    try std.testing.expectEqual(@as(usize, 600), n);
    try std.testing.expectEqualSlices(u8, &payload, &got);
}

test "tls stream: writes are paced to one 192-byte segment at a time" {
    var seam = FakeSeam{ .stream = "", .chunk = chunk_max };
    FakeSeam.g_self = &seam;
    var acc: [4096]u8 = undefined;
    var s = Stream.init(FakeSeam.ops(), &acc);

    var out: [1000]u8 = undefined;
    for (&out, 0..) |*b, i| b.* = @truncate(i);
    const n = try s.write(&out);
    try std.testing.expectEqual(@as(usize, 1000), n);
    // Nothing exceeded the kernel's segment size...
    try std.testing.expect(seam.max_send <= chunk_max);
    // ...and every byte arrived in order.
    try std.testing.expectEqualSlices(u8, &out, seam.sent[0..n]);
}

test "tls stream: bytes arriving during a write drain are stashed, not lost" {
    // The peer answers while we are still writing. Those bytes must be
    // delivered to the next read rather than discarded.
    var seam = FakeSeam{ .stream = "EARLY-REPLY", .chunk = 5 };
    FakeSeam.g_self = &seam;
    var acc: [256]u8 = undefined;
    var s = Stream.init(FakeSeam.ops(), &acc);

    _ = try s.write("request-that-spans-several-segments");
    // The first drain stashed 5 bytes; a read must yield them, then the rest.
    var got: [32]u8 = undefined;
    const n = try s.read(&got);
    try std.testing.expectEqual(@as(usize, 11), n);
    try std.testing.expectEqualSlices(u8, "EARLY-REPLY", got[0..n]);
}

test "tls stream: an over-cap accumulator and a dead seam fail closed" {
    // A peer that sends more than the caller's buffer: Overflow, not truncation.
    var payload: [900]u8 = undefined;
    @memset(&payload, 0x5A);
    {
        var seam = FakeSeam{ .stream = &payload, .chunk = chunk_max };
        FakeSeam.g_self = &seam;
        // Smaller than one seam chunk (192), so a single chunk cannot be
        // stashed: that is the overflow the adapter must refuse rather than
        // silently truncate.
        var acc: [64]u8 = undefined;
        var s = Stream.init(FakeSeam.ops(), &acc);
        var out: [900]u8 = undefined;
        try std.testing.expectError(Error.Overflow, s.read(&out));
    }
    // A seam that returns a negative code: Closed.
    {
        var seam = FakeSeam{ .stream = "", .chunk = 10, .closed = true };
        FakeSeam.g_self = &seam;
        var acc: [256]u8 = undefined;
        var s = Stream.init(FakeSeam.ops(), &acc);
        var out: [16]u8 = undefined;
        try std.testing.expectError(Error.Closed, s.read(&out));
    }
    // A peer that produces nothing: the idle bound fires rather than hanging.
    {
        var seam = FakeSeam{ .stream = "", .chunk = 10 };
        FakeSeam.g_self = &seam;
        var acc: [256]u8 = undefined;
        var s = Stream.init(FakeSeam.ops(), &acc);
        s.idle_limit = 5;
        var out: [16]u8 = undefined;
        try std.testing.expectError(Error.Closed, s.read(&out));
    }
}
