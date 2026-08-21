//! DipshitOS hostile-consumer test — SPIN.BIN (Arc5 issue #246).
//!
//! Sets a CPU tick limit via sys_setrlimit (slot 54, type 1) then spins
//! in an infinite loop. The kernel's scheduler tick enforcement kills the
//! process with status 141 (reserved_cpu_limit_status) when the limit
//! is exceeded.
//!
//! Naked asm with the fixed register ABI:
//!   sys_write = slot 1, sys_exit = slot 3, sys_setrlimit = slot 54

const std = @import("std");

/// The exact alive marker the live gate greps for.
pub const alive_marker: []const u8 = "spin: alive\n";
/// The exact limit-exceeded marker printed before spinning.
pub const limit_marker: []const u8 = "spin: cpu limit set, spinning\n";
/// The CPU tick limit (100 ticks ≈ 10 seconds at 10 Hz).
pub const cpu_limit: u64 = 100;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
    // Print alive marker
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #12
        \\mov x8, #1
        \\svc #0
        // Set CPU limit: sys_setrlimit(1, 100) — type 1 = CPU ticks
        \\mov x0, #1
        \\mov x1, %[limit]
        \\mov x8, #54
        \\svc #0
        // Print limit-set marker
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #33
        \\mov x8, #1
        \\svc #0
        // Spin forever — the scheduler tick will kill us
        \\3: b 3b
        // Markers (inside the asm block so the linker places them nearby)
        \\1: .ascii "spin: alive\\n"
        \\2: .ascii "spin: cpu limit set, spinning\\n"
        :
        : [limit] "r" (cpu_limit),
    );
}
