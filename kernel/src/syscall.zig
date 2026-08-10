//! DipshitOS milestone-three syscall ABI (claim 3594).
//!
//! The claim-8215 EL0 boundary owns exception entry and return. This module
//! layers a fixed numbered contract on that seam: x8 is the syscall number,
//! x0..x5 are arguments, `svc #0` is reserved, and x0 receives the result.
//! The 64-slot function-pointer table is built at runtime in BSS (ADR 0005):
//! the flat kernel loader applies no relocations, so a const table would hold
//! invalid link-time function addresses at the runtime-selected image base.
//!
//! No allocation, libc, POSIX, uaccess, process abstraction, or address-space
//! work lives here. `sys_write` uses bounded arithmetic under the current
//! shared identity map; EFAULT is reserved for the follow-on uaccess card.

const std = @import("std");
const builtin = @import("builtin");
const console = @import("console.zig");
const exceptions = @import("exceptions.zig");
const mmu = @import("mmu.zig");
const scheduler = @import("scheduler.zig");
const userspace = @import("userspace.zig");

pub const slot_count: usize = 64;
pub const implemented_count: usize = 4;
pub const write_cap: u64 = 256;
pub const svc_immediate: u16 = 0;

pub const sys_ping: u64 = 0;
pub const sys_write: u64 = 1;
pub const sys_yield: u64 = 2;
pub const sys_exit: u64 = 3;

pub const ErrorCode = enum(i64) {
    einval = -1,
    ebadf = -2,
    efault = -3,
    enosys = -4,
};

pub fn error_result(code: ErrorCode) u64 {
    return @bitCast(@intFromEnum(code));
}

pub const Args = [6]u64;
pub const Writer = *const fn ([]const u8) void;
const Handler = *const fn (Args, *exceptions.VectorFrame) u64;

const Entry = struct {
    name: []const u8 = "",
    handler: ?Handler = null,
};

pub const EntryInfo = struct {
    number: u64,
    name: []const u8,
    calls: u64,
};

var table_storage: [slot_count]Entry = undefined;
var table_ready = false;
var call_counts: [slot_count]u64 = [_]u64{0} ** slot_count;
var write_fn: ?Writer = null;
var allowed_user_regions: [2]userspace.Region = .{
    .{ .base = 0, .len = 0 },
    .{ .base = 0, .len = 0 },
};

/// Initialize the writer seam and reset counters. The table remains a
/// runtime-built BSS object; rebuilding is unnecessary once its PC-relative
/// addresses have been materialized at the current image base.
pub fn init(writer: Writer) void {
    write_fn = writer;
    @memset(&call_counts, 0);
    allowed_user_regions = .{
        .{ .base = 0, .len = 0 },
        .{ .base = 0, .len = 0 },
    };
    _ = ensure_table();
}

/// Configure the two claim-8215 apertures already mapped for EL0. This is
/// plain range arithmetic over kernel-known mappings, not uaccess or fault
/// recovery. The follow-on uaccess card will replace it.
pub fn set_user_regions(text: userspace.Region, stack: userspace.Region) void {
    allowed_user_regions = .{ text, stack };
}

fn ensure_table() *const [slot_count]Entry {
    if (!table_ready) {
        for (&table_storage) |*entry| entry.* = .{};
        table_storage[sys_ping] = .{ .name = "sys_ping", .handler = handle_ping };
        table_storage[sys_write] = .{ .name = "sys_write", .handler = handle_write };
        table_storage[sys_yield] = .{ .name = "sys_yield", .handler = handle_yield };
        table_storage[sys_exit] = .{ .name = "sys_exit", .handler = handle_exit };
        table_ready = true;
    }
    return &table_storage;
}

pub fn entry_info(number: u64) ?EntryInfo {
    if (number >= slot_count) return null;
    const entry = ensure_table()[number];
    if (entry.handler == null) return null;
    return .{ .number = number, .name = entry.name, .calls = call_counts[number] };
}

pub fn call_count(number: u64) u64 {
    if (number >= slot_count) return 0;
    return call_counts[number];
}

/// Dispatch one already-decoded syscall. In-range reserved slots are counted
/// and return ENOSYS; numbers beyond the fixed namespace return ENOSYS without
/// indexing the table. The caller writes this result into saved x0.
pub fn dispatch(number: u64, args: Args, frame: *exceptions.VectorFrame) u64 {
    if (number >= slot_count) return error_result(.enosys);
    call_counts[number] +%= 1;
    const handler = ensure_table()[number].handler orelse return error_result(.enosys);
    return handler(args, frame);
}

