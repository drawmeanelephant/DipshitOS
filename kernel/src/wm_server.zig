//! DipshitOS M32 WMS2 render-server register (issue #622) — the kernel half
//! of the ADR 0015 seam-A render-server boundary, implemented BESIDE the
//! unchanged shim (`kernel/src/driving_award.zig`).
//!
//! This module owns the render-server seam's minimal observable state:
//! the single WM registrant (one seat), the present-sequence counter (the
//! parity-cards' observability primitive), and the kind-18 `COMPOSITE_TICK`
//! tick-delivery seam. It deliberately holds NO desktop policy — that stays
//! in the shim until the WM-server drain-out cards (WMS4–WMS6); this card
//! only puts the register the future userland WM will drive in place.
//!
//! Zero-regression contract (the WMS2 binding rule): when no WM is
//! registered nothing changes — the shell idle `drain` keeps compositing
//! exactly as today and every pre-M32 gate stays byte-identical. Only after
//! `REGISTER` does composite pacing move to the tick path (the shell guards
//! its idle `drain` call on `registered()`, one flag check on the hot path).
//!
//! Routing restriction (ADR 0009 D2): kind 18 `COMPOSITE_TICK` is the FIRST
//! routing-restricted kernel event kind — delivered EXCLUSIVELY to the
//! registered WM's process queue via `events.push`, never generated when no
//! WM is registered.
//!
//! No allocation, no libc, no POSIX — pure kernel BSS + the existing
//! `events` / `virtio_gpu` seams (both leaf modules, no import cycle).
//! WM-death teardown mirrors the `close_owner(pid)` window-teardown semantic
//! in the scheduler exit path: on WM process exit the kernel unregisters it
//! and pacing automatically falls back to the shell idle shim.

const std = @import("std");
const builtin = @import("builtin");
const events = @import("events.zig");
const process = @import("process.zig"); // the registry row bound (max_processes) — used only by the host tests
const virtio_gpu = @import("virtio_gpu.zig");
const driving_award = @import("driving_award.zig"); // M32 WMS4: the renderer owns the chrome state the seam's teardown clears

/// Slot-65 subcommand encoding — frozen by WMS1 (claim 1484) in the ADR 0007
/// amendment. Do NOT renumber these; WMS4+ implement `SET_WINDOW` against
/// the same opcode.
pub const wmctl_register: u64 = 1;
pub const wmctl_set_window: u64 = 2;
pub const wmctl_request_present: u64 = 3;
/// M32 WMS5 Gate 2 (claim 4278): SET_STATE — the visibility/workspace
/// channel of the geometry seam. a0 = window id, a1 = visible (bit 0) |
/// workspace (bits 8-11); applied through the same clamped kernel
/// primitives the shim uses (user_set_visible + move-to-workspace).
pub const wmctl_set_state: u64 = 4;
/// M32 WMS6 Gate A (issue #626): ALT_TAB — the desktop-chrome drain's first
/// read-mostly surface. a0 = window id, a1 = action: the WM (not the kernel)
/// decides WHICH window Alt+Tab switches to; the kernel clamps + repaints
/// the overlay blit from WM-declared state. The action encoding is frozen
/// here (ADR 0007 amendment by this claim).
pub const wmctl_alt_tab: u64 = 5;
/// ALT_TAB actions (a1) — mirror the kernel shim's overlay state machine
/// (activate/cycle/commit/dismiss) but driven by the WM's chosen id.
pub const alt_tab_activate: u64 = 1;
pub const alt_tab_cycle: u64 = 2;
pub const alt_tab_commit: u64 = 3;
pub const alt_tab_dismiss: u64 = 4;
/// M32 WMS6 Gate B (issue #626): NOTIF_CENTER — the notification-center
/// surface. a0 = 0 close, 1 open, 2 clear-all. The WM decides the panel's
/// open/close/clear; the kernel clamps + blits from its own `notif_center_open`.
pub const wmctl_notif_center: u64 = 6;
/// NOTIF_DISMISS — a0 = row index; the WM dismisses one notification.
pub const wmctl_notif_dismiss: u64 = 7;

