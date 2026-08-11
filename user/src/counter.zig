//! DipshitOS second ESP user program — COUNTER.BIN (milestone-four
//! follow-on 2, claim 4613; extended by follow-on 3 card 3f, claim 5965 —
//! the IPC sender; extended by follow-on 4 card 4b, claim 3179 — the
//! burst cadence).
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
//! Card 3f (claim 5965) + card 4b (claim 3179): COUNTER.BIN is also the
//! IPC SENDER. When exec'd with a target process id argument
//! (`exec COUNTER.BIN <pid>`, claim-4636 argv), it parses argv[0] as the
//! peer's pid and — every 6th iteration — sends a BURST of 6 messages
//! back-to-back in ONE quantum: each message is formatted as "ping <d>\n"
//! into a 64-byte stack scratch buffer, printed as "ipc: ping <d>"
//! (sys_write, slot 1 — the live gate's send marker), and sent through
//! sys_ipc_send (slot 5, the card-3f ABI amendment) to the peer's
//! per-process mailbox. A negative send result (ENOSPC -5 or an error)
//! prints the distinct "ipc: enospc\n" marker — the live gate asserts
//! ZERO of them. The 5 quiet iterations between bursts let the peer drain
//! one message per round (the peer is not scheduled mid-burst — one
//! quantum is one task — so the 8-slot ring peaks at 6 of 8 and drains to
//! 0 before the next burst: NEVER refused, deterministically). The peer
//! echoes each message back ("peer: got ping <d>", byte-exact). Exec'd
//! WITHOUT an argument (argc == 0 — how the earlier long-lived gates run
//! it), the counter's behavior is byte-identical to claim 4613: marker +
//! spin + yield, no IPC.
//!
//! The payload is the same shape as USER.BIN's (naked asm, fixed register
//! ABI only — no Zig-generated memory references or calls): registers
//! x20-x26 carry the entry contract and loop state across SVC boundaries
//! (the kernel saves/restores the full frame), the scratch buffer lives on
//! the program's OWN writable EL0 stack, and the terminal branch is
//! unreachable by construction (the loop never exits).
//!
//! The marker bytes are also exposed as `pub const`s so the host tests
//! pin the EXACT marker shapes (the serial log's grep targets for this
//! program) and the sys_write/sys_ipc_send lengths used in the payload
//! cannot drift from them.

const std = @import("std");

