//! VirelaiOS EL0EXEC.BIN — issue #1333 class-B fixture.
//!
//! An EL0 Zig program (real call frames) that:
//!   1. `sys_exec`s a missing name and keeps running (ENOENT must not
//!      disturb the caller);
//!   2. `sys_exec`s USER.BIN with argv `alpha`, then uses the stack
//!      (a noinline helper copies the survived marker through a local
//!      buffer) — the kstack overflow smashed those frames;
//!   3. `sys_wait`s the child and prints a done marker.
//!
//! Not a GUI app (ADR 0030). Markers are `pub const` so a drift from the
//! live spec is a host-test failure if this file is compiled as a test.

const std = @import("std");
const builtin = @import("builtin");

pub const enoent_ok_marker: []const u8 = "el0-exec: enoent ok\n";
pub const survived_marker: []const u8 = "el0-exec: parent survived\n";
pub const child_done_marker: []const u8 = "el0-exec: child done\n";
pub const exec_failed_marker: []const u8 = "el0-exec: exec failed\n";
pub const enoent_bad_marker: []const u8 = "el0-exec: enoent unexpected\n";

const sys_write: u64 = 1;
const sys_exit: u64 = 3;
const sys_wait: u64 = 8;
const sys_exec: u64 = 28;
const enoent: i64 = -6;

fn svc1(num: u64, a0: u64) i64 {
    if (builtin.os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
        : .{ .memory = true });
    return res;
}

fn svc3(num: u64, a0: u64, a1: u64, a2: u64) i64 {
    if (builtin.os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
        : .{ .memory = true });
    return res;
}

fn svc4(num: u64, a0: u64, a1: u64, a2: u64, a3: u64) i64 {
    if (builtin.os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
        : .{ .memory = true });
    return res;
}

fn write(msg: []const u8) void {
    if (msg.len == 0) return;
    _ = svc3(sys_write, 1, @intFromPtr(msg.ptr), msg.len);
}

fn exit(status: u64) noreturn {
    _ = svc1(sys_exit, status);
    while (true) {}
}

/// Copy the survived marker through a stack buffer so a smashed high
/// frame (the #1333 overflow) faults here instead of silently returning.
noinline fn announce_survived(pid: i64) void {
    var scratch: [64]u8 = undefined;
    const n = survived_marker.len;
    @memcpy(scratch[0..n], survived_marker);
    scratch[n - 1] = if (pid >= 0) '\n' else '!';
    write(scratch[0..n]);
}

export fn _start() callconv(.c) noreturn {
    run();
}

fn run() noreturn {
    const missing = "NOSUCH.BIN";
    const miss = svc4(sys_exec, @intFromPtr(missing.ptr), missing.len, 0, 0);
    if (miss != enoent) {
        write(enoent_bad_marker);
        exit(1);
    }
    write(enoent_ok_marker);

    const child = "USER.BIN";
    const arg = "alpha";
    var block: [32]u8 = [_]u8{0} ** 32;
    @memcpy(block[0..arg.len], arg);
    const pid = svc4(sys_exec, @intFromPtr(child.ptr), child.len, @intFromPtr(&block), 1);
    if (pid < 0) {
        write(exec_failed_marker);
        exit(2);
    }
    announce_survived(pid);

    const st = svc1(sys_wait, @intCast(pid));
    if (st < 0) {
        write(exec_failed_marker);
        exit(3);
    }
    write(child_done_marker);
    exit(0);
}

test "el0exec: marker shapes are pinned (live-gate grep targets)" {
    try std.testing.expectEqualStrings("el0-exec: enoent ok\n", enoent_ok_marker);
    try std.testing.expectEqualStrings("el0-exec: parent survived\n", survived_marker);
    try std.testing.expectEqualStrings("el0-exec: child done\n", child_done_marker);
}
