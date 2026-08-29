//! DipshitOS M32 WMS3+WMS5 — WND.BIN, the long-lived EL0 window-manager SERVER
//! (issues #623/#625).
//!
//! WMS3 (issue #623): REGISTERs via `sys_wmctl` (slot 65, cmd 1) at startup,
//! then loops on `sys_wait_event` (slot 22), servicing the kernel's kind-18
//! `COMPOSITE_TICK` and issuing `REQUEST_PRESENT` (slot 65, cmd 3) at its OWN
//! cadence (every `present_every` ticks, not every tick). While it is
//! registered the shell idle drain is a no-op (WMS2), so THIS loop drives the
//! desktop's scanout presents.
//!
//! WMS5 (issue #625): the registered WM owns INPUT — the kernel fans the raw
//! pointer stream (kind 19 WM_POINTER), the window-registry mirrors (kind 20
//! WM_WINDOW), and — Gate 2 (claim 4278) — the raw keyboard stream (kind 21
//! WM_KEY) out to this process, and stops consuming geometry itself. This
//! server hit-tests and DECIDES geometry:
//!   * drag-to-move from kind 19 (title-bar grab -> SET_WINDOW rects);
//!   * snap-on-drop (a drag ending near a scanout edge issues the snapped rect);
//!   * tile / master-swap, minimize/restore, maximize/restore, workspace
//!     switch/cycle, fullscreen, always-on-top from kind 21 chords — all
//!     issued through SET_WINDOW (cmd 2) rects + SET_STATE (cmd 4) state, the
//!     frozen ADR 0007 encoding. The kernel clamps + blits whatever it gets.
//!
//! It NEVER exits — it occupies its scheduler slot + process row for the whole
//! session, like COUNTER.BIN/PEER.BIN. The loop is a draining server: each
//! wake (a `sys_wait_event` return) serves the WHOLE queued backlog, then the
//! next `sys_wait_event` parks it until the kernel pushes more — bounded work
//! per wake, and a blocked-in-wait rings around a hung one stalling the ring.
//! The kernel round-robins every tick regardless (the WMS2 exit fallback
//! covers the WM being killed; blocking-in-wait covers a hung one).
//!
//! The pure policy RULES it issues are compiled from the SAME source as the
//! kernel shim (`kernel/src/wnd_core.zig`, the drift guard) — the tile/snap/
//! maximize rect math and the chrome policy are one physical file, so the two
//! implementations cannot behaviorally drift while both are live.
//!
//! Written as a real Zig program (freestanding, no libc/POSIX) with inline
//! `svc` syscall wrappers — the payload grew past the WMS3-era naked-asm
//! pacing loop once policy landed (Gate 2). It imports mutable globals, so it
//! is built through the segmented DSK3 loader path (`linker-segmented.ld` +
//! `elf2bin.py --segments`) exactly like GLOBALS.BIN. The markers it writes
//! are pinned `pub const`s so host tests and the live gates' grep targets
//! cannot drift.

const std = @import("std");
// The drift guard: BOTH the kernel shim and this WM server compile the same
// pure rules from one file — the two implementations cannot behaviorally
// drift while both are live. Provided by build.zig as an anonymous import
// (the kernel compiles the same file from kernel/src/wnd_core.zig).
const wnd_core = @import("wnd_core");

// ---------------------------------------------------------------------------
// Syscall numbers (slots frozen in ADR 0007; the same numbers the naked
// payload used — no new syscalls).
// ---------------------------------------------------------------------------
const sys_write: u64 = 1;
const sys_yield_num: u64 = 2;
const sys_wait_event_num: u64 = 22;
const sys_wmctl: u64 = 65;

// Slot-65 subcommands (ADR 0007 — frozen by WMS1/claim 1484, extended by
// WMS4 (cmd 2 chrome) and WMS5 Gate 2 (cmd 4 SET_STATE)).
const wmctl_register: u64 = 1;
const wmctl_set_window: u64 = 2;
const wmctl_request_present: u64 = 3;
const wmctl_set_state: u64 = 4;

// ---------------------------------------------------------------------------
// Syscall wrappers (AArch64 `svc #0` — the fixed-register ABI).
// ---------------------------------------------------------------------------
fn syscall0(num: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
        : .{ .memory = true });
    return res;
}

fn syscall1(num: u64, arg0: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
        : .{ .memory = true });
    return res;
}

fn syscall3(num: u64, arg0: u64, arg1: u64, arg2: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
        : .{ .memory = true });
    return res;
}