/// The exact bytes COUNTER.BIN writes every iteration. Host-tested (the
/// marker-shape test below) so the live gate's grep target cannot drift
/// from the payload's `.ascii`.
pub const marker: []const u8 = "counter: alive\n";
/// The "ipc: ping " prefix printed before each sent sequence number.
pub const ipc_prefix: []const u8 = "ipc: ping ";
/// The "ping " prefix of the SENT payload (the peer echoes it back).
pub const ping_prefix: []const u8 = "ping ";
/// The distinct marker printed when a send is refused (ENOSPC -5 or any
/// negative result). The live gate asserts ZERO of these — the burst
/// never overflows the 8-slot ring (card 4b).
pub const enospc_marker: []const u8 = "ipc: enospc\n";
/// The burst length (card 4b): 6 messages back-to-back in ONE quantum.
/// The peer cannot drain mid-burst, so the ring peaks at 6 of the 8
/// slots; 5 quiet iterations drain it to 0 before the next burst.
pub const burst_len: u32 = 6;
/// The bounded spin between the write and the yield (nops). Bounded so a
/// misprogrammed tick cannot starve the round-robin ring; a 16-bit
/// immediate so the payload stays a single `movz` (no movk chains).
pub const spin_limit: u32 = 50_000;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// Claim 4636 entry contract: x0 = argc, x1 = argv block VA.
        \\mov x20, x0
        \\mov x21, x1
        \\mov x22, #1 // send sequence number (starts at 1)
        \\mov x23, #0 // iteration counter (burst cadence)
        \\mov x24, xzr // target pid (default: none)
        \\cbz x20, 6f // no args: never sends (claim-4613 behavior)
        \\// Parse argv[0] (the first 32-byte slot) as a decimal pid.
        \\mov x25, x21
        \\mov x26, #32
        \\mov x10, #10
        \\10:
        \\ldrb w9, [x25]
        \\sub x9, x9, #48 // '0' = 0x30
        \\cmp x9, #10
        \\b.hs 6f // non-digit: done parsing
        \\mul x24, x24, x10
        \\add x24, x24, x9
        \\add x25, x25, #1
        \\subs x26, x26, #1
        \\b.ne 10b
        \\6:
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
        \\// Card 4b: every 6th iteration, a BURST of 6 messages sent
        \\// back-to-back in ONE quantum (the peer is not scheduled
        \\// mid-burst), then 5 quiet iterations (the peer drains 1 per
        \\// round, so the ring peaks at 6 of the 8 slots and drains to
        \\// 0 before the next burst — NO ENOSPC, deterministically).
        \\add x23, x23, #1
        \\cmp x23, #6
        \\b.lo 3f
        \\mov x23, xzr // reset the cadence counter
        \\cbz x24, 3f // no target (argc == 0): claim-4613 behavior
        \\mov x26, #6 // burst length
        \\7:
        \\// Build the payload "ping <d>\n" on a 64-byte stack scratch:
        \\// digits written from the end, then the newline, then the
        \\// "ping " prefix immediately before them.
        \\sub sp, sp, #64
        \\mov x9, x22 // seq
        \\mov x10, #10
        \\add x14, sp, #62 // write digits from the second-to-last byte (the
        \\// '\n' lands at sp+63 — the uaccess stack region is EXCLUSIVE at
        \\// the top, so the whole payload must stay inside sp..sp+63).
        \\mov x16, #0 // digit count
        \\4:
        \\udiv x11, x9, x10
        \\msub x12, x11, x10, x9 // remainder = seq - q*10
        \\add x12, x12, #48 // '0'
        \\strb w12, [x14]
        \\sub x14, x14, #1
        \\mov x9, x11
        \\add x16, x16, #1
        \\cbnz x9, 4b
        \\add x14, x14, #1 // x14 = first digit
        \\mov x12, #10
        \\strb w12, [x14, x16] // '\n' after the digits
        \\add x16, x16, #1 // tail len = digits + 1 (the "<d>\n" part)
        \\sub x15, x14, #5 // message start: the "ping " prefix before the digits
        \\mov x12, #112 // 'p'
        \\strb w12, [x15]
        \\mov x12, #105 // 'i'
        \\strb w12, [x15, #1]
        \\mov x12, #110 // 'n'
        \\strb w12, [x15, #2]
        \\mov x12, #103 // 'g'
        \\strb w12, [x15, #3]
        \\mov x12, #32 // ' '
        \\strb w12, [x15, #4]
        \\// Print the send marker: "ipc: ping " + "<d>\n" (the tail at
        \\// x15+5 carries the digits and the newline).
        \\mov x0, #1
        \\adr x1, 5f
        \\mov x2, #10
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\add x1, x15, #5
        \\mov x2, x16
        \\mov x8, #1
        \\svc #0
        \\// Send the payload "ping <d>\n": sys_ipc_send(pid, buf, len) —
        \\// slot 5 (the card-3f ABI amendment).
        \\mov x0, x24
        \\mov x1, x15
        \\mov x2, x16
        \\add x2, x2, #5
        \\mov x8, #5
        \\svc #0
        \\// Check the result: a negative return (ENOSPC -5 or an error)
        \\// prints the distinct "ipc: enospc\n" marker — the live gate
        \\// asserts ZERO of them (the burst never overflows the ring).
        \\cmp x0, #0
        \\b.ge 9f
        \\mov x0, #1
        \\adr x1, 8f
        \\mov x2, #12
        \\mov x8, #1
        \\svc #0
        \\9:
        \\add sp, sp, #64
        \\add x22, x22, #1 // next sequence number
        \\subs x26, x26, #1
        \\b.ne 7b
        \\3:
        \\// Yield cooperatively: sys_yield (slot 2) — the frozen ABI, no
        \\// sys_exit anywhere in this program.
        \\mov x8, #2
        \\svc #0
        \\b 0b
        \\1:
        \\.ascii "counter: alive\n"
        \\5:
        \\.ascii "ipc: ping "
        \\8:
        \\.ascii "ipc: enospc\n"
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
    // The send marker's prefix (the `#10` length in the asm and the `5:`
    // `.ascii` must match this const).
    try std.testing.expectEqualStrings("ipc: ping ", ipc_prefix);
    try std.testing.expectEqual(@as(usize, 10), ipc_prefix.len);
    // The sent payload's prefix (the five `strb` immediates in the asm
    // must spell this exact string).
    try std.testing.expectEqualStrings("ping ", ping_prefix);
    try std.testing.expectEqual(@as(usize, 5), ping_prefix.len);
    // The refusal marker (the `#12` length in the asm and the `8:`
    // `.ascii` must match this const — the live gate asserts ZERO).
    try std.testing.expectEqualStrings("ipc: enospc\n", enospc_marker);
    try std.testing.expectEqual(@as(usize, 12), enospc_marker.len);
    // The burst length (the `#6` immediate in the asm must match this
    // const — 6 messages per burst quantum, 6 of the 8 slots at the peak).
    try std.testing.expectEqual(@as(u32, 6), burst_len);
    // The payload is naked asm — no Zig-generated memory references or
    // calls; the module still type-checks the export on the host.
    try std.testing.expectEqual(@as(u32, 50_000), spin_limit);
}
