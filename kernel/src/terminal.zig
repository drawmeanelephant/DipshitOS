//! VirelaiOS terminal (vt) seam (ADR 0020, issue #1072).
//!
//! A **terminal** is a bounded, hardware-free session buffer: an output ring
//! the owner process writes to, an input queue a front-end fills, and an
//! exclusive attach state naming the front-end (the raw serial console, a
//! TABWM window, a TCP/SSH session). It is the thing `SH.BIN`, `TERM.BIN`,
//! and remote sessions all sit on — see ADR 0020.
//!
//! Pure by construction: fixed arrays, no allocation, no hardware, no
//! syscalls. The device/front-end wiring lives outside this module (the
//! `/dev/tty` routing in `file_table.zig` is the next tranche).
//!
//! Overflow policy is explicit and counted:
//!   * output full -> drop the OLDEST byte (`out_dropped`), so output flows;
//!   * input full  -> drop the NEWEST byte (`in_dropped`), so a key burst
//!     never evicts keys the owner has not read yet.

const std = @import("std");

/// Output ring capacity (bytes the owner has written, awaiting a front-end).
pub const out_capacity: usize = 4096;
/// Input queue capacity (bytes a front-end has pushed, awaiting the owner).
pub const in_capacity: usize = 256;
/// How many concurrent terminals the kernel tracks.
pub const max_terminals: usize = 4;

/// The consumer that renders output and supplies input. Exclusive per
/// terminal: one front-end at a time (ADR 0020 D2).
pub const FrontEnd = enum(u8) {
    none = 0,
    /// The raw virtio serial console.
    serial = 1,
    /// A TABWM desktop terminal window (TERM.BIN).
    window = 2,
    /// A network session (remote console / SSH channel).
    net = 3,
};

/// A terminal session. All methods are pure; the struct is `extern`-free and
/// host-testable as a value.
pub const Terminal = struct {
    out: [out_capacity]u8 = [_]u8{0} ** out_capacity,
    out_start: usize = 0,
    out_len: usize = 0,
    out_dropped: u64 = 0,

    in: [in_capacity]u8 = [_]u8{0} ** in_capacity,
    in_start: usize = 0,
    in_len: usize = 0,
    in_dropped: u64 = 0,

    attached: bool = false,
    front_end: FrontEnd = .none,
    owner_pid: ?usize = null,
    in_use: bool = false,

    /// Append owner output to the ring. Always accepts every byte; when the
    /// ring is full it drops the oldest byte and counts it. Returns bytes
    /// accepted (== `bytes.len`).
    pub fn write(self: *Terminal, bytes: []const u8) usize {
        for (bytes) |b| {
            if (self.out_len == out_capacity) {
                self.out_start = (self.out_start + 1) % out_capacity;
                self.out_len -= 1;
                self.out_dropped += 1;
            }
            self.out[(self.out_start + self.out_len) % out_capacity] = b;
            self.out_len += 1;
        }
        return bytes.len;
    }

    /// Drain up to `buf.len` output bytes, oldest first. Returns the count.
    pub fn readOut(self: *Terminal, buf: []u8) usize {
        const n = @min(buf.len, self.out_len);
        for (0..n) |i| buf[i] = self.out[(self.out_start + i) % out_capacity];
        self.out_start = (self.out_start + n) % out_capacity;
        self.out_len -= n;
        return n;
    }

    /// Bytes waiting for a front-end to drain.
    pub fn pendingOut(self: *const Terminal) usize {
        return self.out_len;
    }

    /// Push front-end input. When the queue is full the NEWEST byte is
    /// dropped and counted. Returns bytes accepted.
    pub fn pushInput(self: *Terminal, bytes: []const u8) usize {
        var accepted: usize = 0;
        for (bytes) |b| {
            if (self.in_len == in_capacity) {
                self.in_dropped += 1;
                continue;
            }
            self.in[(self.in_start + self.in_len) % in_capacity] = b;
            self.in_len += 1;
            accepted += 1;
        }
        return accepted;
    }

    /// Drain up to `buf.len` input bytes, oldest first. Returns the count.
    pub fn readInput(self: *Terminal, buf: []u8) usize {
        const n = @min(buf.len, self.in_len);
        for (0..n) |i| buf[i] = self.in[(self.in_start + i) % in_capacity];
        self.in_start = (self.in_start + n) % in_capacity;
        self.in_len -= n;
        return n;
    }

    /// Input bytes waiting for the owner.
    pub fn pendingInput(self: *const Terminal) usize {
        return self.in_len;
    }

    /// Attach a front-end. Exclusive: fails when one is already attached or
    /// `fe` is `.none`. Idempotent re-attach by the SAME front-end succeeds.
    pub fn attach(self: *Terminal, fe: FrontEnd) bool {
        if (fe == .none) return false;
        if (self.attached) return self.front_end == fe;
        self.attached = true;
        self.front_end = fe;
        return true;
    }

    /// Detach whatever front-end is attached (no-op when none).
    pub fn detach(self: *Terminal) void {
        self.attached = false;
        self.front_end = .none;
    }

    pub fn isAttached(self: *const Terminal) bool {
        return self.attached;
    }

    /// Drop all buffered bytes/counters and detach. Keeps `in_use`/owner.
    pub fn flush(self: *Terminal) void {
        self.out_start = 0;
        self.out_len = 0;
        self.out_dropped = 0;
        self.in_start = 0;
        self.in_len = 0;
        self.in_dropped = 0;
    }

    /// Full reset to a free slot (used by the registry on release/tests).
    pub fn reset(self: *Terminal) void {
        self.* = .{};
    }
};

