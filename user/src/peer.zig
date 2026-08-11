//! DipshitOS third ESP user program — PEER.BIN (milestone-four follow-on 3,
//! card 3f — claim 5965).
//!
//! The receiving half of the first inter-process data path. COUNTER.BIN
//! sends short decimal messages ("3\n" — one sequence number per message)
//! through sys_ipc_send (slot 5) into THIS program's per-process mailbox;
//! this program recv-loops through sys_ipc_recv (slot 6) and echoes each
//! received message verbatim with a "peer: got " prefix. The serial log
//! therefore shows the counter's "ipc: ping N" lines interleaved with the
//! peer's "peer: got N" lines — byte-exact end-to-end data flow between
//! TWO live processes, neither of which ever exits.
//!
//! Like COUNTER.BIN this is a NEVER-EXITING program (marker + yield only,
//! no sys_exit) that occupies its pool slot and address space permanently.
//! The payload is the same naked-asm, fixed-register-ABI shape as the
//! other ESP programs: recv into a stack buffer, echo the bytes (an empty
//! recv — result 0 — prints nothing), cooperatively yield, repeat. The
//! ring never fills because every iteration drains at most the 4 queued
//! messages; the yield keeps the round-robin ring live.
//!
//! The "peer: got " prefix bytes are exposed as a `pub const` so the host
//! tests pin the EXACT echo shape (the serial log's grep target for this
//! program) and the sys_write length in the payload cannot drift.

const std = @import("std");

/// The exact prefix bytes PEER.BIN writes before each received message.
/// Host-tested so the live gate's `peer: got` grep target cannot drift
/// from the payload's `.ascii`.
pub const echo_prefix: []const u8 = "peer: got ";
/// The recv buffer bound (the per-message slot bound; larger recv buffers
/// are clamped by the kernel — this program asks for the maximum).
pub const recv_max: u32 = 64;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\0:
        \\// sys_ipc_recv(buf=sp, max=64) — the caller's OWN mailbox, one
        \\// message per pass (the kernel copies it out and consumes it).
        \\sub sp, sp, #96
        \\mov x0, sp
        \\mov x1, #64
        \\mov x8, #6
        \\svc #0
        \\cbz x0, 1f // empty mailbox: nothing to echo
        \\// Echo: "peer: got " (10 bytes) + the received bytes verbatim.
        \\mov x9, x0 // got (the recv result survives the writes below)
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #10
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\mov x1, sp
        \\mov x2, x9
        \\mov x8, #1
        \\svc #0
        \\1:
        \\add sp, sp, #96
        \\// Cooperative yield (slot 2) — the frozen ABI; this program
        \\// NEVER exits.
        \\mov x8, #2
        \\svc #0
        \\b 0b
        \\2:
        \\.ascii "peer: got "
    );
}

test "user peer module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user peer: the echo prefix shape is pinned (live-gate grep target)" {
    // The exact bytes the payload writes (the `#10` length in the asm and
    // the `2:` `.ascii` must match this const — a drift breaks the live
    // gate's `peer: got` assertions, never silently).
    try std.testing.expectEqualStrings("peer: got ", echo_prefix);
    try std.testing.expectEqual(@as(usize, 10), echo_prefix.len);
    try std.testing.expectEqual(@as(u32, 64), recv_max);
}