fn syscall6(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
          [arg4] "{x4}" (arg4),
          [arg5] "{x5}" (arg5),
        : .{ .memory = true });
    return res;
}

/// Write a marker line to the serial console (fd 1) — the live gates' grep
/// targets. `msg` is a slice (in rodata/data).
fn write_marker(msg: []const u8) void {
    _ = syscall3(sys_write, 1, @intFromPtr(msg.ptr), msg.len);
}

/// The kernel event struct (same layout as events.Event — u16 kind, u16
/// flags, u32 seq, u32 arg0, u32 arg1; `sys_wait_event` fills it).
const Event = extern struct {
    kind: u16,
    flags: u16,
    seq: u32,
    arg0: u32,
    arg1: u32,
};

// ---------------------------------------------------------------------------
// Pinned markers + tuning (the live gates' grep targets — DO NOT change).
// ---------------------------------------------------------------------------

/// Written right after REGISTER returns 0 (proves the WM is live + seated).
pub const registered_marker: []const u8 = "wnd: registered\n";
/// Written every `marker_every` REQUEST_PRESENTs — the observable present
/// cadence (a marker per present would flood the serial over a long run).
pub const present_marker: []const u8 = "wnd: present\n";
/// Present every Nth COMPOSITE_TICK (its own cadence, not every tick).
/// Ticks are 1 Hz on VZ, so every 2 ticks = a present every 2 s.
pub const present_every: u32 = 2;
/// Write a present marker every Nth present. With cadence 2 s this bounds
/// serial volume to one line per present.
pub const marker_every: u32 = 1;
/// The kind-18 event the loop services (must match kernel events.COMPOSITE_TICK).
pub const composite_tick_kind: u64 = 18;

// WMS5 (issue #625): the event kinds the WM services — the raw pointer
// stream (19, WM_POINTER), the window-registry mirrors (20, WM_WINDOW), and
// the raw keyboard stream (21, WM_KEY, Gate 2). Pinned against kernel events
// (drift guard), like kind 18.
pub const wm_pointer_kind: u64 = 19;
pub const wm_window_kind: u64 = 20;
pub const wm_key_kind: u64 = 21;
/// Left-button bit inside the WM_POINTER `flags` byte (must match the HID
/// button byte the kernel fans out: 0x01 = left).
pub const btn_left: u8 = 0x01;
/// The title-bar drag markers — written on grab / move-while-held / drop.
/// The live gate greps these to prove the WM — not the kernel — moved the
/// window (the kernel's own geometry is gated off while a WM is registered).
pub const grab_marker: []const u8 = "wnd: grab\n";
pub const drag_marker: []const u8 = "wnd: drag\n";
pub const drop_marker: []const u8 = "wnd: drop\n";

// WMS5 Gate 2 (issue #625, claim 4278): the policy markers — one per
// geometry decision the WM issues over the seam. The live gate greps these
// to prove the WM — not the kernel — decided (the kernel's keyboard geometry
// consumers are gated off while a WM is registered).
pub const tile_marker: []const u8 = "wnd: tile\n";
pub const snap_marker: []const u8 = "wnd: snap\n";
pub const min_marker: []const u8 = "wnd: min\n";
pub const max_marker: []const u8 = "wnd: max\n";
pub const ws_marker: []const u8 = "wnd: ws\n";
pub const fs_marker: []const u8 = "wnd: fs\n";
pub const aot_marker: []const u8 = "wnd: aot\n";

// ADR 0009 modifier bits (must match kernel events MOD_*).
pub const mod_shift: u16 = 0x0001;
pub const mod_ctrl: u16 = 0x0002;
pub const mod_alt: u16 = 0x0004;

// HID keyboard usages for the chords the WM owns (must match the usages
// input.zig decodes: Ctrl+T tile, Ctrl+M master-swap, Ctrl+N minimize,
// Ctrl+Shift+M maximize, Ctrl+Shift+T always-on-top, Ctrl+F1-3 workspace
// switch, Alt+` workspace cycle, F11 fullscreen).
pub const usage_t: u8 = 0x17;
pub const usage_m: u8 = 0x10;
pub const usage_n: u8 = 0x11;
pub const usage_f1: u8 = 0x58;
pub const usage_f2: u8 = 0x59;
pub const usage_f3: u8 = 0x5a;
pub const usage_backtick: u8 = 0x35;
pub const usage_f11: u8 = 0x5c;