/// The single registered WM server process id; null = no WM registered
/// (shim mode, the default — every pre-M32 gate runs in this state).
var wm_pid: ?usize = null;
/// Monotonic present sequence (arg0 of every COMPOSITE_TICK), wraps at 2³².
/// Advanced only by REQUEST_PRESENT — a stalled WM shows a frozen sequence,
/// so parity gates can detect that it stopped presenting.
var present_seq: u32 = 0;
/// Total REQUEST_PRESENT calls accepted (the observable present counter).
var present_count: u64 = 0;
/// Total COMPOSITE_TICK events delivered to the registered WM.
var tick_count: u64 = 0;
/// M32 WMS4 (issue #624): total SET_WINDOW chrome-descriptor submissions
/// accepted (the `wm` observability counter — submissions counted). The
/// descriptors themselves live in `driving_award` (per-window + policy);
/// this seam only counts, per its no-policy charter.
var set_window_count: u64 = 0;
/// M32 WMS6 Gate A (issue #626): total ALT_TAB submissions accepted (the
/// observability counter — how many desktop-chrome decisions the WM made).
var alt_tab_apply_count: u64 = 0;
/// M32 WMS6 Gate B (issue #626): NOTIF_CENTER / NOTIF_DISMISS submissions
/// accepted — the notification-center decisions the WM made.
var notif_center_count: u64 = 0;
var notif_dismiss_count: u64 = 0;
/// Set when the registered WM exits (teardown) — the shell idle loop drains
/// this into the `wm: unregistered, shim resumed` report (the exit path is
/// IRQ context and console-free, so the report is drained like the process
/// exit reports, not printed inline).
var fallback_pending: bool = false;

/// Reset the seam (kernel boot + host-test setups).
pub fn init() void {
    wm_pid = null;
    present_seq = 0;
    present_count = 0;
    tick_count = 0;
    set_window_count = 0;
    set_state_count = 0;
    alt_tab_apply_count = 0;
    notif_center_count = 0;
    notif_dismiss_count = 0;
    pointer_fan_count = 0;
    window_mirror_count = 0;
    key_fan_count = 0;
    fallback_pending = false;
    // M32 WMS5: a reset is a teardown — input ownership returns to the
    // shim and the fan-out hooks are detached (a stale `wm_owns_input=true`
    // stranded by a mid-test re-init would silently gate the kernel's
    // geometry off in later aggregated tests). init() is the one place
    // every setup path converges, so the reset is complete here.
    driving_award.wm_owns_input = false;
    driving_award.wm_pointer_hook = null;
    driving_award.wm_window_hook = null;
    // M32 WMS5 Gate 2 (claim 4278): the keyboard fan-out hook detaches too.
    driving_award.wm_key_hook = null;
}

/// True when a WM is registered (composite pacing has moved to the tick path).
pub fn registered() bool {
    return wm_pid != null;
}

/// The registered WM's process id, if any.
pub fn registered_pid() ?usize {
    return wm_pid;
}

/// Accept the registering process as the active compositor. One seat: a
/// second registration while a WM is already registered is refused (the
/// handler maps that to `EACCES` — seat taken). The gpu/unarmed check is
/// the handler's (it needs the module-level error result); this is the pure
/// state transition. Returns true on success.
pub fn register(pid: usize) bool {
    if (wm_pid != null) return false;
    wm_pid = pid;
    fallback_pending = false;
    // M32 WMS5: the WM now owns input — the kernel stops consuming pointer
    // geometry (the flag gate in driving_award.pointer_tick). The cursor
    // stays a kernel blit; only the geometry DECISIONS move out. The raw
    // pointer + registry mirrors fan out through these hooks (set at
    // register, nulled at unregister — null hook = no WM = no-op).
    driving_award.wm_owns_input = true;
    driving_award.wm_pointer_hook = fan_pointer;
    driving_award.wm_window_hook = fan_window;
    // M32 WMS5 Gate 2 (claim 4278): the keyboard half of the input seam —
    // the raw key stream fans out to the WM (the shell idle's keyboard
    // geometry consumers are gated off behind `wm_owns_input`).
    driving_award.wm_key_hook = fan_key;
    return true;
}