// ---------------------------------------------------------------------------
// The kernel terminal registry (bounded; no allocation).
// ---------------------------------------------------------------------------

pub var terminals: [max_terminals]Terminal = [_]Terminal{.{}} ** max_terminals;

/// Allocate a free terminal for `owner`, or null when all slots are taken.
pub fn create(owner: ?usize) ?usize {
    for (&terminals, 0..) |*t, i| {
        if (!t.in_use) {
            t.reset();
            t.in_use = true;
            t.owner_pid = owner;
            return i;
        }
    }
    return null;
}

/// The terminal at `handle`, or null when out of range / free.
pub fn get(handle: usize) ?*Terminal {
    if (handle >= max_terminals) return null;
    if (!terminals[handle].in_use) return null;
    return &terminals[handle];
}

/// Release a terminal slot (e.g. owner death). Clears everything.
pub fn release(handle: usize) void {
    if (handle >= max_terminals) return;
    terminals[handle].reset();
}

// ---------------------------------------------------------------------------
// Tests (pure; no hardware)
// ---------------------------------------------------------------------------

test "terminal: output round-trips FIFO from owner to front-end" {
    var t = Terminal{};
    try std.testing.expectEqual(@as(usize, 5), t.write("hello"));
    try std.testing.expectEqual(@as(usize, 5), t.pendingOut());
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), t.readOut(&buf));
    try std.testing.expectEqualStrings("hello", buf[0..5]);
    try std.testing.expectEqual(@as(usize, 0), t.pendingOut());
    // Draining an empty ring is a no-op.
    try std.testing.expectEqual(@as(usize, 0), t.readOut(&buf));
}

test "terminal: output ring wraps and preserves order across fill/drain cycles" {
    var t = Terminal{};
    var big: [out_capacity]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i);
    try std.testing.expectEqual(out_capacity, t.write(&big));
    // Drain the first half, refill, then read everything back in order.
    var half: [out_capacity]u8 = undefined;
    try std.testing.expectEqual(out_capacity / 2, t.readOut(half[0 .. out_capacity / 2]));
    try std.testing.expectEqualStrings(big[0 .. out_capacity / 2], half[0 .. out_capacity / 2]);
    const more = "XYZ";
    _ = t.write(more);
    var rest: [out_capacity + 4]u8 = undefined;
    const n = t.readOut(&rest);
    try std.testing.expectEqual(out_capacity / 2 + more.len, n);
    // The tail of the original fill, then the appended bytes.
    try std.testing.expectEqualSlices(u8, big[out_capacity / 2 ..], rest[0 .. out_capacity / 2]);
    try std.testing.expectEqualStrings(more, rest[out_capacity / 2 .. n]);
}