// WMS4 (issue #624): the EXACT values the chrome-descriptor blob embeds.
// Pinned against the shared wnd_core parity policy below, so the EL0 blob
// cannot drift from the kernel's expectation without a test failure.
pub const policy_kind: u32 = 0x3f;
pub const policy_flags: u32 = 0x01;
pub const policy_border_rgb: u32 = 0x0c1826;
pub const policy_border_unfocus_rgb: u32 = 0x475569;
pub const policy_title_bg_rgb: u32 = 0x1a2b3c;
pub const policy_title_fg_rgb: u32 = 0xffffff;
pub const policy_ring_rgb: u32 = 0x3b82f6;
pub const policy_close_rgb: u32 = 0xef4444;
pub const policy_min_rgb: u32 = 0x94a3b8;
pub const policy_pin_rgb: u32 = 0x38bdf8;

// ---------------------------------------------------------------------------
// The WM's own policy state (WMS5 Gate 2 — what the kernel used to own).
// ---------------------------------------------------------------------------

/// The one mirrored user window the WM tracks (the live gates open exactly
/// one window — NOTEPAD — so the WMS5 asm kept one slot; policy extends it
/// to the full user-window range 2..5 with a per-id table).
const max_user_windows: usize = 4;

const MirrorWin = struct {
    id: u8 = 0,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    visible: bool = false,
    focused: bool = false,
    workspace: u8 = 0,
    valid: bool = false,
    // Gate 2 policy state: the WM's own copies of what the kernel shim
    // tracked (tile slots, snap-restore rect, pre-max/pre-fs rects).
    minimized: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    always_on_top: bool = false,
    pre_max_x: u32 = 0,
    pre_max_y: u32 = 0,
    pre_max_w: u32 = 0,
    pre_max_h: u32 = 0,
    snap_last_x: u32 = 0,
    snap_last_y: u32 = 0,
    snap_last_w: u32 = 0,
    snap_last_h: u32 = 0,
    snapped: bool = false,
    snap_valid: bool = false,
};

/// The mirror table (id 2..5 -> slots 0..3).
var mirrors: [max_user_windows]MirrorWin = undefined;
var current_workspace: u8 = 0;
var tile_mode: bool = false;
var tile_master_id: u8 = 0xff;
var tile_stack_id: u8 = 0xff;
var tile_master_side: bool = true;

fn mirror_slot(id: u8) ?usize {
    if (id < 2 or id > 5) return null;
    return id - 2;
}

fn mirror(id: u8) ?*MirrorWin {
    const s = mirror_slot(id) orelse return null;
    return &mirrors[s];
}

fn focused_mirror() ?*MirrorWin {
    for (&mirrors) |*m| {
        if (m.valid and m.focused) return m;
    }
    return null;
}

/// The scanout dimensions the WM computes rects from (the fixed 1280x720
/// scanout; single-sourced in wnd_core so the WM and kernel agree).
const fb_w = wnd_core.fb_w;
const fb_h = wnd_core.fb_h;
const taskbar_h = wnd_core.taskbar_h;
const dock_w = wnd_core.dock_w;

// ---------------------------------------------------------------------------
// The policy actions (each issues SET_WINDOW rects / SET_STATE state).
// ---------------------------------------------------------------------------

/// SET_WINDOW(id, x|y<<16, w|h<<16) — propose a rect (kernel clamps + blits).
fn set_window_rect(id: u8, x: u32, y: u32, w: u32, h: u32) void {
    _ = syscall6(sys_wmctl, wmctl_set_window, id, x | (y << 16), w | (h << 16), 0, 0);
}

/// SET_STATE(id, state) — visibility (bits 0-1), workspace (bits 8-15),
/// always-on-top (bit 16). The ALL id = global workspace switch.
fn set_state(id: u8, visible: ?bool, ws: ?u8, aot: bool) void {
    var st: u64 = 2; // no visibility change (2/3)
    if (visible) |v| st = if (v) 1 else 0;
    if (ws) |w| st |= @as(u64, w) << 8;
    if (aot) st |= 1 << 16;
    _ = syscall6(sys_wmctl, wmctl_set_state, id, st, 0, 0, 0);
}

/// Switch the CURRENT workspace globally (SET_STATE with a0 = ALL).
fn switch_workspace(ws: u8) void {
    _ = syscall6(sys_wmctl, wmctl_set_state, 0xFFFF_FFFF, @as(u64, ws) << 8, 0, 0, 0);
}

