//! DipshitOS twenty-fourth ESP user program — TMRTEST.BIN (Milestone 14,
//! Card S2, claim 5390). The 8.3-short stem ("TMRTEST") fits the FAT 8.3
//! directory format — "TIMERTEST" is 9 chars and would exceed the 8-char
//! stem bound the ESP layer enforces.
//!
//! Headless class-B proof for the per-process application timer seam (ADR
//! 0007 slots 40/41): arm a one-shot timer and observe exactly one TIMER
//! event → arm a periodic timer and count three expiries → cancel it and
//! prove no event leaks → a stale cancel id is refused. One sequence,
//! printing a marker after each step for `tools/verify-live-timers.sh`.

const std = @import("std");
const ui = @import("lib/ui.zig");

fn fail(msg: []const u8) noreturn {
    ui.write_console(msg);
    ui.write_console("\n");
    ui.exit_process(1);
}

pub export fn _start() callconv(.c) noreturn {
    var ev: ui.Event = undefined;

    // 1. One-shot timer (ticks=2): fires exactly once with the armed id.
    const id1 = ui.timer_set(2, 0);
    if (id1 < 0) fail("timer: arm oneshot failed");
    ui.write_console("timer: armed oneshot\n");

    const w1 = ui.wait_event(&ev);
    if (w1 <= 0) fail("timer: oneshot wait failed");
    if (ev.kind != ui.TIMER or ev.arg0 != @as(u32, @intCast(id1))) fail("timer: oneshot event mismatch");
    ui.write_console("timer: oneshot fired\n");

    // A one-shot must not re-arm: the queue is empty right after.
    if (ui.poll_event(&ev) != 0) fail("timer: oneshot refired");
    ui.write_console("timer: oneshot spent\n");

    // 2. Periodic timer (ticks=1): three expiries, same id every time.
    const id2 = ui.timer_set(1, 1);
    if (id2 < 0) fail("timer: arm periodic failed");
    ui.write_console("timer: armed periodic\n");

    var n: u32 = 0;
    while (n < 3) : (n += 1) {
        const w = ui.wait_event(&ev);
        if (w <= 0) fail("timer: periodic wait failed");
        if (ev.kind != ui.TIMER or ev.arg0 != @as(u32, @intCast(id2))) fail("timer: periodic event mismatch");
    }
    ui.write_console("timer: periodic x3\n");

    // 3. Cancel the periodic timer: no event is left pending.
    if (ui.timer_cancel(@intCast(id2)) != 0) fail("timer: cancel failed");
    ui.write_console("timer: cancelled\n");
    if (ui.poll_event(&ev) != 0) fail("timer: cancel leaked event");
    ui.write_console("timer: cancel clean\n");

    // 4. A stale id is refused (EINVAL) — the slot is gone.
    if (ui.timer_cancel(@intCast(id2)) != -1) fail("timer: stale refused failed");
    ui.write_console("timer: stale refused\n");

    ui.write_console("timer: done\n");
    ui.exit_process(0);
}