/// WM-death teardown: unregister `pid`. Returns true only when `pid` WAS the
/// registrant (mirrors the `close_owner(caller)` window-teardown contract in
/// the scheduler exit path, which calls this per exiting process) — a false
/// return is a no-op for unrelated exits.
pub fn unregister(pid: usize) bool {
    if (wm_pid != pid) return false;
    wm_pid = null;
    fallback_pending = true;
    // M32 WMS4: the WM's chrome decisions die with it — the shim fallback
    // must restore its own chrome rules (a dead WM's look must not stay
    // painted). driving_award imports only wnd_core, so this import is
    // cycle-free (the seam delegates render-state teardown to the renderer).
    driving_award.clear_wm_chrome();
    // M32 WMS5: the WM's input ownership dies with it — the kernel resumes
    // consuming pointer geometry (shim fallback, byte-identical to pre-WMS5).
    driving_award.wm_owns_input = false;
    driving_award.wm_pointer_hook = null;
    driving_award.wm_window_hook = null;
    driving_award.wm_key_hook = null;
    return true;
}

/// Consolidate (drain-as-report): true ONCE after a teardown fallback, then
/// false until the next unregister. Called by the shell idle loop to print
/// `wm: unregistered, shim resumed` — the exit path itself (IRQ context,
/// claim 9187) cannot print; this is the report-drain pattern shared with
/// the process exit reports.
pub fn take_fallback_report() bool {
    if (!fallback_pending) return false;
    fallback_pending = false;
    return true;
}

/// Scheduler tick seam (the SAME host-testable tick seam `app_timers.on_tick`
/// fires from — WMS1 frozen decision 3): while a WM is registered, deliver
/// ONE `COMPOSITE_TICK` (kind 18) into the registrant's process event queue,
/// arg0 = present sequence, arg1 = reserved (0). Routing restritriction:
/// this is delivered ONLY to `wm_pid`. A no-op when no WM is registered
/// (nothing changes in shim mode). `events.push` wakes a blocked
/// `sys_wait_event` caller via the `on_event_pushed` hook.
pub fn on_tick() void {
    const pid = wm_pid orelse return;
    tick_count +%= 1;
    events.push(pid, .{
        .kind = events.COMPOSITE_TICK,
        .flags = 0,
        .seq = 0,
        .arg0 = present_seq,
        .arg1 = 0,
    });
}

/// REQUEST_PRESENT (cmd 3): transfer+flush the scanout now through the G1
/// seam and advance the present-sequence counter (the parity-cards'
/// observability primitive) + the present count. Returns false when no WM is
/// registered (the handler refuses the caller EACCES BEFORE this). The
/// transfer+flush is a no-op-safe attempt when the transport is unarmed; the
/// counters reflect what the WM requested, which is the observable present.
pub fn request_present() bool {
    _ = wm_pid orelse return false;
    present_seq +%= 1;
    present_count +%= 1;
    // The G1 transfer+flush is real-hardware work: exec_cmd runs `dc ivac`
    // cache-maintenance asm, which is illegal at EL0 in host test binaries
    // (and other tests in an aggregated binary may have armed the transport).
    // Gate it the established way (the handle_mmap `!builtin.is_test`
    // pattern): on a host test the counters still advance — the present was
    // SCHEDULED, which is the observable contract — and the live gate runs
    // the real transfer+flush on the kernel image.
    if (!builtin.is_test) {
        _ = virtio_gpu.gpu_transfer();
        _ = virtio_gpu.gpu_flush();
    }
    return true;
}

/// Read-only snapshot for the monitor `wm` report row.
pub const WmInfo = struct {
    pid: ?usize,
    present_seq: u32,
    present_count: u64,
    tick_count: u64,
    set_window_count: u64,
    set_state_count: u64,
    alt_tab_apply_count: u64,
    notif_center_count: u64,
    notif_dismiss_count: u64,
    pointer_fan_count: u64,
    window_mirror_count: u64,
    key_fan_count: u64,
};

pub fn info() WmInfo {
    return .{
        .pid = wm_pid,
        .present_seq = present_seq,
        .present_count = present_count,
        .tick_count = tick_count,
        .set_window_count = set_window_count,
        .set_state_count = set_state_count,
        .alt_tab_apply_count = alt_tab_apply_count,
        .notif_center_count = notif_center_count,
        .notif_dismiss_count = notif_dismiss_count,
        .pointer_fan_count = pointer_fan_count,
        .window_mirror_count = window_mirror_count,
        .key_fan_count = key_fan_count,
    };
}

