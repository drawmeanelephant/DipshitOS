//! DipshitOS twenty-third ESP user program — TIMER.BIN (Milestone 14, Card
//! S2, claim 7323).
//!
//! Headless class-B proof for the per-process application timer seam (ADR
//! 0007 slots 40–41): arm a timer, BLOCK in `sys_wait_event` (no spin
//! loop — the whole point of the card), observe the `TIMER` event the
//! kernel posts when the countdown reaches zero, then prove the cancel
//! half (nothing pending → 0, a live pending timer → 1). Each step prints
//! a marker for `tools/verify-live-timers.sh`.

const ui = @import("lib/ui.zig");

fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    @memcpy(buf[pos .. pos + src.len], src);
    return pos + src.len;
}

fn fmt_u64(buf: []u8, value: u64) []const u8 {
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }
    return buf[i..];
}

fn print_seq(prefix: []const u8, seq: u32) void {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    pos = append_str(&buf, pos, prefix);
    pos = append_str(&buf, pos, " seq=");
    pos = append_str(&buf, pos, fmt_u64(buf[pos..], seq));
    buf[pos] = '\n';
    ui.write_console(buf[0 .. pos + 1]);
}

/// Wait for the NEXT event and report it. Returns true when it is a TIMER
/// event (any other kind is reported honestly and skipped — the event queue
/// starts clean at exec, so this should never happen).
fn wait_for_timer(tag: []const u8) bool {
    var ev: ui.Event = undefined;
    const n = ui.wait_event(&ev);
    if (n <= 0) {
        ui.write_console("timertest: wait failed\n");
        return false;
    }
    if (ev.kind != ui.EVENT_TIMER) {
        ui.write_console("timertest: wrong kind\n");
        return false;
    }
    print_seq(tag, ev.seq);
    return true;
}

export fn _start() callconv(.c) noreturn {
    // 1. Arm a 2-tick timer; block in wait_event until the TIMER event.
    if (ui.timer_set(2) < 0) {
        ui.write_console("timertest: set1 failed\n");
        ui.exit_process(1);
    }
    ui.write_console("timertest: armed 2\n");
    if (!wait_for_timer("timertest: fired")) {
        ui.exit_process(2);
    }

    // 2. Cancel with nothing pending -> 0 (and the module reports no arms).
    const c0 = ui.timer_cancel();
    if (c0 != 0) {
        ui.write_console("timertest: cancel-none failed\n");
        ui.exit_process(3);
    }
    ui.write_console("timertest: cancel-none\n");

    // 3. Arm a 1-tick timer; the second TIMER event arrives one tick later.
    if (ui.timer_set(1) < 0) {
        ui.write_console("timertest: set2 failed\n");
        ui.exit_process(4);
    }
    ui.write_console("timertest: armed 1\n");
    if (!wait_for_timer("timertest: fired2")) {
        ui.exit_process(5);
    }

    // 4. Arm a 5-tick timer, then cancel it while pending -> 1, and prove
    //    nothing ever fires (the program exits before the countdown ends).
    if (ui.timer_set(5) < 0) {
        ui.write_console("timertest: set3 failed\n");
        ui.exit_process(6);
    }
    const c1 = ui.timer_cancel();
    if (c1 != 1) {
        ui.write_console("timertest: cancel-pending failed\n");
        ui.exit_process(7);
    }
    ui.write_console("timertest: canceled\n");

    ui.write_console("timertest: done\n");
    ui.exit_process(23);
}