/// M21 W1: toggle the focused window floating/tiled. Mirrors the kernel
/// shim's rule (max 2 tiled windows; a third shifts master -> stack).
fn toggle_tiling() void {
    const fm = focused_mirror() orelse return;
    const fid = fm.id;
    // Already master? detach (promote stack).
    if (tile_mode and tile_master_id == fid) {
        if (tile_stack_id != 0xff) {
            tile_master_id = tile_stack_id;
            tile_stack_id = 0xff;
        } else {
            tile_master_id = 0xff;
            tile_mode = false;
        }
    } else if (tile_mode and tile_stack_id == fid) {
        tile_stack_id = 0xff;
        if (tile_master_id == 0xff) tile_mode = false;
    } else {
        // Not yet tiled — add this window.
        if (tile_master_id == 0xff) {
            tile_master_id = fid;
        } else if (tile_stack_id == 0xff) {
            tile_stack_id = fid;
        } else {
            // Both slots occupied — detach the oldest (master) and shift.
            tile_master_id = tile_stack_id;
            tile_stack_id = fid;
        }
        tile_mode = true;
    }
    write_marker(tile_marker);
    apply_tile_layout();
}

/// M21 W2: swap which window is master and which is detail (flip the side).
fn swap_master() void {
    if (!tile_mode or tile_master_id == 0xff or tile_stack_id == 0xff) return;
    const mid = tile_master_id;
    tile_master_id = tile_stack_id;
    tile_stack_id = mid;
    tile_master_side = !tile_master_side;
    write_marker(tile_marker);
    apply_tile_layout();
}

/// Apply the tile layout through the shared wnd_core math (master 2/3,
/// detail 1/3 — the SAME rule the kernel shim's apply_tile_layout uses).
fn apply_tile_layout() void {
    if (!tile_mode) return;
    const tl = wnd_core.tile_layout(fb_w, fb_h, taskbar_h, dock_w, 667, tile_master_side);
    if (tile_master_id != 0xff) {
        if (mirror(tile_master_id)) |m| {
            m.x = tl.master_x;
            m.y = tl.y;
            m.w = tl.master_w;
            m.h = tl.h;
            set_window_rect(m.id, m.x, m.y, m.w, m.h);
        }
    }
    if (tile_stack_id != 0xff) {
        if (mirror(tile_stack_id)) |m| {
            m.x = tl.detail_x;
            m.y = tl.y;
            m.w = tl.detail_w;
            m.h = tl.h;
            set_window_rect(m.id, m.x, m.y, m.w, m.h);
        }
    }
}

/// M21 W3: minimize/restore the focused window (SET_STATE visibility).
fn toggle_minimize() void {
    const fm = focused_mirror() orelse return;
    if (fm.minimized) {
        fm.minimized = false;
        set_state(fm.id, true, null, false);
        // Restore the saved rect (the kernel kept it; we mirror the truth).
        if (fm.snap_valid) {
            set_window_rect(fm.id, fm.snap_last_x, fm.snap_last_y, fm.snap_last_w, fm.snap_last_h);
            fm.x = fm.snap_last_x;
            fm.y = fm.snap_last_y;
            fm.w = fm.snap_last_w;
            fm.h = fm.snap_last_h;
            fm.snap_valid = false;
        }
        write_marker(min_marker);
    } else {
        fm.minimized = true;
        // Save the current rect for restore (the WM's own pre-min copy).
        fm.snap_last_x = fm.x;
        fm.snap_last_y = fm.y;
        fm.snap_last_w = fm.w;
        fm.snap_last_h = fm.h;
        fm.snap_valid = true;
        set_state(fm.id, false, null, false);
        write_marker(min_marker);
    }
}

/// M21 W6: maximize/restore the focused window (SET_WINDOW max rect).
fn toggle_maximize() void {
    const fm = focused_mirror() orelse return;
    if (fm.maximized) {
        fm.maximized = false;
        if (fm.snap_valid) {
            set_window_rect(fm.id, fm.snap_last_x, fm.snap_last_y, fm.snap_last_w, fm.snap_last_h);
            fm.x = fm.snap_last_x;
            fm.y = fm.snap_last_y;
            fm.w = fm.snap_last_w;
            fm.h = fm.snap_last_h;
            fm.snap_valid = false;
        }
        write_marker(max_marker);
    } else {
        const mx = wnd_core.maximize_rect(fb_w, fb_h, taskbar_h, dock_w);
        fm.maximized = true;
        fm.snap_last_x = fm.x;
        fm.snap_last_y = fm.y;
        fm.snap_last_w = fm.w;
        fm.snap_last_h = fm.h;
        fm.snap_valid = true;
        fm.x = mx.x;
        fm.y = mx.y;
        fm.w = mx.w;
        fm.h = mx.h;
        set_window_rect(fm.id, mx.x, mx.y, mx.w, mx.h);
        write_marker(max_marker);
    }
}