/// M32 WMS4: count one accepted SET_WINDOW submission (the syscall layer
/// calls this AFTER the descriptor was validated and stored).
pub fn note_set_window() void {
    set_window_count +%= 1;
}

// ---------------------------------------------------------------------------
// M32 WMS5 (issue #625): the INPUT SEAM — the registered WM receives the raw
// pointer stream (kind 19 WM_POINTER) and the window-registry mirrors (kind
// 20 WM_WINDOW); the kernel stops consuming pointer geometry while a WM is
// registered (cursor stays a kernel blit surface). Routing restriction = the
// kind-18 discipline: every fan-out is a no-op when no WM is registered.
// ---------------------------------------------------------------------------

/// Total WM_POINTER raw-stream events fanned out to the registered WM.
var pointer_fan_count: u64 = 0;
/// Total WM_WINDOW registry-mirror events fanned out to the registered WM.
var window_mirror_count: u64 = 0;
/// Total WM_KEY raw-keyboard events fanned out to the registered WM (WMS5
/// Gate 2, claim 4278 — the keyboard half of the input seam).
var key_fan_count: u64 = 0;
/// Total SET_STATE (cmd 4) calls applied by the registered WM (visibility /
/// workspace changes — the geometry seam's state channel, claim 4278).
var set_state_count: u64 = 0;

/// Fan ONE raw absolute-pointer sample to the registered WM (the input
/// handover): kind 19, `arg0` = x|(y<<16) in fb pixels, `flags` low byte =
/// the raw HID button byte. No-op when no WM is registered (shim mode —
/// the kernel's own pointer_tick keeps consuming geometry exactly as
/// before; zero regression). Caller maps HID logicals to pixels first.
pub fn fan_pointer(x: u32, y: u32, buttons: u8) void {
    const pid = wm_pid orelse return;
    pointer_fan_count +%= 1;
    events.push(pid, .{
        .kind = events.WM_POINTER,
        .flags = buttons,
        .seq = 0,
        .arg0 = x | (y << 16),
        .arg1 = 0,
    });
}

/// Fan ONE window-registry mirror to the registered WM (so it can
/// hit-test): kind 20, `flags` = id | visible<<8 | focused<<9 |
/// workspace<<10, `arg0` = x|(y<<16), `arg1` = w|(h<<16). No-op when no WM
/// is registered.
pub fn fan_window(id: u8, x: u32, y: u32, w: u32, h: u32, visible: bool, focused: bool, workspace: u8) void {
    const pid = wm_pid orelse return;
    window_mirror_count +%= 1;
    var flags: u16 = id;
    if (visible) flags |= 1 << 8;
    if (focused) flags |= 1 << 9;
    flags |= @as(u16, workspace & 0x3) << 10;
    events.push(pid, .{
        .kind = events.WM_WINDOW,
        .flags = flags,
        .seq = 0,
        .arg0 = x | (y << 16),
        .arg1 = w | (h << 16),
    });
}

/// Fan ONE raw keyboard sample to the registered WM (the input handover's
/// keyboard half): kind 21, `arg0` = the raw HID keyboard usage byte,
/// `flags` = ADR 0009 modifier bits. No-op when no WM is registered (shim
/// mode — the kernel's own keyboard geometry consumers keep working exactly
/// as before; zero regression). Caller edge-detects (key-DOWN only).
pub fn fan_key(usage: u8, flags: u16) void {
    const pid = wm_pid orelse return;
    key_fan_count +%= 1;
    events.push(pid, .{
        .kind = events.WM_KEY,
        .flags = flags,
        .seq = 0,
        .arg0 = usage,
        .arg1 = 0,
    });
}

/// Note a SET_STATE (cmd 4) call — the WM's visibility/workspace change.
pub fn note_set_state() void {
    set_state_count +%= 1;
}

/// Note an ALT_TAB (cmd 5) submission — a desktop-chrome decision the WM
/// made (activate/cycle/commit/dismiss).
pub fn note_alt_tab() void {
    alt_tab_apply_count +%= 1;
}

/// Note a NOTIF_CENTER (cmd 6) submission — the WM's open/close/clear call.
pub fn note_notif_center() void {
    notif_center_count +%= 1;
}

