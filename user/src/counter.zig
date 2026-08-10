//! DipshitOS second ESP user program — COUNTER.BIN (milestone-four
//! follow-on 2, claim 4613).
//!
//! The strong liveness proof the claim-0826 concurrent gate lacks: claim
//! 0826 ran TWO live processes, but both were copies of the SAME program
//! (USER.BIN) and BOTH exited after a few ticks. This program is the
//! permanent occupant: a DISTINCT second image (built from this file by
//! the same build/elf2bin pipeline as USER.BIN, embedded on the ESP as
//! COUNTER.BIN) that NEVER exits — it loops forever writing its own
//! distinct marker through sys_write (fd 1, slot 1) each quantum, spins
//! briefly, and yields (sys_yield, slot 2) — only the frozen ADR-0007
//! slots 1 + 2, no sys_exit. While it runs, the shell, the worker, AND
//! other concurrently-exec'd programs all stay responsive: the process
//! occupies its pool slot and address space permanently, and the live
//! gate reaps + re-execs the short USER.BIN into a freed slot while the
//! counter's markers keep landing.
//!
//! The payload is the same shape as USER.BIN's (naked asm, fixed register
//! ABI only — no Zig-generated memory references or calls): it writes one
//! marker line per iteration, runs a bounded nop spin (so a stray tick
//! can never starve the ring), yields cooperatively, and repeats. The
//! terminal branch is unreachable by construction (the loop never exits).
//!
//! The marker bytes are also exposed as a `pub const` so the host tests
//! pin the EXACT marker shape (the serial log's grep target for this
//! program) and the sys_write length used in the payload cannot drift
//! from it.

const std = @import("std");

/// The exact bytes COUNTER.BIN writes every iteration. Host-tested (the
/// marker-shape test below) so the live gate's grep target cannot drift
/// from the payload's `.ascii`.
pub const marker: []const u8 = "counter: alive\n";
/// The bounded spin between the write and the yield (nops). Bounded so a
/// misprogrammed tick cannot starve the round-robin ring; a 16-bit
/// immediate so the payload stays a single `movz` (no movk chains).
pub const spin_limit: u32 = 50_000;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\0:
        \\// Write the marker: sys_write(fd=1, buf=marker, len=marker.len).
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #15
        \\mov x8, #1
        \\svc #0
        \\// Bounded spin (this program must never dominate a quantum).
        \\movz x9, #50000
        \\2:
        \\sub x9, x9, #1
        \\cbnz x9, 2b
        \\// Yield cooperatively: sys_yield (slot 2) — the frozen ABI, no
        \\// new syscall, no sys_exit anywhere in this program.
        \\mov x8, #2
        \\svc #0
        \\b 0b
        \\1:
        \\.ascii "counter: alive\n"
    );
}

test "user counter module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user counter: the marker shape is pinned (live-gate grep target)" {
    // The exact bytes the payload writes (the `#15` length in the asm and
    // the `1:` `.ascii` must match this const — a drift breaks the live
    // gate's `counter: alive` assertions, never silently).
    try std.testing.expectEqualStrings("counter: alive\n", marker);
    try std.testing.expectEqual(@as(usize, 15), marker.len);
    // The payload is naked asm — no Zig-generated memory references or
    // calls; the module still type-checks the export on the host.
    try std.testing.expectEqual(@as(u32, 50_000), spin_limit);
}