/// M21 W7: fullscreen/restore the focused window (SET_WINDOW full rect).
fn toggle_fullscreen() void {
    const fm = focused_mirror() orelse return;
    if (fm.fullscreen) {
        fm.fullscreen = false;
        if (fm.snap_valid) {
            set_window_rect(fm.id, fm.snap_last_x, fm.snap_last_y, fm.snap_last_w, fm.snap_last_h);
            fm.x = fm.snap_last_x;
            fm.y = fm.snap_last_y;
            fm.w = fm.snap_last_w;
            fm.h = fm.snap_last_h;
            fm.snap_valid = false;
        }
        write_marker(fs_marker);
    } else {
        const fs = wnd_core.fullscreen_rect(fb_w, fb_h);
        fm.fullscreen = true;
        fm.snap_last_x = fm.x;
        fm.snap_last_y = fm.y;
        fm.snap_last_w = fm.w;
        fm.snap_last_h = fm.h;
        fm.snap_valid = true;
        fm.x = fs.x;
        fm.y = fs.y;
        fm.w = fs.w;
        fm.h = fs.h;
        set_window_rect(fm.id, fs.x, fs.y, fs.w, fs.h);
        write_marker(fs_marker);
    }
}

/// M21 W8: toggle always-on-top on the focused window (SET_STATE bit 16).
fn toggle_always_on_top() void {
    const fm = focused_mirror() orelse return;
    fm.always_on_top = !fm.always_on_top;
    set_state(fm.id, null, null, true);
    write_marker(aot_marker);
}

/// WMS5 Gate 2: snap the mirror window to the zone under the drop point
/// (M15 C3 rule from wnd_core — corners first, then edges; 20 px threshold).
fn snap_window_to(id: u8, px: u32, py: u32) void {
    const m = mirror(id) orelse return;
    const zone = wnd_core.snap_zone_for_point(px, py, fb_w, fb_h);
    if (zone == .none) return;
    const zb = wnd_core.snap_zone_bounds(zone, fb_w, fb_h, taskbar_h) orelse return;
    // The kernel clamps to user_buf_w/h; we propose the zone-centered rect.
    const win_w = @min(zb.w, wnd_core.user_buf_w);
    const win_h = @min(zb.h, wnd_core.user_buf_h);
    const win_x = zb.x + (zb.w - win_w) / 2;
    const win_y = zb.y + (zb.h - win_h) / 2;
    if (!m.snapped) {
        m.snap_last_x = m.x;
        m.snap_last_y = m.y;
        m.snap_last_w = m.w;
        m.snap_last_h = m.h;
        m.snap_valid = true;
    }
    m.snapped = true;
    m.x = win_x;
    m.y = win_y;
    m.w = win_w;
    m.h = win_h;
    set_window_rect(m.id, win_x, win_y, win_w, win_h);
    write_marker(snap_marker);
}

// ---------------------------------------------------------------------------
// The WMS5 keyboard chord decoder (kind 21 WM_KEY).
// ---------------------------------------------------------------------------
fn handle_wm_key(usage: u8, flags: u16) void {
    const ctrl = (flags & mod_ctrl) != 0;
    const shift = (flags & mod_shift) != 0;
    const alt = (flags & mod_alt) != 0;

    if (alt and usage == usage_backtick) {
        // Alt+` cycles workspaces (W4).
        current_workspace = (current_workspace + 1) % 3;
        switch_workspace(current_workspace);
        write_marker(ws_marker);
        return;
    }
    if (ctrl and !shift) {
        if (usage == usage_f1) {
            current_workspace = 0;
            switch_workspace(0);
            write_marker(ws_marker);
            return;
        }
        if (usage == usage_f2) {
            current_workspace = 1;
            switch_workspace(1);
            write_marker(ws_marker);
            return;
        }
        if (usage == usage_f3) {
            current_workspace = 2;
            switch_workspace(2);
            write_marker(ws_marker);
            return;
        }
        if (usage == usage_t) {
            toggle_tiling();
            return;
        }
        if (usage == usage_m) {
            swap_master();
            return;
        }
        if (usage == usage_n) {
            toggle_minimize();
            return;
        }
    }
    if (ctrl and shift) {
        if (usage == usage_m) {
            toggle_maximize();
            return;
        }
        if (usage == usage_t) {
            toggle_always_on_top();
            return;
        }
    }
    if (usage == usage_f11) {
        toggle_fullscreen();
        return;
    }
}