/// Note a NOTIF_DISMISS (cmd 7) submission — the WM dismissing a row.
pub fn note_notif_dismiss() void {
    notif_dismiss_count +%= 1;
}

// ---------------------------------------------------------------------------
// Host tests (Class A) — the pure register/teardown/tick/present contracts
// ---------------------------------------------------------------------------

test "wm_server: register is one-seat and teardown falls back to the shim" {
    init();
    // No WM registered: shim mode.
    try std.testing.expect(!registered());
    try std.testing.expect(registered_pid() == null);

    // First register wins; a second is refused (the handler maps it to EACCES).
    try std.testing.expect(register(3));
    try std.testing.expect(registered());
    try std.testing.expectEqual(@as(?usize, 3), registered_pid());
    try std.testing.expect(!register(5));

    // WMS5 (issue #625): registering hands input ownership to the WM — the
    // kernel stops consuming pointer geometry and the raw-stream fan-out
    // hooks go live (they no-op when no WM is registered).
    try std.testing.expect(driving_award.wm_owns_input);
    try std.testing.expect(driving_award.wm_pointer_hook != null);
    try std.testing.expect(driving_award.wm_window_hook != null);
    // WMS5 Gate 2 (claim 4278): the keyboard fan-out hook goes live too.
    try std.testing.expect(driving_award.wm_key_hook != null);

    // Teardown unregisters the registrant; a non-owner exit is a no-op.
    try std.testing.expect(!unregister(4));
    try std.testing.expect(unregister(3));
    try std.testing.expect(!registered());
    try std.testing.expect(registered_pid() == null);

    // WMS5: input ownership and the fan-out hooks die with the WM (shim
    // fallback — the kernel resumes consuming pointer geometry exactly as
    // before; zero regression).
    try std.testing.expect(!driving_award.wm_owns_input);
    try std.testing.expect(driving_award.wm_pointer_hook == null);
    try std.testing.expect(driving_award.wm_window_hook == null);
    try std.testing.expect(driving_award.wm_key_hook == null);

    // The fallback report is drained exactly once after a teardown.
    try std.testing.expect(take_fallback_report());
    try std.testing.expect(!take_fallback_report());
    // ... and re-registering clears the pending flag (then tear down so the
    // aggregated test binary does not leak input ownership into later tests).
    try std.testing.expect(register(7));
    try std.testing.expect(!take_fallback_report());
    try std.testing.expect(unregister(7));
    try std.testing.expect(!driving_award.wm_owns_input);
}

test "wm_server: WMS5 raw-pointer and window-mirror fan-out is WM-only (kind 19/20 routing)" {
    events.init();
    init();
    events.on_event_pushed = null;

    // No WM: fan-outs are no-ops (nothing is generated, nothing changes).
    fan_pointer(100, 200, 0x01);
    fan_window(2, 10, 20, 30, 40, true, true, 0);
    fan_key(0x17, events.MOD_CTRL); // Gate 2: Ctrl+T usage
    try std.testing.expectEqual(@as(u64, 0), info().pointer_fan_count);
    try std.testing.expectEqual(@as(u64, 0), info().window_mirror_count);
    try std.testing.expectEqual(@as(u64, 0), info().key_fan_count);

    // Register pid 3: the fan-outs deliver kind 19/20/21 ONLY to the WM.
    try std.testing.expect(register(3));
    fan_pointer(100, 200, 0x01);
    fan_window(2, 10, 20, 30, 40, true, true, 0);
    fan_key(0x17, events.MOD_CTRL); // Gate 2: Ctrl+T usage
    try std.testing.expectEqual(@as(u64, 1), info().pointer_fan_count);
    try std.testing.expectEqual(@as(u64, 1), info().window_mirror_count);
    try std.testing.expectEqual(@as(u64, 1), info().key_fan_count);

    const p = events.pop(3).?;
    try std.testing.expectEqual(events.WM_POINTER, p.kind);
    try std.testing.expectEqual(@as(u16, 0x01), p.flags); // button byte
    try std.testing.expectEqual(@as(u32, 100 | (200 << 16)), p.arg0); // x|(y<<16)

    const w = events.pop(3).?;
    try std.testing.expectEqual(events.WM_WINDOW, w.kind);
    try std.testing.expectEqual(@as(u16, 2 | (1 << 8) | (1 << 9)), w.flags); // id | visible | focused
    try std.testing.expectEqual(@as(u32, 10 | (20 << 16)), w.arg0);
    try std.testing.expectEqual(@as(u32, 30 | (40 << 16)), w.arg1);

    // Gate 2 (claim 4278): kind 21 WM_KEY carries the raw usage + modifier
    // bits — the WM's chord decoder input.
    const k = events.pop(3).?;
    try std.testing.expectEqual(events.WM_KEY, k.kind);
    try std.testing.expectEqual(@as(u16, events.MOD_CTRL), k.flags);
    try std.testing.expectEqual(@as(u32, 0x17), k.arg0); // Ctrl+T usage

    // No other process's queue received anything (the kind-18 discipline).
    var i: usize = 0;
    while (i < process.max_processes) : (i += 1) {
        if (i != 3) try std.testing.expectEqual(@as(usize, 0), events.pending(i));
    }
    // Teardown: fan-outs stop again (and the flag is clean for later tests).
    try std.testing.expect(unregister(3));
    fan_pointer(100, 200, 0x01);
    fan_key(0x17, events.MOD_CTRL);
    try std.testing.expectEqual(@as(u64, 1), info().pointer_fan_count); // unchanged
    try std.testing.expectEqual(@as(u64, 1), info().key_fan_count); // unchanged
}

