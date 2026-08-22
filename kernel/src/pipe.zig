//! M19 P1 (issue #290): the kernel pipe — a bounded, single-buffer conduit
//! between two commands.
//!
//! Two consumers share this module:
//!   * The shell's `|` operator (M19 P1) uses the console adapters below:
//!     the LEFT command runs with `sink_console()` (its writes land in the
//!     pipe), then the RIGHT command runs with `source_console(real)` (its
//!     reads pull from the pipe, its writes pass through to the real
//!     console). Sequential model — cmd1 runs to completion, then cmd2.
//!   * EL0 processes use `sys_pipe_read` (slot 56) / `sys_pipe_write`
//!     (slot 57) through the uaccess layer; `append_slice`/`advance_write`
//!     and `unread_slice`/`advance_read` expose the buffer to those
//!     handlers without a staging copy.
//!
//! Bounded and heap-free: one 4 KiB BSS buffer, no allocation, no
//! synchronization (single-core, IRQ-masked command execution). Overflow is
//! dropped (the writer's `write` returns the bytes actually stored).

const std = @import("std");
const console = @import("console.zig");

/// The pipe buffer size (march-m19.md P1: max 4 KiB).
pub const pipe_capacity: usize = 4096;

var buf: [pipe_capacity]u8 = undefined;
var len: usize = 0; // total bytes written
var read_pos: usize = 0; // consumed prefix

/// Clear the pipe before a new `a | b` (or a fresh EL0 session).
pub fn reset() void {
    len = 0;
    read_pos = 0;
}

/// Unread bytes still in the pipe.
pub fn available() usize {
    return len - read_pos;
}

/// Free write space left in the pipe.
pub fn capacity_left() usize {
    return pipe_capacity - len;
}

/// Append `bytes` to the pipe; returns the number stored (drops overflow).
pub fn write(bytes: []const u8) usize {
    const n = @min(bytes.len, capacity_left());
    @memcpy(buf[len..][0..n], bytes[0..n]);
    len += n;
    return n;
}

/// The append region for a uaccess copy-in (`sys_pipe_write`). The caller
/// validates room first, then `advance_write(n)` on success.
pub fn append_slice() []u8 {
    return buf[len..];
}

/// Advance the write cursor after a successful copy-in.
pub fn advance_write(n: usize) void {
    len += n;
}

/// The unread region for a uaccess copy-out (`sys_pipe_read`). The caller
/// copies out then `advance_read(n)` on success.
pub fn unread_slice() []const u8 {
    return buf[read_pos..len];
}

/// Consume `n` unread bytes after a successful copy-out.
pub fn advance_read(n: usize) void {
    read_pos += n;
}

// ---------------------------------------------------------------------------
// Sink console — the LEFT command's stdout during `a | b`
// ---------------------------------------------------------------------------

const SinkCtx = struct {};
var sink_ctx: SinkCtx = .{};
// ADR 0005 (claim 0015): vtables are built at runtime into BSS — a const
// table holds link-time absolute addresses, wrong at the kernel's
// runtime-chosen load base.
var sink_vtable: console.Console.VTable = undefined;
var sink_vtable_ready = false;
fn ensure_sink_vtable() *const console.Console.VTable {
    if (!sink_vtable_ready) {
        sink_vtable = .{
            .write = sink_write,
            .flush = sink_flush,
            .readByte = sink_read,
        };
        sink_vtable_ready = true;
    }
    return &sink_vtable;
}
fn sink_write(_: *anyopaque, bytes: []const u8) void {
    _ = write(bytes);
}
fn sink_flush(_: *anyopaque) void {}
fn sink_read(_: *anyopaque) ?u8 {
    return null; // the left command has no stdin
}

/// A console whose writes land in the pipe and whose reads return nothing.
pub fn sink_console() console.Console {
    return .{ .ctx = &sink_ctx, .vtable = ensure_sink_vtable() };
}

// ---------------------------------------------------------------------------
// Source console — the RIGHT command's stdin during `a | b`
// ---------------------------------------------------------------------------

const SourceCtx = struct { inner: console.Console };
var source_ctx: SourceCtx = undefined;
var source_vtable: console.Console.VTable = undefined;
var source_vtable_ready = false;
fn ensure_source_vtable() *const console.Console.VTable {
    if (!source_vtable_ready) {
        source_vtable = .{
            .write = source_write,
            .flush = source_flush,
            .readByte = source_read,
        };
        source_vtable_ready = true;
    }
    return &source_vtable;
}
fn source_write(ctx: *anyopaque, bytes: []const u8) void {
    const sc: *SourceCtx = @ptrCast(@alignCast(ctx));
    sc.inner.write(bytes);
}
fn source_flush(ctx: *anyopaque) void {
    const sc: *SourceCtx = @ptrCast(@alignCast(ctx));
    sc.inner.flush();
}
fn source_read(_: *anyopaque) ?u8 {
    if (available() == 0) return null;
    const b = buf[read_pos];
    read_pos += 1;
    return b;
}

/// A console whose reads pull from the pipe and whose writes pass through
/// to `inner`. Used as the RIGHT command's console during `a | b`.
pub fn source_console(inner: console.Console) console.Console {
    source_ctx.inner = inner;
    return .{ .ctx = &source_ctx, .vtable = ensure_source_vtable() };
}

// ---------------------------------------------------------------------------
// Tests (host-side; no hardware)
// ---------------------------------------------------------------------------

test "pipe: write/read round-trips through the buffer" {
    reset();
    try std.testing.expectEqual(@as(usize, 0), available());
    const n = write("hello pipe");
    try std.testing.expectEqual(@as(usize, 10), n);
    try std.testing.expectEqual(@as(usize, 10), available());
    var out: [pipe_capacity]u8 = undefined;
    const got = read_into_for_test(&out);
    try std.testing.expectEqualStrings("hello pipe", out[0..got]);
    try std.testing.expectEqual(@as(usize, 0), available());
}

test "pipe: overflow is dropped, never wraps" {
    reset();
    const big = "x" ** (pipe_capacity + 100);
    const n = write(big);
    try std.testing.expectEqual(@as(usize, pipe_capacity), n);
    try std.testing.expectEqual(@as(usize, pipe_capacity), available());
    // A second write finds no room.
    try std.testing.expectEqual(@as(usize, 0), write("y"));
}

test "pipe: sink console captures writes, source console feeds reads" {
    reset();
    var mock = console.MockConsole(256){};
    const real = mock.console();
    const sink = sink_console();
    sink.write("left-out");
    sink.putc('\n');
    try std.testing.expectEqual(@as(usize, 9), available());
    // The source console reads the pipe and passes writes through.
    const source = source_console(real);
    var got: [32]u8 = undefined;
    var n: usize = 0;
    while (source.readByte()) |b| : (n += 1) {
        if (n < got.len) got[n] = b;
    }
    try std.testing.expectEqualStrings("left-out\n", got[0..n]);
    source.puts("right-out");
    try std.testing.expectEqualStrings("right-out", mock.contents());
}

/// Host-test helper mirroring the syscall read path (copy unread bytes out).
fn read_into_for_test(out: []u8) usize {
    const avail = available();
    const take = @min(avail, out.len);
    @memcpy(out[0..take], unread_slice()[0..take]);
    advance_read(take);
    return take;
}