// ---------------------------------------------------------------------------
// The main loop (REGISTER -> chrome policy -> wait/serve events forever).
// ---------------------------------------------------------------------------

export fn _start() callconv(.c) noreturn {
    // The whole body is Zig below (freestanding, no libc) — the entry is a
    // plain function; the kernel enters at _start with a valid stack,
    // exactly like NOTEPAD.BIN. This program never returns.
    main();
}

fn main() noreturn {
    // WMS3: REGISTER (cmd 1). Only seated when the kernel compositor seam is
    // armed (the live gate boots with --screen); otherwise ENXIO parks here.
    if (syscall6(sys_wmctl, wmctl_register, 0, 0, 0, 0, 0) != 0) {
        while (true) {
            _ = syscall0(sys_yield_num); // fail-safe park
        }
    }
    write_marker(registered_marker);

    // WMS4 (issue #624): submit the chrome POLICY — one
    // sys_wmctl(SET_WINDOW, a0=ALL, a1=0, a2=0, ptr=desc, len=40). The WM
    // becomes the theme owner: the kernel blits chrome from this descriptor
    // (dark-theme values, byte-equal to the shim's own constants — parity by
    // value). Issued right after REGISTER, before any window exists, so every
    // window created later inherits it (the kernel's draw-time fallback).
    const desc = wnd_core.chrome_parity_policy();
    _ = syscall6(sys_wmctl, wmctl_set_window, 0xFFFF_FFFF, 0, 0, @intFromPtr(&desc), wnd_core.chrome_desc_bytes);

    // WMS5 mirror + drag + policy state.
    var ev: Event = undefined;
    var ticks: u64 = 0;
    var presents: u64 = 0;
    var grabbing: bool = false;
    var grab_dx: u32 = 0;
    var grab_dy: u32 = 0;
    var prev_btn: u8 = 0;

    while (true) {
        // BLOCK until at least one event is queued for this process. The
        // kernel delivers COMPOSITE_TICK (18), WM_POINTER (19), WM_WINDOW
        // (20), and WM_KEY (21) while we are registered. `handle_wait_event`
        // returns immediately while the queue is non-empty and only parks us
        // when it drains — so a single wake serves the WHOLE backlog, and
        // the bounded work per wake is "drain the queue", not "one event".
        const wait_rc = syscall1(sys_wait_event_num, @intFromPtr(&ev));
        if (wait_rc != 1) {
            // TEMP DEBUG: print the wait_event return code.
            var dbg: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&dbg, "wnd: wait_rc={d}\n", .{wait_rc}) catch "wnd: dbg-err\n";
            write_marker(s);
            _ = syscall0(sys_yield_num);
            continue;
        }
        switch (ev.kind) {
            composite_tick_kind => {
                ticks +%= 1;
                if (ticks % present_every == 0) {
                    _ = syscall6(sys_wmctl, wmctl_request_present, 0, 0, 0, 0, 0);
                    presents +%= 1;
                    if (presents % marker_every == 0) {
                        write_marker(present_marker);
                    }
                }
            },
            wm_window_kind => {
                // WM_WINDOW (kind 20) registry mirror: flags low byte = id,
                // bit 8 = visible, bit 9 = focused, bits 10-11 = workspace;
                // arg0 = x|(y<<16), arg1 = w|(h<<16).
                const id: u8 = @intCast(ev.flags & 0xff);
                const s = mirror_slot(id) orelse continue; // not a window we track
                const m = &mirrors[s];
                m.id = id;
                m.valid = true;
                m.x = ev.arg0 & 0xffff;
                m.y = ev.arg0 >> 16;
                m.w = ev.arg1 & 0xffff;
                m.h = ev.arg1 >> 16;
                m.visible = (ev.flags & (1 << 8)) != 0;
                m.focused = (ev.flags & (1 << 9)) != 0;
                m.workspace = @intCast((ev.flags >> 10) & 0x3);
            },
            wm_pointer_kind => {
                // WM_POINTER (kind 19): raw absolute pointer. arg0 =
                // px|(py<<16) (framebuffer pixels), flags low byte = HID
                // button byte (0x01 = left). The WM — not the kernel —
                // hit-tests and decides geometry.
                const px = ev.arg0 & 0xffff;
                const py = ev.arg0 >> 16;
                const btn: u8 = @intCast(ev.flags & 0xff);
                const left = (btn & btn_left) != 0;
                const prev_left = (prev_btn & btn_left) != 0;

                if (grabbing) {
                    if (left) {
                        // While held: MOVE via SET_WINDOW rect (the kernel
                        // clamps whatever we propose and mirrors the clamped
                        // truth back at us).
                        const fm = focused_mirror();
                        if (fm) |m| {
                            const nx = px -% grab_dx;
                            const ny = py -% grab_dy;
                            set_window_rect(m.id, nx, ny, m.w, m.h);
                            m.x = nx;
                            m.y = ny;
                            write_marker(drag_marker);
                        }
                    } else {
                        // Released: DROP. Snap if the drop point is near a
                        // scanout edge (M15 C3).
                        grabbing = false;
                        const fm = focused_mirror();
                        if (fm) |m| {
                            snap_window_to(m.id, px, py);
                        }
                        write_marker(drop_marker);
                    }
                } else {
                    // Not grabbing: a left-button DOWN EDGE starts a drag —
                    // but only when the pointer is inside the focused
                    // window's TITLE BAR (the wnd_core.title_bar_contains
                    // rule: [my, my+16), full width).
                    if (!prev_left and left) {
                        const fm = focused_mirror();
                        if (fm) |m| {
                            const g = wnd_core.Geom{
                                .id = m.id,
                                .kind = .user,
                                .x = m.x,
                                .y = m.y,
                                .w = m.w,
                                .h = m.h,
                                .visible = m.visible,
                                .workspace = m.workspace,
                            };
                            if (wnd_core.title_bar_contains(g, px, py)) {
                                grabbing = true;
                                grab_dx = px -% m.x;
                                grab_dy = py -% m.y;
                                write_marker(grab_marker);
                            }
                        }
                    }
                }
                prev_btn = btn;
            },
            wm_key_kind => {
                // WM_KEY (kind 21): raw keyboard — arg0 = HID usage, flags =
                // ADR 0009 modifier bits. The WM — not the kernel — decides
                // geometry from chords.
                handle_wm_key(@intCast(ev.arg0), ev.flags);
            },
            else => {},
        }
    }
}

