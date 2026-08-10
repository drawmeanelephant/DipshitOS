//! DipshitOS first EL0 execution boundary (claim 8215).
//!
//! This is deliberately smaller than a process subsystem: one statically
//! linked EL0t task, one static user stack, the existing TTBR0 identity map,
//! and one SVC operation. Only the page-aligned user text and stack ranges are
//! EL0-accessible; neighboring Normal RAM, kernel data, and Device mappings
//! remain privileged. Separate address spaces, loading, processes, and a broad
//! syscall ABI are later cards.
//!
//! The live proof is stronger than a one-way `eret`: the EL0 loop increments
//! x0, round-trips it through `svc #0`, receives the kernel's result in x0,
//! and invokes SVC again. Seeing the second valid call proves the first SVC
//! returned to EL0. Reporting is deferred to the shell idle loop because the
//! polled console is not reentrant in exception context.

const std = @import("std");
const builtin = @import("builtin");
const console = @import("console.zig");
const exceptions = @import("exceptions.zig");

const user_text_section = if (builtin.object_format == .elf) ".usertext" else "__TEXT,__usertext";

pub const syscall_ping: u64 = 0;
pub const svc_immediate: u16 = 0;
pub const error_unknown: u64 = std.math.maxInt(u64);

pub const Region = struct { base: u64, len: u64 };
extern var __user_text_start: u8;
extern var __user_text_end: u8;
extern var __user_stack_start: u8;
extern var __user_stack_end: u8;

pub fn text_region(image_base: u64) Region {
    // Absolute linker symbols in this relocation-free ELF evaluate to image
    // offsets. Add the loader-provided runtime base before handing the range
    // to the identity-map builder.
    const start = image_base + @intFromPtr(&__user_text_start);
    const end = @intFromPtr(&__user_text_end);
    return .{ .base = start, .len = end - @intFromPtr(&__user_text_start) };
}

pub fn stack_region(image_base: u64) Region {
    const start = image_base + @intFromPtr(&__user_stack_start);
    const end = @intFromPtr(&__user_stack_end);
    return .{ .base = start, .len = end - @intFromPtr(&__user_stack_start) };
}

var calls_value: u64 = 0;
var valid_sequences_value: u64 = 0;
var rejected_value: u64 = 0;
var last_arg_value: u64 = 0;
var last_result_value: u64 = 0;

var report_pending: bool = false;
var report_calls: u64 = 0;
var report_roundtrips: u64 = 0;
var report_arg: u64 = 0;
var report_result: u64 = 0;
var report_rejected: u64 = 0;

pub const Stats = struct {
    calls: u64,
    valid_sequences: u64,
    rejected: u64,
    last_arg: u64,
    last_result: u64,
};

pub fn init() void {
    calls_value = 0;
    valid_sequences_value = 0;
    rejected_value = 0;
    last_arg_value = 0;
    last_result_value = 0;
    report_pending = false;
}

pub fn stats() Stats {
    return .{
        .calls = calls_value,
        .valid_sequences = valid_sequences_value,
        .rejected = rejected_value,
        .last_arg = last_arg_value,
        .last_result = last_result_value,
    };
}

/// Exception-context SVC dispatcher. x8 selects the operation, x0 is both
/// the ping sequence argument and return register. Unknown operations return
/// a stable all-ones error instead of turning a bad userspace request into a
/// fatal kernel exception.
pub fn handle_svc(frame: *exceptions.VectorFrame, immediate: u16) bool {
    const operation = exceptions.frame_read(frame, 8);
    const arg = exceptions.frame_read(frame, 0);
    if (immediate != svc_immediate or operation != syscall_ping) {
        rejected_value += 1;
        last_arg_value = arg;
        last_result_value = error_unknown;
        _ = exceptions.frame_write(frame, 0, error_unknown);
        return true;
    }

    const expected = calls_value +% 1;
    calls_value +%= 1;
    if (arg == expected) valid_sequences_value +%= 1;
    last_arg_value = arg;
    last_result_value = calls_value;
    _ = exceptions.frame_write(frame, 0, last_result_value);

    // The second correctly sequenced entry can exist only if the first SVC
    // returned to EL0 and its x0 result survived the exception restore.
    if (!report_pending and calls_value == 2 and valid_sequences_value == 2) {
        report_pending = true;
        report_calls = calls_value;
        report_roundtrips = valid_sequences_value - 1;
        report_arg = arg;
        report_result = last_result_value;
        report_rejected = rejected_value;
    }
    return true;
}

/// Shell-context evidence line. Never called from the synchronous exception
/// handler or timer IRQ path.
pub fn maybe_report(con: *console.Console) void {
    if (!report_pending) return;
    report_pending = false;
    con.puts("userspace: el0=1 svc=");
    con.print_u64(report_calls);
    con.puts(" roundtrips=");
    con.print_u64(report_roundtrips);
    con.puts(" arg=");
    con.print_u64(report_arg);
    con.puts(" result=");
    con.print_u64(report_result);
    con.puts(" rejected=");
    con.print_u64(report_rejected);
    con.puts("\n");
}

/// Statically linked EL0 payload. The stack store/load proves SP_EL0 points at
/// writable user-accessible RAM; the second SVC proves return to EL0. This
/// function intentionally contains no Zig-generated memory references or
/// calls—only the tiny register ABI crosses into EL1.
pub fn entry() linksection(user_text_section) callconv(.naked) noreturn {
    asm volatile (
        \\mov x0, xzr
        \\mov x8, xzr
        \\1:
        \\add x0, x0, #1
        \\sub sp, sp, #16
        \\str x0, [sp]
        \\ldr x0, [sp]
        \\add sp, sp, #16
        \\svc #0
        \\b 1b
    );
}

test "userspace: two sequenced pings prove an SVC return round-trip" {
    init();
    var frame: exceptions.VectorFrame = [_]u64{0} ** exceptions.vector_frame_slots;
    try std.testing.expect(exceptions.frame_write(&frame, 8, syscall_ping));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 1));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, 1), exceptions.frame_read(&frame, 0));

    try std.testing.expect(exceptions.frame_write(&frame, 0, 2));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, 2), exceptions.frame_read(&frame, 0));
    const s = stats();
    try std.testing.expectEqual(@as(u64, 2), s.calls);
    try std.testing.expectEqual(@as(u64, 2), s.valid_sequences);
    try std.testing.expectEqual(@as(u64, 0), s.rejected);

    var mock = console.MockConsole(256){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings(
        "userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0\n",
        mock.contents(),
    );
    mock.reset();
    maybe_report(&con);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
}

test "userspace: malformed SVC requests return a bounded ABI error" {
    init();
    var frame: exceptions.VectorFrame = [_]u64{0} ** exceptions.vector_frame_slots;
    try std.testing.expect(exceptions.frame_write(&frame, 8, 99));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 0x1234));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_unknown, exceptions.frame_read(&frame, 0));
    const s = stats();
    try std.testing.expectEqual(@as(u64, 0), s.calls);
    try std.testing.expectEqual(@as(u64, 1), s.rejected);
    try std.testing.expectEqual(@as(u64, 0x1234), s.last_arg);
    try std.testing.expectEqual(error_unknown, s.last_result);
}