test "terminal: output overflow drops the OLDEST byte and counts it" {
    var t = Terminal{};
    var big: [out_capacity + 10]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i);
    _ = t.write(&big);
    try std.testing.expectEqual(@as(u64, 10), t.out_dropped);
    // The surviving window is the LAST out_capacity bytes.
    var buf: [out_capacity]u8 = undefined;
    try std.testing.expectEqual(out_capacity, t.readOut(&buf));
    try std.testing.expectEqualSlices(u8, big[10..], &buf);
}

test "terminal: input round-trips FIFO from front-end to owner" {
    var t = Terminal{};
    try std.testing.expectEqual(@as(usize, 3), t.pushInput("abc"));
    try std.testing.expectEqual(@as(usize, 3), t.pendingInput());
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), t.readInput(&buf));
    try std.testing.expectEqualStrings("abc", buf[0..3]);
    try std.testing.expectEqual(@as(usize, 0), t.pendingInput());
}

test "terminal: input overflow drops the NEWEST byte (never evicts unread keys)" {
    var t = Terminal{};
    var big: [in_capacity]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i);
    try std.testing.expectEqual(in_capacity, t.pushInput(&big));
    // One over capacity: the new byte is refused, the queue is untouched.
    try std.testing.expectEqual(@as(usize, 0), t.pushInput("Z"));
    try std.testing.expectEqual(@as(u64, 1), t.in_dropped);
    try std.testing.expectEqual(in_capacity, t.pendingInput());
    var buf: [in_capacity]u8 = undefined;
    try std.testing.expectEqual(in_capacity, t.readInput(&buf));
    try std.testing.expectEqualSlices(u8, &big, &buf);
}

test "terminal: front-end attach is exclusive and detach re-opens it" {
    var t = Terminal{};
    try std.testing.expect(!t.isAttached());
    try std.testing.expect(t.attach(.serial));
    try std.testing.expect(t.isAttached());
    try std.testing.expectEqual(FrontEnd.serial, t.front_end);
    // A second, different front-end is refused while attached.
    try std.testing.expect(!t.attach(.window));
    try std.testing.expectEqual(FrontEnd.serial, t.front_end);
    // Re-attach by the same front-end is idempotent.
    try std.testing.expect(t.attach(.serial));
    // `.none` is never a valid attach.
    t.detach();
    try std.testing.expect(!t.isAttached());
    try std.testing.expect(!t.attach(.none));
    // Now the window can take it.
    try std.testing.expect(t.attach(.window));
}

test "terminal: flush clears buffers and counters without detaching the owner" {
    var t = Terminal{};
    _ = t.write("out");
    _ = t.pushInput("in");
    t.attached = true;
    t.front_end = .serial;
    t.flush();
    try std.testing.expectEqual(@as(usize, 0), t.pendingOut());
    try std.testing.expectEqual(@as(usize, 0), t.pendingInput());
    try std.testing.expectEqual(@as(u64, 0), t.out_dropped);
    try std.testing.expectEqual(@as(u64, 0), t.in_dropped);
    try std.testing.expect(t.isAttached());
}

test "terminal: registry creates, looks up, and releases bounded slots" {
    for (&terminals) |*t| t.reset();
    const a = create(7) orelse return error.TestUnexpectedResult;
    const b = create(8) orelse return error.TestUnexpectedResult;
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(?usize, 7), get(a).?.owner_pid);
    try std.testing.expectEqual(@as(?usize, 8), get(b).?.owner_pid);
    // Fill the rest; overflow is an honest null.
    var made: usize = 2;
    while (made < max_terminals) : (made += 1) {
        _ = create(null) orelse return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(?usize, null), create(null));
    // Release frees a slot; the freed handle is a fresh empty terminal.
    release(a);
    try std.testing.expectEqual(@as(?*Terminal, null), get(a));
    const c = create(9) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?usize, 9), get(c).?.owner_pid);
    for (&terminals) |*t| t.reset();
}