test "wnd: module compiles and exports the EL0 entry (drift guard import)" {
    _ = @intFromPtr(&_start);
    // The WM binary is built against the SAME shared rules as the kernel shim.
    _ = wnd_core.hit_test;
    _ = wnd_core.clamp_resize_w;
}

test "wnd: the WMS4 chrome policy matches the shared parity values (drift guard)" {
    const p = wnd_core.chrome_parity_policy();
    try std.testing.expectEqual(policy_kind, p.kind);
    try std.testing.expectEqual(policy_flags, p.flags);
    try std.testing.expectEqual(policy_border_rgb, p.border_rgb);
    try std.testing.expectEqual(policy_border_unfocus_rgb, p.border_unfocus_rgb);
    try std.testing.expectEqual(policy_title_bg_rgb, p.title_bg_rgb);
    try std.testing.expectEqual(policy_title_fg_rgb, p.title_fg_rgb);
    try std.testing.expectEqual(policy_ring_rgb, p.ring_rgb);
    try std.testing.expectEqual(policy_close_rgb, p.close_rgb);
    try std.testing.expectEqual(policy_min_rgb, p.min_rgb);
    try std.testing.expectEqual(policy_pin_rgb, p.pin_rgb);
    // The descriptor itself validates under the kernel's single refusal rule.
    try std.testing.expect(wnd_core.chrome_valid(p));
}

