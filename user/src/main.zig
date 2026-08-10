//! DipshitOS user program loaded from the ESP (milestone-three card 6,
//! claim 6783).
//!
//! Built as a freestanding AArch64 flat image (USER.BIN, DSK1 format via
//! tools/elf2bin.py — the same tooling as KERNEL.BIN), embedded on the ESP
//! by the image builder, read through the claim-6420 FAT path by the
//! kernel's `exec` monitor command, and entered at EL0 under a fresh user
//! root that maps this page at `userspace.text_va`.
//!
//! The payload is deliberately identical in shape to the claim-8215 static
//! payload (naked asm, fixed register ABI only — no Zig-generated memory
//! references or calls): it proves the loaded image actually executes at
//! EL0 by (1) writing a marker line through sys_write (fd 1, slot 1), which
//! lands directly in the serial log, (2) round-tripping two sequenced
//! sys_ping calls (slot 0) — the second valid call proves the first SVC
//! returned to EL0 — and (3) exiting with a distinct status (0x2a = 42)
//! through the non-returning sys_exit (slot 3), closing the claim-6729
//! lifecycle. The terminal branch is only a fail-safe park if a ping
//! round-trip comes back wrong.

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #25
        \\mov x8, #1
        \\svc #0
        \\// Two sequenced pings: x0 = 1 then 2; each SVC must return the
        \\// same value (the claim-8215 round-trip proof from a LOADED
        \\// image). Any mismatch parks in the fail-safe branch.
        \\mov x9, xzr
        \\2:
        \\add x9, x9, #1
        \\mov x0, x9
        \\mov x8, #0
        \\svc #0
        \\cmp x0, x9
        \\b.ne 3f
        \\cmp x9, #2
        \\b.lo 2b
        \\mov x0, #1
        \\adr x1, 4f
        \\mov x2, #14
        \\mov x8, #1
        \\svc #0
        \\mov x0, #0x2a
        \\mov x8, #3
        \\svc #0
        \\3:
        \\b 3b
        \\1:
        \\.ascii "user: hello from the ESP"
        \\.byte 10
        \\4:
        \\.ascii "user: exec ok"
        \\.byte 10
    );
}

// A host-side test cannot execute the naked payload, but compiling this
// module on the host (aarch64 test runner) still type-checks the export.
test "user program module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}