test "wm_server: SET_STATE counter + keyboard fan-out (claim 4278, WMS5 Gate 2)" {
    events.init();
    init();
    events.on_event_pushed = null;
    // The SET_STATE counter is monotonically incremented by the syscall
    // layer's handler; here we just pin the note contract (no WM needed).
    note_set_state();
    try std.testing.expectEqual(@as(u64, 1), info().set_state_count);
    init();
    try std.testing.expectEqual(@as(u64, 0), info().set_state_count);
    // Fan-out of a raw key with NO WM registered is a silent no-op (shim).
    fan_key(0x17, events.MOD_CTRL);
    try std.testing.expectEqual(@as(u64, 0), info().key_fan_count);
}

test "wm_server: COMPOSITE_TICK is delivered only to the registered WM with the present sequence" {
    events.init();
    init();
    events.on_event_pushed = null;

    // No WM registered: on_tick is a no-op, nothing is generated.
    on_tick();
    var i: usize = 0;
    while (i < process.max_processes) : (i += 1) {
        try std.testing.expectEqual(@as(usize, 0), events.pending(i));
    }

    // Register pid 3; the next tick delivers kind 18 with arg0 = present seq.
    try std.testing.expect(register(3));
    on_tick();
    on_tick();
    try std.testing.expectEqual(@as(usize, 2), events.pending(3));
    const ev = events.pop(3).?;
    try std.testing.expectEqual(events.COMPOSITE_TICK, ev.kind);
    try std.testing.expectEqual(@as(u32, present_seq), ev.arg0);
    try std.testing.expectEqual(@as(u32, 0), ev.arg1);

    // No other process's queue received a tick (the routing restriction).
    var j: usize = 0;
    while (j < process.max_processes) : (j += 1) {
        if (j != 3) try std.testing.expectEqual(@as(usize, 0), events.pending(j));
    }
    try std.testing.expectEqual(@as(u64, 2), info().tick_count);
    // Tear down so the aggregated test binary does not leak input ownership.
    try std.testing.expect(unregister(3));
    try std.testing.expect(!driving_award.wm_owns_input);
}

test "wm_server: REQUEST_PRESENT advances the present sequence and count" {
    init();
    try std.testing.expect(!request_present()); // no WM registered
    try std.testing.expect(register(3));
    try std.testing.expect(request_present());
    try std.testing.expect(request_present());
    const inf = info();
    try std.testing.expectEqual(@as(?usize, 3), inf.pid);
    try std.testing.expectEqual(@as(u32, 2), inf.present_seq);
    try std.testing.expectEqual(@as(u64, 2), inf.present_count);
    // Tear down so the aggregated test binary does not leak input ownership.
    try std.testing.expect(unregister(3));
    try std.testing.expect(!driving_award.wm_owns_input);
}