/// Adapter registered through claim 8215's `set_svc_dispatcher` seam.
pub fn handle_svc(frame: *exceptions.VectorFrame, immediate: u16) bool {
    var args: Args = undefined;
    for (&args, 0..) |*arg, reg| arg.* = exceptions.frame_read(frame, @intCast(reg));
    const number = exceptions.frame_read(frame, 8);
    const result = if (immediate == svc_immediate)
        dispatch(number, args, frame)
    else
        error_result(.enosys);
    _ = exceptions.frame_write(frame, 0, result);
    return true;
}

fn handle_ping(args: Args, _: *exceptions.VectorFrame) u64 {
    return userspace.ping(args[0]);
}

fn handle_write(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] != 1) return error_result(.ebadf);
    const address = args[1];
    const len = args[2];
    if (len > write_cap) return error_result(.einval);
    const end = address +% len;
    if (end < address) return error_result(.einval);
    if (len == 0) return 0;
    if (!allowed_user_range(address, len)) return error_result(.einval);
    // The live kernel's user apertures lie inside the guaranteed low identity
    // blanket. Host test images are conventionally loaded above 4 GiB, so the
    // architectural ceiling is pinned separately by pure range tests.
    if (comptime !builtin.is_test) {
        if (end > mmu.identity_blanket_end) return error_result(.einval);
    }
    const writer = write_fn orelse return error_result(.einval);
    const bytes: [*]const u8 = @ptrFromInt(address);
    writer(bytes[0..@intCast(len)]);
    return len;
}

fn allowed_user_range(address: u64, len: u64) bool {
    if (len == 0) return true;
    const end = address +% len;
    if (end < address) return false;
    for (allowed_user_regions) |region| {
        const region_end = region.base +% region.len;
        if (region_end < region.base) continue;
        if (address >= region.base and end <= region_end) return true;
    }
    return false;
}

fn range_within_identity(address: u64, len: u64) bool {
    const end = address +% len;
    return end >= address and end <= mmu.identity_blanket_end;
}

fn handle_yield(_: Args, _: *exceptions.VectorFrame) u64 {
    _ = scheduler.yield_current();
    return 0;
}

fn handle_exit(args: Args, _: *exceptions.VectorFrame) u64 {
    // Returning from this Zig function is only kernel control flow. On
    // success the scheduler has removed the caller from the runnable set and
    // staged another task's frame, so the SVC exception return never returns
    // to the terminated EL0 task.
    if (!scheduler.exit_current(args[0])) return error_result(.einval);
    return 0;
}

/// Deterministic monitor output for the four frozen rows and their counters.
pub fn report(con: *console.Console) void {
    con.puts("syscalls: slots=64 implemented=4\n");
    var number: u64 = 0;
    while (number < implemented_count) : (number += 1) {
        const info = entry_info(number).?;
        con.puts("  ");
        con.print_u64(info.number);
        con.puts(" ");
        con.puts(info.name);
        con.puts(" calls=");
        con.print_u64(info.calls);
        con.puts("\n");
    }
}

var test_write_buffer: [write_cap]u8 = undefined;
var test_write_len: usize = 0;

fn test_writer(bytes: []const u8) void {
    @memcpy(test_write_buffer[test_write_len..][0..bytes.len], bytes);
    test_write_len += bytes.len;
}

fn fresh_frame() exceptions.VectorFrame {
    return [_]u64{0} ** exceptions.vector_frame_slots;
}

var test_marshaled_args: Args = [_]u64{0} ** 6;
fn capture_marshaled_args(args: Args, _: *exceptions.VectorFrame) u64 {
    test_marshaled_args = args;
    return 0xcafe;
}

test "syscall: runtime table has 64 slots and four unique implemented rows" {
    init(test_writer);
    const table = ensure_table();
    try std.testing.expectEqual(@as(usize, 64), table.len);
    var seen: [slot_count]bool = [_]bool{false} ** slot_count;
    var implemented: usize = 0;
    for (table, 0..) |entry, number| {
        if (entry.handler != null) {
            try std.testing.expect(!seen[number]);
            seen[number] = true;
            implemented += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), implemented);
    try std.testing.expectEqualStrings("sys_ping", entry_info(0).?.name);
    try std.testing.expectEqualStrings("sys_exit", entry_info(3).?.name);
    try std.testing.expect(entry_info(4) == null);
    try std.testing.expect(entry_info(63) == null);
}

test "syscall: adapter decodes x8 and x0-x5 and unknown numbers return ENOSYS" {
    userspace.init();
    init(test_writer);
    var frame = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_ping));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 41));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, 41), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_ping));

    try std.testing.expect(exceptions.frame_write(&frame, 8, 63));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_result(.enosys), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(63));

    try std.testing.expect(exceptions.frame_write(&frame, 8, 64));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_result(.enosys), exceptions.frame_read(&frame, 0));
}

