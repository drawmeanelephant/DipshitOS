//! DipshitOS bounded per-process application timers (Milestone 14, card S2 —
//! claim 5390).
//!
//! A fixed 8-entry kernel timer table (pure BSS, zero heap) tied to the
//! existing scheduler tick: `sys_timer_set(ticks, periodic)` arms a timer
//! owned by the calling process and returns a stable id; every expiry posts
//! a `TIMER` event (ADR 0009 kind 9, `arg0` = timer id) to the owner's
//! event FIFO — the same queue an app already blocks on via `sys_wait_event`.
//! One-shot timers (`periodic = 0`) fire once and free their slot; periodic
//! timers (`periodic = 1`) re-arm relative to the fire tick.
//!
//! Timers are per-process OWNED: only the owning process may cancel an id,
//! and `cancel_owner` disables every timer a process held when it exits (the
//! scheduler's `exit_current` calls it). No allocation, no libc, no POSIX.
//!
//! The module never touches the console or the scheduler: the scheduler
//! feeds `on_tick` with its tick counter (IRQ-context, console-free — the
//! claim-9187 discipline), and `events.push` runs the already-wired wakeup
//! hook so a blocked `sys_wait_event` caller wakes the moment its timer
//! fires.

const std = @import("std");
const events = @import("events.zig"); // TIMER kind + push + owner-bound validation
const process = @import("process.zig"); // the registry bound (max_processes)

/// Fixed timer table size (the issue's "e.g. 8 entries").
pub const max_timers: usize = 8;

/// One timer slot. `owner` is a process id (or `null` when free); `id` is a
/// monotonic handle that never reuses a freed slot's number, so a stale id
/// cannot cancel a timer that was re-armed by another process.
const Timer = struct {
    owner: ?usize = null,
    id: u32 = 0,
    period_ticks: u64 = 0,
    periodic: bool = false,
    next_fire: u64 = 0,
};

var table: [max_timers]Timer = [_]Timer{.{}} ** max_timers;
var next_id: u32 = 1;
/// The last tick the scheduler fed us (the arm baseline for `next_fire`).
var now_tick: u64 = 0;

fn in_range(pid: usize) bool {
    return pid < process.max_processes;
}

/// Reset every timer (kernel boot + host tests).
pub fn init() void {
    for (&table) |*t| t.* = .{};
    next_id = 1;
    now_tick = 0;
}

/// Arm a timer owned by `pid` that first fires `ticks` ticks from now.
/// Returns the new timer id, or `null` when the table is full, `ticks` is
/// zero, or `pid` is out of range (defensive).
pub fn arm(pid: usize, ticks: u64, periodic: bool) ?u32 {
    if (!in_range(pid) or ticks == 0) return null;
    for (&table) |*t| {
        if (t.owner != null) continue;
        t.* = .{
            .owner = pid,
            .id = next_id,
            .period_ticks = ticks,
            .periodic = periodic,
            .next_fire = now_tick + ticks,
        };
        const id = next_id;
        next_id +%= 1;
        return id;
    }
    return null;
}

/// Cancel timer `id` owned by `pid`. True when it was found and disabled.
pub fn cancel(pid: usize, id: u32) bool {
    for (&table) |*t| {
        if (t.owner == pid and t.id == id) {
            t.* = .{};
            return true;
        }
    }
    return false;
}

/// Disable every timer owned by `pid` (the process-exit cleanup seam).
pub fn cancel_owner(pid: usize) void {
    for (&table) |*t| {
        if (t.owner == pid) t.* = .{};
    }
}

/// True when timer `id` is still armed and owned by `pid` (host-test + gate
/// introspection).
pub fn active(pid: usize, id: u32) bool {
    for (&table) |*t| {
        if (t.owner == pid and t.id == id) return true;
    }
    return false;
}

/// Number of armed timers currently owned by `pid`.
pub fn count_owner(pid: usize) usize {
    var n: usize = 0;
    for (&table) |*t| {
        if (t.owner == pid) n += 1;
    }
    return n;
}