test "wnd: the marker/tuning shapes are pinned (live-gate grep targets)" {
    try std.testing.expectEqualStrings("wnd: registered\n", registered_marker);
    try std.testing.expectEqual(@as(usize, 16), registered_marker.len);
    try std.testing.expectEqualStrings("wnd: present\n", present_marker);
    try std.testing.expectEqual(@as(usize, 13), present_marker.len);
    try std.testing.expectEqual(@as(u32, 2), present_every);
    try std.testing.expectEqual(@as(u32, 1), marker_every);
    try std.testing.expectEqual(@as(u64, 18), composite_tick_kind);
    // WMS5: the drag markers + kinds (the live gate greps these).
    try std.testing.expectEqualStrings("wnd: grab\n", grab_marker);
    try std.testing.expectEqual(@as(usize, 10), grab_marker.len);
    try std.testing.expectEqualStrings("wnd: drag\n", drag_marker);
    try std.testing.expectEqual(@as(usize, 10), drag_marker.len);
    try std.testing.expectEqualStrings("wnd: drop\n", drop_marker);
    try std.testing.expectEqual(@as(usize, 10), drop_marker.len);
    try std.testing.expectEqual(@as(u64, 19), wm_pointer_kind);
    try std.testing.expectEqual(@as(u64, 20), wm_window_kind);
    try std.testing.expectEqual(@as(u64, 21), wm_key_kind);
    try std.testing.expectEqual(@as(u8, 0x01), btn_left);
    // WMS5 Gate 2: the policy markers + chords are pinned too.
    try std.testing.expectEqualStrings("wnd: tile\n", tile_marker);
    try std.testing.expectEqualStrings("wnd: snap\n", snap_marker);
    try std.testing.expectEqualStrings("wnd: min\n", min_marker);
    try std.testing.expectEqualStrings("wnd: max\n", max_marker);
    try std.testing.expectEqualStrings("wnd: ws\n", ws_marker);
    try std.testing.expectEqualStrings("wnd: fs\n", fs_marker);
    try std.testing.expectEqualStrings("wnd: aot\n", aot_marker);
    try std.testing.expectEqual(@as(u8, 0x17), usage_t);
    try std.testing.expectEqual(@as(u8, 0x10), usage_m);
    try std.testing.expectEqual(@as(u8, 0x11), usage_n);
}

test "wnd: the WMS5 drag-grab rule matches the shared title-bar rule (drift guard)" {
    const g = wnd_core.Geom{ .id = 2, .kind = .user, .x = 100, .y = 100, .w = 400, .h = 300, .visible = true, .workspace = 0 };
    try std.testing.expect(wnd_core.title_bar_contains(g, 100, 100)); // top-left
    try std.testing.expect(wnd_core.title_bar_contains(g, 300, 115)); // mid band
    try std.testing.expect(!wnd_core.title_bar_contains(g, 300, 116)); // one below the band
    try std.testing.expect(!wnd_core.title_bar_contains(g, 300, 200)); // client area
    try std.testing.expectEqual(@as(usize, 16), wnd_core.title_bar_h);
    // The kernel re-exports the SAME number (no second constant to drift).
    _ = wnd_core.hit_test;
}

test "wnd: the WMS5 Gate 2 policy issues the SAME rects as the kernel shim (drift guard)" {
    // The WM's tile layout must match the kernel's apply_tile_layout numbers
    // (master 2/3 left, detail 1/3 right on a 1280x720 scanout with the
    // 20 px taskbar + 24 px dock).
    const tl = wnd_core.tile_layout(fb_w, fb_h, taskbar_h, dock_w, 667, true);
    try std.testing.expectEqual(@as(u32, 1256), tl.master_w + tl.detail_w);
    try std.testing.expectEqual(@as(u32, 837), tl.master_w);
    try std.testing.expectEqual(@as(u32, 419), tl.detail_w);
    try std.testing.expectEqual(@as(u32, 24), tl.master_x);
    try std.testing.expectEqual(@as(u32, 24 + 837), tl.detail_x);
    try std.testing.expectEqual(@as(u32, 700), tl.h); // 720 - 20 taskbar
    // Maximize = the workspace area (dock + taskbar excluded).
    const mx = wnd_core.maximize_rect(fb_w, fb_h, taskbar_h, dock_w);
    try std.testing.expectEqual(@as(u32, 24), mx.x);
    try std.testing.expectEqual(@as(u32, 0), mx.y);
    try std.testing.expectEqual(@as(u32, 1256), mx.w);
    try std.testing.expectEqual(@as(u32, 700), mx.h);
    // Snap bounds (M15 C3) — left half, taskbar excluded.
    const lb = wnd_core.snap_zone_bounds(.left, fb_w, fb_h, taskbar_h).?;
    try std.testing.expectEqual(@as(u32, 640), lb.w);
    try std.testing.expectEqual(@as(u32, 700), lb.h);
    // The WM's mirrored constants are the SAME numbers (no drift).
    try std.testing.expectEqual(wnd_core.fb_w, fb_w);
    try std.testing.expectEqual(wnd_core.taskbar_h, taskbar_h);
    try std.testing.expectEqual(wnd_core.dock_w, dock_w);
}