test "syscall: handle_svc marshals every x0-x5 argument before replacing x0" {
    init(test_writer);
    _ = ensure_table();
    const saved = table_storage[63];
    defer table_storage[63] = saved;
    table_storage[63] = .{ .name = "test_capture", .handler = capture_marshaled_args };
    var frame = fresh_frame();
    const expected: Args = .{
        0x0101_0101_0101_0101,
        0x1212_1212_1212_1212,
        0x2323_2323_2323_2323,
        0x3434_3434_3434_3434,
        0x4545_4545_4545_4545,
        0x5656_5656_5656_5656,
    };
    for (expected, 0..) |value, reg| try std.testing.expect(exceptions.frame_write(&frame, @intCast(reg), value));
    try std.testing.expect(exceptions.frame_write(&frame, 8, 63));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(expected, test_marshaled_args);
    try std.testing.expectEqual(@as(u64, 0xcafe), exceptions.frame_read(&frame, 0));
}

test "syscall: write validates fd cap overflow and zero length" {
    init(test_writer);
    test_write_len = 0;
    var frame = fresh_frame();
    const bytes = "write-through-mock";
    set_user_regions(
        .{ .base = @intFromPtr(bytes.ptr), .len = bytes.len },
        .{ .base = 0, .len = 0 },
    );
    var args: Args = .{ 1, @intFromPtr(bytes.ptr), bytes.len, 0, 0, 0 };
    try std.testing.expectEqual(@as(u64, bytes.len), dispatch(sys_write, args, &frame));
    try std.testing.expectEqualStrings(bytes, test_write_buffer[0..test_write_len]);

    args[0] = 2;
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_write, args, &frame));
    args[0] = 1;
    args[2] = write_cap + 1;
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_write, args, &frame));
    args[1] = std.math.maxInt(u64) - 1;
    args[2] = 4;
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_write, args, &frame));
    args[1] = @intFromPtr(bytes.ptr) - 1;
    args[2] = 1;
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_write, args, &frame));
    args[1] = @intFromPtr(bytes.ptr) + bytes.len - 1;
    args[2] = 2;
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_write, args, &frame));
    try std.testing.expect(range_within_identity(mmu.identity_blanket_end - 1, 1));
    try std.testing.expect(!range_within_identity(mmu.identity_blanket_end, 1));
    try std.testing.expect(!range_within_identity(mmu.identity_blanket_end - 1, 2));

    test_write_len = 0;
    args[1] = mmu.identity_blanket_end;
    args[2] = 0;
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_write, args, &frame));
    try std.testing.expectEqual(@as(usize, 0), test_write_len);
}

test "syscall: yield returns zero and exit removes the current task" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000);
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_yield, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), scheduler.cooperative_yield_count());
    // worker -> user, then exit the EL0 task. It is reaped from the runnable
    // ring, so the selected frame belongs to shell and can never be `frame`.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exit, .{ 7, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_terminated(2));
    try std.testing.expectEqual(@as(?u64, 7), scheduler.terminated_status(2));
    try std.testing.expectEqual(@as(u64, 1), scheduler.exit_count());
    try std.testing.expect(exceptions.resume_frame != @intFromPtr(&frame));
}

test "syscall: handle_svc writes yield result into the suspended caller frame" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000);
    scheduler.start();
    var caller = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&caller, 0, 0xdead));
    try std.testing.expect(exceptions.frame_write(&caller, 8, sys_yield));
    exceptions.resume_frame = @intFromPtr(&caller);
    try std.testing.expect(handle_svc(&caller, svc_immediate));
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(&caller, 0));
    try std.testing.expect(exceptions.resume_frame != @intFromPtr(&caller));
    try std.testing.expectEqual(@as(usize, 1), scheduler.current_id());
}

test "syscall: counters are monotonic and report is deterministic" {
    userspace.init();
    init(test_writer);
    var frame = fresh_frame();
    _ = dispatch(sys_ping, .{ 9, 0, 0, 0, 0, 0 }, &frame);
    _ = dispatch(sys_ping, .{ 10, 0, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 2), call_count(sys_ping));
    var mock = console.MockConsole(512){};
    var con = mock.console();
    report(&con);
    try std.testing.expectEqualStrings(
        "syscalls: slots=64 implemented=4\n" ++
            "  0 sys_ping calls=2\n" ++
            "  1 sys_write calls=0\n" ++
            "  2 sys_yield calls=0\n" ++
            "  3 sys_exit calls=0\n",
        mock.contents(),
    );
}