/// Scheduler tick hook (IRQ-context, console-free): record `now` and fire
/// every timer whose deadline has passed. A fired timer posts a `TIMER`
/// event; periodic timers re-arm relative to `now`, one-shot timers free
/// their slot.
pub fn on_tick(now: u64) void {
    now_tick = now;
    var i: usize = 0;
    while (i < max_timers) : (i += 1) {
        const t = &table[i];
        const owner = t.owner orelse continue;
        if (now < t.next_fire) continue;
        events.push(owner, .{
            .kind = events.TIMER,
            .flags = 0,
            .seq = 0,
            .arg0 = t.id,
            .arg1 = 0,
        });
        if (t.periodic) {
            t.next_fire = now + t.period_ticks;
        } else {
            t.* = .{};
        }
    }
}

// ---------------------------------------------------------------------------
// Tests (host-side; the live cross-process expiry is proven on VZ by
// tools/verify-live-timers.sh, class B)
// ---------------------------------------------------------------------------

test "timers: arm posts a TIMER event at the deadline and frees a one-shot" {
    init();
    events.init();
    const id = arm(0, 3, false).?;
    try std.testing.expect(active(0, id));
    try std.testing.expectEqual(@as(usize, 1), count_owner(0));

    // Two ticks pass: nothing fires yet.
    on_tick(1);
    on_tick(2);
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));

    // Third tick: one TIMER event carrying the timer id.
    on_tick(3);
    try std.testing.expectEqual(@as(usize, 1), events.pending(0));
    const ev = events.pop(0).?;
    try std.testing.expectEqual(events.TIMER, ev.kind);
    try std.testing.expectEqual(id, ev.arg0);

    // One-shot is spent: slot freed, no further events.
    try std.testing.expect(!active(0, id));
    try std.testing.expectEqual(@as(usize, 0), count_owner(0));
    on_tick(4);
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));
}

test "timers: periodic timers re-arm and keep firing" {
    init();
    events.init();
    const id = arm(0, 2, true).?;

    on_tick(1); // deadline 2 not reached
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));

    on_tick(2); // fire, re-arm to 4
    on_tick(4); // fire again, re-arm to 6
    on_tick(6); // fire a third time
    try std.testing.expectEqual(@as(usize, 3), events.pending(0));
    try std.testing.expect(active(0, id));

    var fires: usize = 0;
    while (events.pop(0)) |ev| {
        try std.testing.expectEqual(events.TIMER, ev.kind);
        try std.testing.expectEqual(id, ev.arg0);
        fires += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), fires);
}

test "timers: cancel removes the timer and a stale id cannot cancel a new one" {
    init();
    events.init();
    const id = arm(0, 1, true).?;
    try std.testing.expect(cancel(0, id));
    try std.testing.expect(!active(0, id));
    try std.testing.expect(!cancel(0, id)); // already gone
    on_tick(5);
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));

    // A re-armed timer gets a fresh id; the OLD id no longer cancels it.
    const id2 = arm(0, 1, true).?;
    try std.testing.expect(id2 != id);
    try std.testing.expect(!cancel(0, id));
    try std.testing.expect(active(0, id2));
}

test "timers: ownership is enforced — only the owner may cancel" {
    init();
    events.init();
    const id = arm(0, 1, true).?;
    try std.testing.expect(!cancel(1, id)); // wrong process
    try std.testing.expect(active(0, id));
    try std.testing.expect(cancel(0, id));
}

test "timers: cancel_owner clears every timer for the exiting process" {
    init();
    events.init();
    _ = arm(0, 1, true).?;
    _ = arm(0, 2, false).?;
    _ = arm(1, 3, true).?;
    try std.testing.expectEqual(@as(usize, 2), count_owner(0));

    cancel_owner(0);
    try std.testing.expectEqual(@as(usize, 0), count_owner(0));
    try std.testing.expectEqual(@as(usize, 1), count_owner(1));
}

test "timers: defensive refusals — zero ticks, out-of-range pid, full table" {
    init();
    events.init();
    try std.testing.expect(arm(0, 0, true) == null);
    try std.testing.expect(arm(process.max_processes, 1, true) == null);

    // Fill the table, then the next arm is refused.
    var i: usize = 0;
    while (i < max_timers) : (i += 1) {
        _ = arm(0, 1, true).?;
    }
    try std.testing.expectEqual(@as(usize, max_timers), count_owner(0));
    try std.testing.expect(arm(0, 1, true) == null);
}
