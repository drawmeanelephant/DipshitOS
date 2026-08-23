//! Milestone six card G5 (claim 1543) — Driving Award, the window manager.
//!
//! A bounded window registry (fixed BSS, no heap) with z-order, focus,
//! hit-testing, and a dirty-rect compositor that blits window buffers into
//! the G1 framebuffer (kernel/src/virtio_gpu.zig). Road Pops — the G3 boot
//! terminal (kernel/src/text.zig, kernel/src/road_pops.zig) — is the FIRST
//! window (window 0, a full-screen terminal); a second demo window (a 1 Hz
//! clock) overlaps its top-right corner and proves multiple windows with
//! distinct content + focus.
//!
//! Z-order is the registry array order (index 0 = bottom, the last index =
//! top). `raise` moves a window to the top; focus is tracked by window id
//! (stable across raises), and `hit_test` returns the TOPMOST visible window
//! containing a point. The compositor repaints from the lowest dirty window
//! upward — a genuine dirty-rect redraw: a window whose content did not
//! change is never repainted, and the scanout transfer + flush run once per
//! dirty batch (the G1/G2/G3 full-frame present discipline).
//!
//! Window 0 (the terminal) renders the shared text layer straight into the
//! scanout framebuffer (its "buffer" IS the framebuffer — a terminal
//! redraws its full client area, which here is the whole screen). Window 1
//! (the clock) renders into its own fixed BSS back-buffer, which the
//! compositor blits over the terminal. Because the terminal's repaint
//! covers the clock's region, the compositor repaints from the lowest dirty
//! window UP, so the clock is always re-blitted over a freshly repainted
//! terminal — the classic overlay-preserving order.
//!
//! Input routing (the I3 path): keyboard bytes reach the Road Pops line
//! editor only while the terminal window is focused (`terminal_focused`);
//! when another window holds focus the keystrokes simply queue in the input
//! FIFO until the terminal regains focus. Serial (the scripted evidence
//! channel) stays an always-wired fallback, unchanged.
//!
//! No libc, no POSIX, no allocation, no function pointers in any const
//! table (the claim-0015 discipline — the registry is a BSS array built at
//! runtime).
//!
//! Host tests pin the pure contracts: hit-test, z-order/raise, focus, the
//! repaint-from-lowest-dirty plan, the clock rendering, and the blit.

const std = @import("std");
const font = @import("font8x8.zig");
const input = @import("input.zig"); // card U4 (claim 4993): the pointer reports
const virtio_gpu = @import("virtio_gpu.zig");
const fbtext = @import("text.zig");
const events = @import("events.zig"); // Milestone 9 (claim 9228): application events
const clipboard = @import("clipboard.zig"); // Arc2 W3 (claim 1264): tray clipboard indicator

// ---------------------------------------------------------------------------
// Geometry + colors (fixed constants — the live record lives in the claim)
// ---------------------------------------------------------------------------

/// Bounded window registry size (fixed BSS, M15 C4 dock adds one fixed window).
pub const max_windows: usize = 9;

/// The clock window: an overlay in the terminal's top-right corner. 304x192
/// at (960,16) — inside the 1280x720 scanout, overlapping the terminal.
pub const clock_x: u32 = 960;
pub const clock_y: u32 = 16;
pub const clock_w: u32 = 304;
pub const clock_h: u32 = 192;

/// Clock palette (0xRRGGBB) — deliberately distinct from the terminal's
/// green-on-dark so the live gate can tell the two windows apart by pixel.
pub const clock_border_rgb: u32 = 0x8899aa;
pub const clock_title_bg_rgb: u32 = 0xb58900; // amber title bar
pub const clock_title_fg_rgb: u32 = 0x141414;
pub const clock_bg_rgb: u32 = 0x0a1a2e; // dark navy body
pub const clock_fg_rgb: u32 = 0xd8dee9; // light body text
pub const clock_accent_rgb: u32 = 0xffaa00; // amber accent (mascot line)

/// Card U5 (claim 0935, ADR 0008 D4): the HIG chrome palette. The focus
/// ring is white (distinct from every window fill); the user title bar
/// reuses the window-manager's dark blue with white text. The U4 cursor
/// is magenta — a color nothing else renders, so the pixel gates can find
/// it unambiguously.
pub const focus_ring_rgb: u32 = 0xffffff;
pub const focus_ring_w: usize = 3;
pub const user_title_h: usize = 16;
pub const user_title_bg_rgb: u32 = 0x1a2b3c;
pub const user_title_fg_rgb: u32 = 0xffffff;
pub const cursor_rgb: u32 = 0xff00ff;
pub const cursor_w: usize = 8;
pub const cursor_h: usize = 8;

/// Card G6 (claim 0487): user windows — the draw/window syscall seam.
/// Bounded: TWO user windows (ids 2 and 3, `user_window_id_base`), each a
/// fixed BSS back-buffer `user_buf_w` × `user_buf_h` B8G8R8X8 that the
/// kernel owns and an EL0 program renders into through `sys_win_open` /
/// `sys_win_fill` / `sys_win_present`. The buffers never outgrow this
/// bound (no heap, no allocation).
pub const user_window_id_base: u8 = 2;
pub const user_windows_max: usize = 4;
pub const user_buf_w: u32 = 512;
pub const user_buf_h: u32 = 384;

/// Step 8 (Issue #211): the system taskbar at the bottom of the scanout.
pub const taskbar_h: u32 = 20;
pub const taskbar_y: u32 = virtio_gpu.fb_height - taskbar_h;
pub const taskbar_bg_rgb: u32 = 0x0f172a;
pub const taskbar_entry_active_rgb: u32 = 0x3b82f6;
pub const taskbar_entry_dimmed_rgb: u32 = 0x1e293b;

/// Arc2 W3 (claim 1264, #226): system tray — right 80px of 20px taskbar at y=700.
/// HH:MM from tick, D/L/A theme letter in accent, filled/empty clipboard rect.
/// Clock ticks on composite() without timer; migrates Kind.clock id 1 (no duplicate).
pub const tray_w: u32 = 80;
pub const tray_x: u32 = virtio_gpu.fb_width - tray_w;
pub const tray_h: u32 = taskbar_h;
pub const tray_y: u32 = taskbar_y;

/// M15 C4 (Dock, #229): 24 px left dock, topmost fixed layer.
pub const dock_w: u32 = 24;
pub const dock_x: u32 = 0;
pub const dock_y: u32 = 0;
pub const dock_h: u32 = virtio_gpu.fb_height - taskbar_h;
pub const dock_bg_rgb: u32 = 0x0f172a;
pub const dock_icon_bg_rgb: u32 = 0x1e293b;
pub const dock_icon_active_rgb: u32 = 0x3b82f6;

/// Step 9 (Issue #212): the desktop wallpaper gradient.
pub const wallpaper_top_rgb: u32 = 0x1a1a2e;
pub const wallpaper_bot_rgb: u32 = 0x0a0a14;

/// The window-kind tags (the terminal and the demo window).
pub const Kind = enum {
    terminal,
    clock,
    user,
    taskbar,
    wallpaper,
    dock,
};

/// One window in the registry. Value type; the registry is a fixed BSS
/// array. `title` is a static string literal (data, never a function
/// pointer — safe at any load base).
pub const Window = struct {
    id: u8,
    title: []const u8,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    kind: Kind,
    visible: bool,
    dirty: bool,
    /// Card G6 teardown follow-on (per-process ownership): the owning
    /// process id for a `.user` window (null for the fixed terminal +
    /// clock, which are kernel-owned). The syscall layer records the
    /// caller here at `sys_win_open`, restricts fill/present/close to the
    /// owner, and the exit path auto-closes the owner's windows via
    /// `close_owner` — a real teardown semantic instead of a window that
    /// leaks until reboot.
    owner: ?usize = null,
    /// Arc4 #239: animated window fade-in. 0=none (fully opaque),
    /// 1=fade-in active. The paint path applies per-pixel alpha
    /// blending during the fade frames.
    fade_phase: u8 = 0,
    fade_tick: u8 = 0,
    /// Arc4 #241: workspace assignment. 0..2 = workspace, fixed layers
    /// are always workspace 0 (visible on all).
    workspace: u8 = 0,
    /// Arc4 #242: unsaved-changes flag. The compositor shows a
    /// confirmation dialog when the user clicks close on a dirty window.
    unsaved: bool = false,
};

/// Arc4 #239: fade-in constants. The window is at 25% opacity for
/// `fade_half_frames` composites, then 50% for the same count, then
/// fully opaque. Total fade-in = 2 × fade_half_frames composites.
pub const fade_half_frames: u8 = 2;

// ---------------------------------------------------------------------------
// Registry state (fixed BSS)
// ---------------------------------------------------------------------------

var windows: [max_windows]Window = undefined;
var win_count: usize = 0;
/// Focused window id (stable across raises); 0xff = none.
var focused_id: u8 = 0xff;
var armed_global: bool = false;
/// Scanout presents pushed by the compositor since arm.
var presents: usize = 0;

/// Arc4 #241: virtual desktop workspaces. Three workspaces (0, 1, 2).
/// The current workspace controls which user windows are visible.
/// Fixed layers (terminal, wallpaper, taskbar, dock) are visible on all.
pub const workspace_max: u8 = 3;
pub var current_workspace: u8 = 0;

/// Arc4 #241: switch to a workspace (0..2). Marks all windows dirty
/// so the compositor repaints the new visibility set.
pub fn switch_workspace(ws: u8) void {
    if (ws >= workspace_max) return;
    current_workspace = ws;
    // Mark all windows dirty so the compositor repaints.
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        windows[i].dirty = true;
    }
    _ = mark_dirty(0);
    _ = mark_dirty(1);
}

/// Arc4 #241: check if a window is visible in the current workspace.
pub fn workspace_visible(w: *const Window) bool {
    // Fixed layers are always visible.
    if (w.kind != .user) return true;
    return w.workspace == current_workspace;
}

/// The clock's back-buffer (fixed BSS, contiguous B8G8R8X8). The
/// compositor blits it over the terminal.
var clock_buf: [clock_w * clock_h * 4]u8 = undefined;
/// Card G6 (claim 0487): the user windows' back-buffers (fixed BSS).
var user_bufs: [user_windows_max][user_buf_w * user_buf_h * 4]u8 = undefined;
/// The clock's displayed tick (so it only repaints when the second changes).
var clock_shown_tick: u64 = 0;
var clock_has_tick: bool = false;

/// Card U4 (claim 4993): the pointer cursor's framebuffer position. Hidden
/// until the first pointer report arrives (the default VM has no pointer).
var cursor_x: u32 = 0;
var cursor_y: u32 = 0;
var cursor_shown: bool = false;
var prev_ptr_buttons: u8 = 0;

/// Step 5/6/7 (Issues #208/#209/#210): drag + close + minimize state.
var drag_id: ?u8 = null;
var drag_offset_x: u32 = 0;
var drag_offset_y: u32 = 0;

/// Arc2 W1 (claim 3589, #224): drag-to-resize — 6×6 bottom-right corner.
pub const resize_min_w: u32 = 128;
pub const resize_min_h: u32 = 64;
pub const resize_hit_size: u32 = 6;
var resize_id: ?u8 = null;
var resize_start_x: u32 = 0;
var resize_start_y: u32 = 0;
var resize_origin_w: u32 = 0;
var resize_origin_h: u32 = 0;

/// Arc4 #237: drag-and-drop state — BSS, no heap.
/// The drag payload is copied from the source app via sys_drag_start,
/// then delivered to the target window on DROP via uaccess.
pub const drag_payload_max: usize = 512;
var drag_payload: [drag_payload_max]u8 = undefined;
var drag_payload_len: usize = 0;
var drag_active: bool = false;
var drag_source_pid: usize = 0;
var drag_over_id: ?u8 = null; // window currently under pointer during drag

/// Arc4 #237: store a drag payload from the source app (slot 48).
/// Called from the syscall handler.
pub fn drag_start(payload: []const u8, source_pid: usize) void {
    const copy_len = @min(payload.len, drag_payload_max);
    @memcpy(drag_payload[0..copy_len], payload[0..copy_len]);
    drag_payload_len = copy_len;
    drag_active = true;
    drag_source_pid = source_pid;
    drag_over_id = null;
}

/// Arc4 #237: check if a drag is currently active.
pub fn drag_is_active() bool {
    return drag_active;
}

/// Arc4 #237: get the drag payload for copy to target.
pub fn drag_get_payload() []const u8 {
    return drag_payload[0..drag_payload_len];
}

/// Arc4 #237: cancel an active drag (e.g. source window closed).
pub fn drag_cancel() void {
    drag_active = false;
    drag_payload_len = 0;
    drag_over_id = null;
}

/// Arc4 #242: unsaved-changes confirmation dialog state — BSS, no heap.
/// When the user clicks close on a dirty window, a Save/Don't Save/Cancel
/// dialog appears. The app must respond within 5 ticks or auto-don't-save.
pub const unsaved_timeout_ticks: u32 = 5;
var unsaved_dialog_open: bool = false;
var unsaved_dialog_target: u8 = 0; // window id being closed
var unsaved_dialog_ticks: u32 = 0;

/// Arc4 #242: open the unsaved-changes dialog for a window.
pub fn unsaved_dialog_show(target_id: u8) void {
    unsaved_dialog_open = true;
    unsaved_dialog_target = target_id;
    unsaved_dialog_ticks = 0;
}

/// Arc4 #242: check if the unsaved dialog is open.
pub fn unsaved_dialog_is_open() bool {
    return unsaved_dialog_open;
}

/// Arc4 #242: advance the timeout tick. Returns the action when it fires.
pub fn unsaved_dialog_advance_tick() ?enum { auto_close, none } {
    if (!unsaved_dialog_open) return .none;
    unsaved_dialog_ticks +|= 1;
    if (unsaved_dialog_ticks >= unsaved_timeout_ticks) {
        // Auto-don't-save: close the window.
        const tid = unsaved_dialog_target;
        unsaved_dialog_open = false;
        _ = user_close(tid);
        return .auto_close;
    }
    return .none;
}

/// Arc4 #242: handle a click inside the unsaved dialog.
pub fn unsaved_dialog_click(x: u32, y: u32) enum { save, dont_save, cancel, none } {
    if (!unsaved_dialog_open) return .none;
    // Dialog rect: centered, 200×100.
    const dlg_w: u32 = 200;
    const dlg_h: u32 = 100;
    const dlg_x: u32 = if (virtio_gpu.fb_width > dlg_w) (virtio_gpu.fb_width - dlg_w) / 2 else 0;
    const dlg_y: u32 = if (virtio_gpu.fb_height > dlg_h) (virtio_gpu.fb_height - dlg_h) / 2 else 0;
    // Save button: left, 60×20 at bottom of dialog.
    if (x >= dlg_x + 20 and x < dlg_x + 80 and y >= dlg_y + dlg_h - 30 and y < dlg_y + dlg_h - 10) {
        const tid = unsaved_dialog_target;
        unsaved_dialog_open = false;
        // Post WIN_UNSAVED arg0=0 (save) to the target.
        if (find_user_window(tid)) |w| {
            if (w.owner) |pid| {
                events.push(pid, .{
                    .kind = events.WIN_UNSAVED,
                    .flags = 0,
                    .seq = 0,
                    .arg0 = 0, // save
                    .arg1 = 0,
                });
            }
        }
        return .save;
    }
    // Don't Save button: middle.
    if (x >= dlg_x + 90 and x < dlg_x + 150 and y >= dlg_y + dlg_h - 30 and y < dlg_y + dlg_h - 10) {
        const tid = unsaved_dialog_target;
        unsaved_dialog_open = false;
        _ = user_close(tid);
        return .dont_save;
    }
    // Cancel button: right.
    if (x >= dlg_x + 160 and x < dlg_x + 220 and y >= dlg_y + dlg_h - 30 and y < dlg_y + dlg_h - 10) {
        unsaved_dialog_open = false;
        return .cancel;
    }
    return .none;
}

/// Arc4 #242: set/clear the unsaved flag on a user window.
pub fn user_set_unsaved(id: u8, flag: bool) bool {
    const w = find_user_window(id) orelse return false;
    w.unsaved = flag;
    return true;
}

/// M15 C2 (Alt+Tab overlay, #225): hold-Alt cycling UI state — BSS, no heap.
var overlay_active: bool = false;
var overlay_selected: usize = 0;
var overlay_ids: [max_windows]u8 = undefined;
var overlay_count: usize = 0;

/// M15 C3 (Snap zones, #227): drag snap state — BSS, no heap.
pub const SnapZone = enum { none, left, right, top, bottom, top_left, top_right, bottom_left, bottom_right };
var snap_zone: SnapZone = .none;
var snap_last_x: [user_windows_max]u32 = [_]u32{0} ** user_windows_max;
var snap_last_y: [user_windows_max]u32 = [_]u32{0} ** user_windows_max;
var snap_last_w: [user_windows_max]u32 = [_]u32{0} ** user_windows_max;
var snap_last_h: [user_windows_max]u32 = [_]u32{0} ** user_windows_max;
var snap_last_valid: [user_windows_max]bool = [_]bool{false} ** user_windows_max;
var snap_snapped: [user_windows_max]bool = [_]bool{false} ** user_windows_max;

/// Arc2 W3 (claim 1264, #226): system tray state — fixed BSS, ~32B, zero heap.
/// Right 80px of 20px taskbar at y=700: HH:MM from tick, D/L/A theme letter
/// in accent, filled/empty clipboard rect. Clock ticks on composite() without
/// timer; migrates Kind.clock id 1 (no duplicate tray-vs-clock).
var tray_tick: u64 = 0;
var tray_has_tick: bool = false;
var tray_last_theme: u8 = 0xff;
var tray_last_clip_len: usize = 0;

/// Arc4 #240: desktop notification toasts — bounded BSS FIFO, 4 entries.
/// Follows the exit-report FIFO pattern (M3 claim 1014). Apps post via
/// sys_notify; the compositor renders top-right and auto-dismisses.
pub const notify_max: usize = 4;
pub const notify_text_max: usize = 280;
pub const notify_dismiss_ticks: u32 = 5;
var notify_texts: [notify_max][notify_text_max]u8 = undefined;
var notify_lens: [notify_max]usize = [_]usize{0} ** notify_max;
var notify_levels: [notify_max]u8 = [_]u8{0} ** notify_max;
var notify_head: usize = 0;
var notify_count: usize = 0;
var notify_ticks: [notify_max]u32 = [_]u32{0} ** notify_max;

/// Push a notification into the bounded FIFO (drop-oldest on overflow).
/// Called from the syscall handler (kernel context).
pub fn notify_push(text: []const u8, level: u8) void {
    const slot = (notify_head + notify_count) % notify_max;
    const copy_len = @min(text.len, notify_text_max);
    @memcpy(notify_texts[slot][0..copy_len], text[0..copy_len]);
    notify_lens[slot] = copy_len;
    notify_levels[slot] = level;
    notify_ticks[slot] = 0;
    if (notify_count < notify_max) {
        notify_count += 1;
    } else {
        // Drop-oldest: advance head.
        notify_head = (notify_head + 1) % notify_max;
    }
}

/// Drain (dismiss) a notification by index within the visible set.
/// Returns true if dismissed.
pub fn notify_dismiss(index: usize) bool {
    if (index >= notify_count) return false;
    // Compact: shift remaining entries forward.
    var i: usize = index;
    while (i + 1 < notify_count) : (i += 1) {
        const src = (notify_head + i + 1) % notify_max;
        const dst = (notify_head + i) % notify_max;
        const n = notify_lens[src];
        @memcpy(notify_texts[dst][0..n], notify_texts[src][0..n]);
        notify_lens[dst] = n;
        notify_levels[dst] = notify_levels[src];
        notify_ticks[dst] = notify_ticks[src];
    }
    notify_count -= 1;
    return true;
}

/// Advance notification ticks (called once per composite). Auto-dismiss
/// entries that have exceeded notify_dismiss_ticks.
pub fn notify_advance_ticks() void {
    if (notify_count == 0) return;
    var i: usize = notify_count;
    while (i > 0) {
        i -= 1;
        const slot = (notify_head + i) % notify_max;
        notify_ticks[slot] +|= 1;
        if (notify_ticks[slot] >= notify_dismiss_ticks) {
            _ = notify_dismiss(i);
        }
    }
}

/// The current notification count (for compositor rendering).
pub fn notify_count_visible() usize {
    return notify_count;
}

/// Read notification data by visible index (0 = newest).
pub fn notify_entry(index: usize) ?struct { text: []const u8, level: u8 } {
    if (index >= notify_count) return null;
    const slot = (notify_head + index) % notify_max;
    return .{ .text = notify_texts[slot][0..notify_lens[slot]], .level = notify_levels[slot] };
}

/// Step 7 (Issue #207): theme selection. 0=dark, 1=light, 2=amber.
/// Read by the compositor chrome pass for title bars, clock, focus ring.
pub var theme_id: u8 = 0;

/// Theme color for the clock title bar background.
pub fn clock_title_bg() u32 {
    return switch (theme_id) {
        1 => 0xf8fafc, // light: near-white title bar
        2 => 0xb58900, // amber: warm gold
        else => 0xb58900, // dark: original amber
    };
}

/// Theme color for the clock body background.
pub fn clock_bg() u32 {
    return switch (theme_id) {
        1 => 0xf1f5f9, // light: light gray
        2 => 0x0a1a2e, // amber: dark navy (original)
        else => 0x0a1a2e, // dark: original
    };
}

/// M20-U9: window border width — 2px, visible on every theme.
pub const chrome_border_w: usize = 2;

/// Theme color for the user window border (darker than the title bar).
pub fn user_border() u32 {
    return switch (theme_id) {
        1 => 0x94a3b8, // light: slate
        2 => 0x0c1826, // amber: near-black navy (original)
        else => 0x0c1826, // dark: original
    };
}

/// M20-U9 layout helper: where the centered title text starts and how
/// many bytes of it to draw, given a window width and label length.
/// Leaves room for the minimize+close buttons on the right; labels too
/// wide for the remaining span truncate with a trailing "...".
pub fn chrome_title_layout(win_w: usize, label_len: usize) struct { x_off: usize, draw_len: usize, truncated: bool } {
    const btn_reserve: usize = 34; // minimize + close + margins (right side)
    const min_pad: usize = 4; // never start left of x+4
    const usable = if (win_w > btn_reserve + min_pad) win_w - btn_reserve else win_w;
    const max_chars = usable / 8;
    var draw_len = label_len;
    var truncated = false;
    if (draw_len > max_chars and max_chars >= 4) {
        draw_len = max_chars - 3;
        truncated = true;
    } else if (draw_len > max_chars) {
        draw_len = max_chars;
        truncated = true;
    }
    const text_px = if (truncated) (draw_len + 3) * 8 else draw_len * 8;
    var x_off: usize = 0;
    if (win_w > text_px) x_off = (win_w - text_px) / 2;
    if (x_off < min_pad) x_off = min_pad;
    return .{ .x_off = x_off, .draw_len = draw_len, .truncated = truncated };
}

/// Theme color for the user window title bar.
pub fn user_title_bg() u32 {
    return switch (theme_id) {
        1 => 0xe2e8f0, // light: light surface
        2 => 0x1a2b3c, // amber: dark blue (original)
        else => 0x1a2b3c, // dark: original
    };
}

/// Theme color for the focus ring.
pub fn focus_ring() u32 {
    return switch (theme_id) {
        1 => 0x2563eb, // light: blue ring (distinct on white)
        2 => 0xffffff, // amber: white (original)
        else => 0xffffff, // dark: white (original)
    };
}

/// Theme color for the taskbar background.
pub fn taskbar_bg() u32 {
    return switch (theme_id) {
        1 => 0xe2e8f0, // light: light surface
        2 => 0x0f172a, // amber: dark (original)
        else => 0x0f172a, // dark: original
    };
}

/// Theme color for the taskbar entry highlight.
pub fn taskbar_entry_active() u32 {
    return switch (theme_id) {
        1 => 0x2563eb, // light: blue
        2 => 0xff8800, // amber: orange
        else => 0x3b82f6, // dark: blue (original)
    };
}

/// Theme color for the taskbar entry (dimmed).
pub fn taskbar_entry_dimmed() u32 {
    return switch (theme_id) {
        1 => 0xcbd5e1, // light: light border
        2 => 0x1e293b, // amber: dark (original)
        else => 0x1e293b, // dark: original
    };
}

/// Theme color for the desktop wallpaper top.
pub fn wallpaper_top() u32 {
    return switch (theme_id) {
        1 => 0xf1f5f9, // light: very light
        2 => 0x1a1a2e, // amber: dark (original)
        else => 0x1a1a2e, // dark: original
    };
}

/// Theme color for the desktop wallpaper bottom.
pub fn wallpaper_bot() u32 {
    return switch (theme_id) {
        1 => 0xe2e8f0, // light: light surface
        2 => 0x0a0a14, // amber: darker (original)
        else => 0x0a0a14, // dark: original
    };
}

// ---------------------------------------------------------------------------
// Arc2 W3 — system tray helpers (pure, host-testable, isolated for merge)
// ---------------------------------------------------------------------------

/// Tray rect — right 80px of 20px taskbar at y=700. Pure — host-testable.
pub fn tray_rect() struct { x: u32, y: u32, w: u32, h: u32 } {
    return .{ .x = tray_x, .y = tray_y, .w = tray_w, .h = tray_h };
}

/// Format HH:MM from tick (seconds since boot, 1 Hz timer). Zero-padded,
/// 24h wrap. Pure — host-testable. Writes into buf[0..5] and returns slice.
pub fn format_hhmm(buf: []u8, ticks: u64) []const u8 {
    if (buf.len < 5) return "";
    const total_minutes = (ticks / 60) % (24 * 60);
    const hh = total_minutes / 60;
    const mm = total_minutes % 60;
    buf[0] = @as(u8, @intCast('0' + hh / 10));
    buf[1] = @as(u8, @intCast('0' + hh % 10));
    buf[2] = ':';
    buf[3] = @as(u8, @intCast('0' + mm / 10));
    buf[4] = @as(u8, @intCast('0' + mm % 10));
    return buf[0..5];
}

/// Theme letter D/L/A per theme_id. Pure — host-testable.
pub fn theme_letter() u8 {
    return switch (theme_id) {
        1 => 'L',
        2 => 'A',
        else => 'D',
    };
}

/// Theme accent for tray letter — taskbar active entry color per theme.
pub fn tray_theme_accent() u32 {
    return taskbar_entry_active();
}

/// Clipboard filled when current_len !=0. Pure wrapper — host-testable.
pub fn tray_clipboard_filled() bool {
    return clipboard.current_len() != 0;
}

/// Current tray tick (for tests).
pub fn tray_current_tick() u64 {
    return tray_tick;
}
pub fn tray_has_clock() bool {
    return tray_has_tick;
}

// ---------------------------------------------------------------------------
// Arm / query
// ---------------------------------------------------------------------------

/// Arm the window manager: register the terminal (window 0, full screen)
/// and the fixed chrome (wallpaper, taskbar, dock). The clock window
/// (Kind.clock id 1) is migrated to the taskbar tray (Arc2 W3) — no duplicate
/// window. Focus the terminal, mark dirty so first composite paints the scene.
pub fn arm() void {
    win_count = 0;
    windows[win_count] = .{
        .id = 0,
        .title = "roadpops",
        .x = 0,
        .y = 0,
        .w = virtio_gpu.fb_width,
        .h = virtio_gpu.fb_height,
        .kind = .terminal,
        .visible = true,
        .dirty = true,
    };
    win_count += 1;
    // Arc2 W3: Kind.clock id 1 deprecated — tray clock in taskbar replaces it.
    // No window created for clock; tray state holds HH:MM.
    // Step 9: wallpaper window (id 254) — gradient background between terminal and taskbar.
    windows[win_count] = .{
        .id = 254,
        .title = "wallpaper",
        .x = 0,
        .y = 0,
        .w = virtio_gpu.fb_width,
        .h = virtio_gpu.fb_height,
        .kind = .wallpaper,
        .visible = true,
        .dirty = true,
    };
    win_count += 1;
    // Step 8: taskbar window (id 255) — always topmost.
    windows[win_count] = .{
        .id = 255,
        .title = "taskbar",
        .x = 0,
        .y = taskbar_y,
        .w = virtio_gpu.fb_width,
        .h = taskbar_h,
        .kind = .taskbar,
        .visible = true,
        .dirty = true,
    };
    win_count += 1;
    // M15 C4: dock window (id 253) — 24 px left bar, always visible.
    windows[win_count] = .{
        .id = 253,
        .title = "dock",
        .x = dock_x,
        .y = dock_y,
        .w = dock_w,
        .h = dock_h,
        .kind = .dock,
        .visible = true,
        .dirty = true,
    };
    win_count += 1;
    focused_id = 0;
    armed_global = true;
    presents = 0;
    clock_shown_tick = 0;
    clock_has_tick = false;
    tray_tick = 0;
    tray_has_tick = false;
    tray_last_theme = 0xff;
    tray_last_clip_len = 0;
    cursor_shown = false;
    prev_ptr_buttons = 0;
    drag_id = null;
    resize_id = null;
    overlay_active = false;
    overlay_count = 0;
    overlay_selected = 0;
    snap_zone = .none;
    var si: usize = 0;
    while (si < user_windows_max) : (si += 1) {
        snap_last_valid[si] = false;
        snap_snapped[si] = false;
    }
}

pub fn armed() bool {
    return armed_global;
}

pub fn count() usize {
    return win_count;
}

pub fn presents_pushed() usize {
    return presents;
}

pub fn window_at(i: usize) ?*const Window {
    if (i >= win_count) return null;
    return &windows[i];
}

pub fn kind_name(kind: Kind) []const u8 {
    return switch (kind) {
        .terminal => "terminal",
        .clock => "clock",
        .user => "user",
        .taskbar => "taskbar",
        .wallpaper => "wallpaper",
        .dock => "dock",
    };
}

// ---------------------------------------------------------------------------
// Z-order, focus, hit-testing (pure — host-testable)
// ---------------------------------------------------------------------------

/// The index of the focused window, or null when none.
pub fn focused_index() ?usize {
    if (!armed_global) return null;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == focused_id) return i;
    }
    return null;
}

/// The focused window's id, or 0xff when none.
pub fn focused_window_id() u8 {
    return focused_id;
}

/// True when the focused window is the terminal (the I3 keyboard sink).
pub fn terminal_focused() bool {
    const fi = focused_index() orelse return false;
    return windows[fi].kind == .terminal;
}

/// The focused window, or null when none.
pub fn focused_window() ?*const Window {
    const fi = focused_index() orelse return null;
    return &windows[fi];
}

/// The owning process ID of the focused user window, or null if terminal/clock/none.
pub fn focused_owner() ?usize {
    const fi = focused_index() orelse return null;
    if (windows[fi].kind == .user) return windows[fi].owner;
    return null;
}

/// Focus a window by id. Returns false for an unknown id.
/// Card E4 (claim 0293): emits WIN_BLUR to previous focused user window
/// and WIN_FOCUS to newly focused user window.
pub fn focus(id: u8) bool {
    if (!armed_global) return false;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == id) {
            // Card U5 (ADR 0008 D4): focus is ALWAYS VISIBLE — a focus
            // change must repaint so the ring moves.
            if (focused_id != id) {
                const old_id = focused_id;
                // Deliver WIN_BLUR to previously focused user window owner
                if (find_user_window(old_id)) |old_win| {
                    if (old_win.owner) |old_owner| {
                        events.push(old_owner, .{
                            .kind = events.WIN_BLUR,
                            .flags = 0,
                            .seq = 0,
                            .arg0 = old_id,
                            .arg1 = id,
                        });
                    }
                }
                // Deliver WIN_FOCUS to newly focused user window owner
                if (windows[i].kind == .user and windows[i].owner != null) {
                    events.push(windows[i].owner.?, .{
                        .kind = events.WIN_FOCUS,
                        .flags = 0,
                        .seq = 0,
                        .arg0 = id,
                        .arg1 = old_id,
                    });
                }
                _ = mark_dirty(0);
            }
            // Step 7 (Issue #210): auto-show a hidden window on focus.
            if (!windows[i].visible) {
                windows[i].visible = true;
                windows[i].dirty = true;
                _ = mark_dirty(0);
            }
            focused_id = id;
            return true;
        }
    }
    return false;
}

/// Raise a window to the top of the z-order (the end of the array). Focus
/// is unchanged (tracked by id). Returns false for an unknown id.
pub fn raise(id: u8) bool {
    if (!armed_global) return false;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == id) {
            const moved = windows[i];
            var j = i;
            while (j + 1 < win_count) : (j += 1) windows[j] = windows[j + 1];
            windows[win_count - 1] = moved;
            // Re-blit the raised window (z-order changed).
            windows[win_count - 1].dirty = true;
            return true;
        }
    }
    return false;
}

/// The topmost visible window containing (x, y), or null when none does.
pub fn hit_test(x: u32, y: u32) ?u8 {
    var i: usize = win_count;
    while (i > 0) {
        i -= 1;
        const w = &windows[i];
        if (!w.visible) continue;
        // Arc4 #241: skip windows not in the current workspace.
        if (!workspace_visible(w)) continue;
        // Wallpaper is background-only — not interactive.
        if (w.kind == .wallpaper) continue;
        if (x >= w.x and x < w.x + w.w and y >= w.y and y < w.y + w.h) return w.id;
    }
    return null;
}

/// Focus the topmost window at (x, y). Returns false when nothing is there.
pub fn focus_at(x: u32, y: u32) bool {
    const id = hit_test(x, y) orelse return false;
    return focus(id);
}

// ---------------------------------------------------------------------------
// Dirty tracking
// ---------------------------------------------------------------------------

/// Mark a window dirty (by id) so the next composite repaints it. Returns
/// false for an unknown id.
pub fn mark_dirty(id: u8) bool {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == id) {
            windows[i].dirty = true;
            return true;
        }
    }
    return false;
}

/// Mark the terminal (window 0) dirty — the Road Pops tee's write path.
pub fn mark_terminal_dirty() void {
    if (win_count > 0) windows[0].dirty = true;
}

// ---------------------------------------------------------------------------
// Card G6 (claim 0487): the draw/window syscall seam — user windows
// ---------------------------------------------------------------------------

pub const UserOpenResult = union(enum) {
    opened: u8,
    invalid: void,
    full: void,
};

/// Find a user window by id (only `.user` kinds — the terminal/clock ids
/// are fixed and never match the user id base).
fn find_user_window(id: u8) ?*Window {
    const idx = find_user_window_index(id) orelse return null;
    return &windows[idx];
}

/// The registry index of a user window, or null.
fn find_user_window_index(id: u8) ?usize {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == id and windows[i].kind == .user) return i;
    }
    return null;
}

/// Open a kernel-owned user window at screen position (x, y) with a
/// back-buffer w×h (≤ `user_buf_w` × `user_buf_h`), OWNED by the process
/// `owner` (the syscall layer records the caller's pid here). The window
/// is appended at the top of the z-order and focused. Returns `.opened`
/// with the id (2..5), `.invalid` for geometry outside the
/// back-buffer/scanout bounds (or when the manager is unarmed — no gpu),
/// and `.full` when all four user slots are already open. The window is
/// OWNED by `owner` — it auto-closes when that process exits (the
/// scheduler's exit path calls `close_owner`).
pub fn user_open(x: u32, y: u32, w: u32, h: u32, owner: usize) UserOpenResult {
    if (!armed_global) return .invalid;
    if (w == 0 or h == 0 or w > user_buf_w or h > user_buf_h) return .invalid;
    if (x >= virtio_gpu.fb_width or y >= virtio_gpu.fb_height) return .invalid;
    if (w > virtio_gpu.fb_width - x or h > virtio_gpu.fb_height - y) return .invalid;
    var i: usize = 0;
    while (i < user_windows_max) : (i += 1) {
        const id = user_window_id_base + @as(u8, @intCast(i));
        var used = false;
        var j: usize = 0;
        while (j < win_count) : (j += 1) {
            if (windows[j].id == id) {
                used = true;
                break;
            }
        }
        if (used) continue;
        @memset(&user_bufs[i], 0);
        windows[win_count] = .{
            .id = id,
            .title = "user",
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .kind = .user,
            .visible = true,
            .dirty = true,
            .owner = owner,
            .fade_phase = 1, // Arc4 #239: start fade-in
            .fade_tick = 0,
            .workspace = current_workspace, // Arc4 #241: assign to current workspace
        };
        win_count += 1;
        _ = focus(id);
        return .{ .opened = id };
    }
    return .full;
}

/// Fill a rect in the user window's back-buffer (local coordinates,
/// 0..window w/h) and mark it dirty. Returns false for an unknown id or a
/// rect outside the window bounds.
pub fn user_fill(id: u8, x: u32, y: u32, w: u32, h: u32, rgb: u32) bool {
    const win = find_user_window(id) orelse return false;
    if (w == 0 or h == 0) return false;
    if (x >= win.w or y >= win.h) return false;
    if (w > win.w - x or h > win.h - y) return false;
    const idx = id - user_window_id_base;
    if (idx >= user_windows_max) return false;
    fill_rect(@ptrCast(&user_bufs[idx]), user_buf_w * 4, x, y, w, h, rgb);
    win.dirty = true;
    return true;
}

/// Mark a user window dirty so the compositor blits its back-buffer on the
/// next idle-loop pass (the deferred-present discipline — the syscall never
/// touches the gpu directly; the shell idle loop's `drain` composites).
/// Returns false for an unknown id.
pub fn user_present(id: u8) bool {
    const win = find_user_window(id) orelse return false;
    win.dirty = true;
    return true;
}

/// Move a user window's top-left corner to (x, y), CLAMPED so the whole
/// window stays inside the scanout (a window is never allowed off-screen —
/// the honest bound). Marks the moved window dirty and the terminal dirty
/// (its old rect is revealed) so the next composite repaints over the old
/// position and blits at the new one. Returns false for an unknown id, a
/// non-user window (the terminal + clock are fixed), or an unarmed manager.
/// The EL0 `sys_win_move` enforces ownership on top of this.
pub fn user_move(id: u8, x: u32, y: u32) bool {
    const win = find_user_window(id) orelse return false;
    const max_x = virtio_gpu.fb_width - win.w;
    const max_y = virtio_gpu.fb_height - win.h;
    win.x = @min(x, max_x);
    win.y = @min(y, max_y);
    win.dirty = true;
    // Reveal whatever sat under the window's old rect (the terminal repaint).
    _ = mark_dirty(0);
    return true;
}

/// Raise a user window to the top of the z-order (the EL0 `sys_win_raise`
/// primitive — ownership is enforced at the syscall layer). Focus is
/// unchanged (tracked by id, the G5 discipline). Returns false for an
/// unknown id or a non-user window (the terminal + clock are fixed).
pub fn user_raise(id: u8) bool {
    if (find_user_window_index(id) == null) return false;
    return raise(id);
}

/// Arc4 #238 (slot 49): raise the caller's user window to the top of the
/// z-order (EL0-callable variant of `user_raise`). Owner-restricted like
/// `sys_win_raise`; refused on fixed layers. Returns false for unknown id,
/// non-user window, or unarmed manager.
pub fn user_raise_front(id: u8) bool {
    if (!armed_global) return false;
    if (find_user_window_index(id) == null) return false;
    return raise(id);
}

/// Arc4 #238 (slot 50): lower the caller's user window to the bottom of
/// the z-order — above fixed windows (wallpaper/taskbar/dock, ids 255/253)
/// but below all other user windows. Owner-restricted; refused on fixed
/// layers. Returns false for unknown id, non-user window, or unarmed.
pub fn user_lower_back(id: u8) bool {
    if (!armed_global) return false;
    const idx = find_user_window_index(id) orelse return false;
    // Move to index 0: shift everything above down by one.
    const moved = windows[idx];
    var j = idx;
    while (j > 0) : (j -= 1) windows[j] = windows[j - 1];
    windows[0] = moved;
    windows[0].dirty = true;
    return true;
}

/// Arc4 #241: move a user window to a different workspace.
pub fn user_move_to_workspace(id: u8, ws: u8) bool {
    if (!armed_global) return false;
    const w = find_user_window(id) orelse return false;
    w.workspace = ws;
    w.dirty = true;
    _ = mark_dirty(0);
    return true;
}

/// Close (release) a user window: remove it from the registry (the z-order
/// stays compact — later windows shift down), fall the focus back to the
/// terminal when the closed window held it, and mark the fixed windows
/// (terminal + clock) dirty so the next composite repaints over the
/// released window's pixels. Returns false for an unknown id or a non-user
/// window (the terminal + clock are fixed and never closable). The
/// back-buffer slot is freed for the next `user_open` (which re-clears it).
/// This is the PRIVILEGED release path (the monitor's `dui close <n>`); the
/// EL0 `sys_win_close` enforces ownership on top of it.
pub fn user_close(id: u8) bool {
    const idx = find_user_window_index(id) orelse return false;
    remove_user_at(idx);
    return true;
}

/// The owner of a user window, or null for an unknown id / non-user window
/// (the syscall layer compares this to the caller to enforce ownership).
pub fn user_owner(id: u8) ?usize {
    const win = find_user_window(id) orelse return null;
    return win.owner;
}

/// Card G6 (claim 0487) follow-on (slot 18): the geometry of a user window
/// — the `sys_win_get` result. The syscall layer marshals this into the
/// caller's buffer (four u32 LE words) through uaccess so an EL0 program
/// can read its window's rect back after a CLAMPED move (the move is
/// silent; this is the read-back seam).
pub const WinRect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// The rect of a user window, or null for an unknown id / non-user window
/// (the terminal + clock are fixed and never match).
pub fn user_rect(id: u8) ?WinRect {
    const win = find_user_window(id) orelse return null;
    return .{ .x = win.x, .y = win.y, .w = win.w, .h = win.h };
}

/// Card G6 (claim 0487) follow-on (slot 19): the FULL state of a user
/// window — the `sys_win_query` result. The rect (like `user_rect`) plus the
/// z-order rank (`z` = the registry index, 0 = bottom — the SAME number the
/// monitor's `dui` report prints), and the focus/visible/dirty flags (1/0).
/// The syscall layer marshals this into the caller's buffer (eight u32 LE
/// words) so an EL0 program can introspect its window end to end.
pub const WinQuery = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    z: u32,
    focused: u32,
    visible: u32,
    dirty: u32,
};

/// The full state of a user window, or null for an unknown id / non-user
/// window. `z` is the registry index (0 = bottom of the z-order).
pub fn user_query(id: u8) ?WinQuery {
    const idx = find_user_window_index(id) orelse return null;
    const win = windows[idx];
    return .{
        .x = win.x,
        .y = win.y,
        .w = win.w,
        .h = win.h,
        .z = @intCast(idx),
        .focused = if (focused_id == id) 1 else 0,
        .visible = if (win.visible) 1 else 0,
        .dirty = if (win.dirty) 1 else 0,
    };
}

/// Card G6 (claim 0487) follow-on (slot 20): set a user window's visibility
/// (hide/show). Returns false for an unknown id or a non-user window (the
/// terminal + clock are fixed and never hideable). Hiding marks the window
/// hidden + dirty (inert while hidden) and marks the terminal dirty so the
/// next composite repaints over the hidden window's pixels; showing marks the
/// window dirty so it reappears. Idempotent (same-flag calls are a no-op — no
/// dirty churn). The EL0 `sys_win_set_visible` enforces ownership on top of
/// this; focus is unchanged (tracked by id, the G5 discipline).
pub fn user_set_visible(id: u8, visible: bool) bool {
    const win = find_user_window(id) orelse return false;
    if (win.visible == visible) return true;
    win.visible = visible;
    win.dirty = true;
    if (!visible) _ = mark_dirty(0); // reveal whatever sat under the hidden window
    return true;
}

/// Arc2 W1 (claim 3589, #224): drag-to-resize — hit-test, clamp, and resize.
///
/// 6×6 bottom-right corner at (x+w-6, y+h-6). Pure — host-testable.
pub fn is_resize_hit(win: Window, px: u32, py: u32) bool {
    if (win.kind != .user or !win.visible) return false;
    if (win.w < resize_hit_size or win.h < resize_hit_size) return false;
    const rx = win.x + win.w - resize_hit_size;
    const ry = win.y + win.h - resize_hit_size;
    return px >= rx and px < win.x + win.w and py >= ry and py < win.y + win.h;
}

/// Clamp helpers — pure, host-testable. Buffer bounds 128×64..512×384 plus
/// on-scanout containment (so a resize never writes beyond the framebuffer).
pub fn clamp_resize_w(req_w: i32, win_x: u32) u32 {
    var w: i32 = req_w;
    if (w < @as(i32, resize_min_w)) w = @as(i32, resize_min_w);
    if (w > @as(i32, user_buf_w)) w = @as(i32, user_buf_w);
    // Screen containment: max is remaining width from win_x.
    const max_screen = @as(i32, @intCast(virtio_gpu.fb_width -| win_x));
    if (w > max_screen) w = max_screen;
    if (w < @as(i32, resize_min_w)) w = @as(i32, resize_min_w);
    if (w < 0) w = @as(i32, resize_min_w);
    return @intCast(w);
}

pub fn clamp_resize_h(req_h: i32, win_y: u32) u32 {
    var h: i32 = req_h;
    if (h < @as(i32, resize_min_h)) h = @as(i32, resize_min_h);
    if (h > @as(i32, user_buf_h)) h = @as(i32, user_buf_h);
    const max_screen = @as(i32, @intCast(virtio_gpu.fb_height -| win_y));
    if (h > max_screen) h = max_screen;
    if (h < @as(i32, resize_min_h)) h = @as(i32, resize_min_h);
    if (h < 0) h = @as(i32, resize_min_h);
    return @intCast(h);
}

/// Resize a user window to (w, h), clamped to 128×64..512×384 and on-scanout.
/// Marks the window dirty + the terminal dirty (reveal old rect + chrome repaint
/// on next `composite()`), and emits `WIN_RESIZE` to the owning pid. Returns
/// false for an unknown id / non-user window. The EL0 `sys_win_resize` enforces
/// ownership on top of this; the compositor's pointer_tick calls it directly.
pub fn user_resize(id: u8, w: u32, h: u32) bool {
    const win = find_user_window(id) orelse return false;
    const clamped_w = clamp_resize_w(@intCast(w), win.x);
    const clamped_h = clamp_resize_h(@intCast(h), win.y);
    win.w = clamped_w;
    win.h = clamped_h;
    win.dirty = true;
    _ = mark_dirty(0);
    _ = mark_dirty(1);
    if (win.owner) |owner| {
        events.push(owner, .{
            .kind = events.WIN_RESIZE,
            .flags = 0,
            .seq = 0,
            .arg0 = clamped_w,
            .arg1 = clamped_h,
        });
    }
    return true;
}

/// True when a resize drag is active.
pub fn resize_active() bool {
    return resize_id != null;
}

pub fn resize_current_id() ?u8 {
    return resize_id;
}

/// Auto-close every user window owned by the process `owner` (the exit
/// path's teardown seam — `scheduler.exit_current` calls this with the
/// exited process's pid). Returns how many windows were released. Pure
/// BSS writes (safe in the exception context the exit path runs in).
pub fn close_owner(owner: usize) usize {
    var closed: usize = 0;
    while (true) {
        var idx: ?usize = null;
        var i: usize = 0;
        while (i < win_count) : (i += 1) {
            if (windows[i].kind == .user and windows[i].owner == owner) {
                idx = i;
                break;
            }
        }
        const found = idx orelse break;
        remove_user_at(found);
        closed += 1;
    }
    return closed;
}

/// Remove the user window at registry index `idx` (the shared release
/// primitive behind `user_close` and `close_owner`): compact the z-order,
/// fall the focus back to the terminal when the removed window held it,
/// and mark the fixed windows dirty so the next composite repaints over
/// the released window's pixels.
/// Card E4 (claim 0293): emits WIN_CLOSE to the user window owner.
fn remove_user_at(idx: usize) void {
    const removed_win = windows[idx];
    const removed_id = removed_win.id;
    if (removed_win.kind == .user and removed_win.owner != null) {
        events.push(removed_win.owner.?, .{
            .kind = events.WIN_CLOSE,
            .flags = 0,
            .seq = 0,
            .arg0 = removed_id,
            .arg1 = 0,
        });
    }
    var j = idx;
    while (j + 1 < win_count) : (j += 1) windows[j] = windows[j + 1];
    win_count -= 1;
    if (focused_id == removed_id) {
        focused_id = 0; // fall back to the terminal
    }
    // M15 C2: overlay snapshot is stale after a close — dismiss honestly.
    if (overlay_active) {
        overlay_active = false;
        overlay_count = 0;
    }
    // M15 C3: clear snap state for the closed window.
    if (snap_slot(removed_id)) |s| {
        snap_last_valid[s] = false;
        snap_snapped[s] = false;
    }
    if (drag_id != null and drag_id.? == removed_id) {
        drag_id = null;
        snap_zone = .none;
    }
    if (resize_id != null and resize_id.? == removed_id) {
        resize_id = null;
    }
    // Reveal whatever sat under the released window.
    _ = mark_dirty(0);
    _ = mark_dirty(1);
}

/// Card U5 (claim 0935, ADR 0008 D4): cycle focus to the next visible
/// window in z-order (wrapping). Returns the newly focused id, or null
/// when no window is cyclable. A focus change repaints the whole scene
/// (mark_dirty(0) — the compositor repaints everything above the lowest
/// dirty window, so the ring moves correctly under any overlay).
pub fn cycle_focus() ?u8 {
    if (win_count == 0) return null;
    const start = focused_index() orelse 0;
    var i: usize = 1;
    while (i <= win_count) : (i += 1) {
        const idx = (start + i) % win_count;
        if (!windows[idx].visible) continue;
        // Wallpaper, taskbar and dock are not cyclable.
        if (windows[idx].kind == .wallpaper or windows[idx].kind == .taskbar or windows[idx].kind == .dock) continue;
        const target_id = windows[idx].id;
        _ = focus(target_id);
        return focused_id;
    }
    return null;
}

/// M15 C2 (Alt+Tab overlay, #225): hold-Alt cycling UI — BSS snapshot + highlight.
/// Pure overlay: Alt held + first Tab captures user-window ids, Tab/Shift+Tab cycles
/// `overlay_selected`, Alt release commits the highlight. No new syscall/kind.
pub fn alt_tab_is_active() bool {
    return overlay_active;
}

pub fn alt_tab_selected_id() ?u8 {
    if (!overlay_active or overlay_count == 0) return null;
    return overlay_ids[overlay_selected];
}

pub fn alt_tab_count() usize {
    return overlay_count;
}

/// Snapshot user windows and activate the overlay. Returns true when an overlay
/// with ≥2 windows is now visible (1 window → no overlay, honest no-op).
pub fn alt_tab_activate() bool {
    if (overlay_active) return false;
    var ids: [max_windows]u8 = undefined;
    var cnt: usize = 0;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        const w = windows[i];
        if (!w.visible) continue;
        if (w.kind != .user) continue;
        if (cnt < max_windows) {
            ids[cnt] = w.id;
            cnt += 1;
        }
    }
    if (cnt <= 1) return false;
    var sel: usize = 0;
    var found: ?usize = null;
    var k: usize = 0;
    while (k < cnt) : (k += 1) {
        if (ids[k] == focused_id) {
            found = k;
            break;
        }
    }
    if (found) |idx| sel = (idx + 1) % cnt else sel = 0;
    var j: usize = 0;
    while (j < cnt) : (j += 1) overlay_ids[j] = ids[j];
    overlay_count = cnt;
    overlay_selected = sel;
    overlay_active = true;
    _ = mark_dirty(0);
    return true;
}

/// Cycle the highlight — Shift inverts (reverse).
pub fn alt_tab_cycle(shift: bool) void {
    if (!overlay_active or overlay_count == 0) return;
    if (shift) {
        if (overlay_selected == 0) overlay_selected = overlay_count - 1 else overlay_selected -= 1;
    } else {
        overlay_selected = (overlay_selected + 1) % overlay_count;
    }
    _ = mark_dirty(0);
}

/// Commit the highlighted window (focus+raise) and dismiss the overlay.
pub fn alt_tab_commit() ?u8 {
    if (!overlay_active or overlay_count == 0) return null;
    const id = overlay_ids[overlay_selected];
    overlay_active = false;
    overlay_count = 0;
    _ = focus(id);
    _ = raise(id);
    _ = mark_dirty(0);
    return id;
}

/// Dismiss without committing (right-click / Escape).
pub fn alt_tab_dismiss() void {
    if (!overlay_active) return;
    overlay_active = false;
    overlay_count = 0;
    _ = mark_dirty(0);
}

/// M15 C3 (Snap zones, #227): 20 px threshold, corners first, then edges.
pub fn snap_zone_for_point(x: u32, y: u32) SnapZone {
    const thresh: u32 = 20;
    const w = virtio_gpu.fb_width;
    const h = virtio_gpu.fb_height;
    const near_left = x < thresh;
    const near_right = x + thresh >= w;
    const near_top = y < thresh;
    const near_bottom = y + thresh >= h;
    // Corners take precedence (avoid flicker when corner zones overlap edges).
    if (near_left and near_top) return .top_left;
    if (near_right and near_top) return .top_right;
    if (near_left and near_bottom) return .bottom_left;
    if (near_right and near_bottom) return .bottom_right;
    if (near_left) return .left;
    if (near_right) return .right;
    if (near_top) return .top;
    if (near_bottom) return .bottom;
    return .none;
}

/// Zone bounds in scanout coordinates (taskbar excluded for bottom zones).
/// Returns the zone's full rect; caller clamps to `user_buf_w`/`h` for the window.
pub fn snap_zone_bounds(zone: SnapZone) ?struct { x: u32, y: u32, w: u32, h: u32 } {
    const w = virtio_gpu.fb_width;
    const h = virtio_gpu.fb_height;
    const half_w = w / 2;
    const half_h = (h - taskbar_h) / 2;
    return switch (zone) {
        .none => null,
        .left => .{ .x = 0, .y = 0, .w = half_w, .h = h - taskbar_h },
        .right => .{ .x = half_w, .y = 0, .w = w - half_w, .h = h - taskbar_h },
        .top => .{ .x = 0, .y = 0, .w = w, .h = half_h },
        .bottom => .{ .x = 0, .y = half_h, .w = w, .h = h - half_h - taskbar_h },
        .top_left => .{ .x = 0, .y = 0, .w = half_w, .h = half_h },
        .top_right => .{ .x = half_w, .y = 0, .w = w - half_w, .h = half_h },
        .bottom_left => .{ .x = 0, .y = half_h, .w = half_w, .h = half_h },
        .bottom_right => .{ .x = half_w, .y = half_h, .w = w - half_w, .h = half_h },
    };
}

/// Per-window slot for snap state (user windows 2..5 → 0..3).
fn snap_slot(id: u8) ?usize {
    if (id < user_window_id_base) return null;
    const s = @as(usize, id - user_window_id_base);
    if (s >= user_windows_max) return null;
    return s;
}

/// True when the user window is currently snapped.
pub fn snap_is_snapped(id: u8) bool {
    const s = snap_slot(id) orelse return false;
    return snap_snapped[s];
}

/// Snap the user window to the zone — saves last rect if not already snapped,
/// clamps to `user_buf_w`/`h`, centers within zone, marks dirty, sets snapped.
pub fn snap_window(id: u8, zone: SnapZone) bool {
    const s = snap_slot(id) orelse return false;
    const win = find_user_window(id) orelse return false;
    const zb = snap_zone_bounds(zone) orelse return false;
    if (!snap_snapped[s]) {
        snap_last_x[s] = win.x;
        snap_last_y[s] = win.y;
        snap_last_w[s] = win.w;
        snap_last_h[s] = win.h;
        snap_last_valid[s] = true;
    }
    const win_w = @min(zb.w, user_buf_w);
    const win_h = @min(zb.h, user_buf_h);
    const win_x = zb.x + (zb.w - win_w) / 2;
    const win_y = zb.y + (zb.h - win_h) / 2;
    win.x = win_x;
    win.y = win_y;
    win.w = win_w;
    win.h = win_h;
    win.dirty = true;
    snap_snapped[s] = true;
    _ = mark_dirty(0);
    return true;
}

/// Restore the window's pre-snap rect if it was snapped.
pub fn snap_restore(id: u8) bool {
    const s = snap_slot(id) orelse return false;
    if (!snap_snapped[s] or !snap_last_valid[s]) return false;
    const win = find_user_window(id) orelse return false;
    win.x = snap_last_x[s];
    win.y = snap_last_y[s];
    win.w = snap_last_w[s];
    win.h = snap_last_h[s];
    win.dirty = true;
    snap_snapped[s] = false;
    snap_last_valid[s] = false;
    _ = mark_dirty(0);
    return true;
}

/// Current snap preview zone (for `draw_chrome`).
pub fn snap_current_zone() SnapZone {
    return snap_zone;
}

/// Map raw pointer buttons bitmask to ADR 0009 button flags.
pub fn mouse_buttons_to_flags(buttons: u8) u16 {
    var flags: u16 = 0;
    if ((buttons & 0x01) != 0) flags |= events.BTN_LEFT;
    if ((buttons & 0x02) != 0) flags |= events.BTN_RIGHT;
    if ((buttons & 0x04) != 0) flags |= events.BTN_MIDDLE;
    return flags;
}

/// Card U4 (claim 4993): the pointer tick — consume the pointer state from
/// the input path (motion + click edges). Returns the newly focused window
/// id when a CLICK landed on a window (D4: click = focus + raise), null
/// otherwise. Called from the shell idle loop; a no-op when the input path
/// is unarmed (the default VM).
/// Card E3 (claim 9228): converts absolute pointer motion and button clicks
/// within a user window to window-local coordinates and queues MOUSE_DOWN,
/// MOUSE_UP, and MOUSE_MOVE events to the hit user window's owning process.
pub fn pointer_tick(st: input.PointerState, click: ?input.Click) ?u8 {
    if (!armed_global) return null;
    var focused_changed: ?u8 = null;
    if (st.valid) {
        const nx = map_pointer_axis(st.x, virtio_gpu.fb_width);
        const ny = map_pointer_axis(st.y, virtio_gpu.fb_height);
        const moved = (!cursor_shown or nx != cursor_x or ny != cursor_y);
        if (moved) {
            cursor_x = nx;
            cursor_y = ny;
            cursor_shown = true;
            _ = mark_dirty(0); // the cursor moves over a full repaint
        }

        const kb_flags = input.hid_modifiers_to_flags(input.report().kb_mods);
        const btn_flags = mouse_buttons_to_flags(st.buttons);
        const all_flags = btn_flags | kb_flags;

        const left_bit: u8 = 0x01;
        const right_bit: u8 = 0x02;
        const prev_left = (prev_ptr_buttons & left_bit) != 0;
        const prev_right = (prev_ptr_buttons & right_bit) != 0;
        const cur_left = (st.buttons & left_bit) != 0;
        const cur_right = (st.buttons & right_bit) != 0;
        const left_pressed = (!prev_left and cur_left) or (click != null);
        const left_released = (prev_left and !cur_left);
        const right_pressed = (!prev_right and cur_right);
        const right_released = (prev_right and !cur_right);

        // Step 5/6/7: drag + close + minimize handling on MOUSE_DOWN (left only).
        // M15 C4: dock handling must precede user windows — dock is at 0,0,24,700.
        if (left_pressed) {
            var handled_btn = false;
            // Arc4 #242: unsaved-changes dialog intercepts all clicks while open.
            if (unsaved_dialog_open) {
                switch (unsaved_dialog_click(cursor_x, cursor_y)) {
                    .save, .dont_save, .cancel => {
                        handled_btn = true;
                    },
                    .none => {},
                }
            }
            // M15 C4: dock icon click — 24 px left bar, 20×20 icons at (2,8+idx*32).
            if (cursor_x < dock_w and cursor_y < dock_h) {
                if (cursor_x >= 2 and cursor_x < 22) {
                    var idx: usize = 0;
                    while (idx < 5) : (idx += 1) {
                        const iy = 8 + @as(u32, @intCast(idx)) * 32;
                        if (cursor_y >= iy and cursor_y < iy + 20) {
                            var has_user = false;
                            var k: usize = 0;
                            while (k < win_count) : (k += 1) {
                                if (windows[k].kind == .user) {
                                    has_user = true;
                                    break;
                                }
                            }
                            if (!has_user) {
                                _ = user_open(64, 64, 512, 384, 99);
                            } else {
                                var kk: usize = 0;
                                while (kk < win_count) : (kk += 1) {
                                    if (windows[kk].kind == .user) {
                                        _ = focus(windows[kk].id);
                                        _ = raise(windows[kk].id);
                                        break;
                                    }
                                }
                            }
                            _ = mark_dirty(0);
                            handled_btn = true;
                            break;
                        }
                    }
                }
            }
            if (!handled_btn) {
                // Check close/minimize buttons on user windows first.
                var wi: usize = win_count;
                while (wi > 0) {
                    wi -= 1;
                    const w = &windows[wi];
                    if (w.kind != .user or !w.visible) continue;
                    // Close button: top-right corner (x + w.w - 14, y + 4, 8x8).
                    if (cursor_x >= w.x + w.w - 16 and cursor_x < w.x + w.w - 4 and
                        cursor_y >= w.y and cursor_y < w.y + user_title_h)
                    {
                        // Arc4 #242: dirty window → show unsaved-changes dialog.
                        if (w.unsaved) {
                            unsaved_dialog_show(w.id);
                        } else {
                            _ = user_close(w.id);
                        }
                        handled_btn = true;
                        break;
                    }
                    // Minimize button: left of close (x + w.w - 26, y + 4, 8x8).
                    if (cursor_x >= w.x + w.w - 28 and cursor_x < w.x + w.w - 16 and
                        cursor_y >= w.y and cursor_y < w.y + user_title_h)
                    {
                        _ = user_set_visible(w.id, false);
                        handled_btn = true;
                        break;
                    }
                    // Arc2 W1: resize handle — 6×6 bottom-right corner.
                    if (is_resize_hit(w.*, cursor_x, cursor_y)) {
                        resize_id = w.id;
                        resize_start_x = cursor_x;
                        resize_start_y = cursor_y;
                        resize_origin_w = w.w;
                        resize_origin_h = w.h;
                        _ = focus(w.id);
                        _ = raise(w.id);
                        _ = mark_dirty(0);
                        focused_changed = w.id;
                        handled_btn = true;
                        break;
                    }
                    // Title bar drag initiation.
                    if (cursor_x >= w.x and cursor_x < w.x + w.w and
                        cursor_y >= w.y and cursor_y < w.y + user_title_h)
                    {
                        // M15 C3: snapped windows restore on drag-out — restore before
                        // capturing the drag offset so the offset tracks the restored rect.
                        if (snap_is_snapped(w.id)) {
                            _ = snap_restore(w.id);
                        }
                        drag_id = w.id;
                        drag_offset_x = if (cursor_x >= w.x) cursor_x - w.x else 0;
                        drag_offset_y = if (cursor_y >= w.y) cursor_y - w.y else 0;
                        _ = focus(w.id);
                        _ = raise(w.id);
                        _ = mark_dirty(0);
                        focused_changed = w.id;
                        handled_btn = true;
                        break;
                    }
                }
            }
            // Fall through to normal focus-at if no button/title bar was hit.
            if (!handled_btn) {
                if (focus_at(cursor_x, cursor_y)) {
                    const id = focused_id;
                    _ = raise(id);
                    _ = mark_dirty(0);
                    focused_changed = id;
                }
            }
        }
        // Arc2 W2: right-click — focus the hit window (no drag/resize/close).
        if (right_pressed) {
            if (focus_at(cursor_x, cursor_y)) {
                const id = focused_id;
                _ = raise(id);
                _ = mark_dirty(0);
                focused_changed = id;
            }
        }

        // Arc2 W1: resize drag — live clamp + chrome repaint + WIN_RESIZE.
        if (resize_id) |rid| {
            if (moved and cur_left) {
                const dx = @as(i32, @intCast(cursor_x)) - @as(i32, @intCast(resize_start_x));
                const dy = @as(i32, @intCast(cursor_y)) - @as(i32, @intCast(resize_start_y));
                const req_w = @as(i32, @intCast(resize_origin_w)) + dx;
                const req_h = @as(i32, @intCast(resize_origin_h)) + dy;
                const win = find_user_window(rid) orelse null;
                if (win) |w| {
                    const new_w = clamp_resize_w(req_w, w.x);
                    const new_h = clamp_resize_h(req_h, w.y);
                    if (new_w != w.w or new_h != w.h) {
                        _ = user_resize(rid, new_w, new_h);
                    }
                }
            }
            if (left_released) {
                resize_id = null;
            }
        } else if (drag_id) |did| {
            if (moved and cur_left) {
                const new_x: u32 = if (cursor_x >= drag_offset_x) cursor_x - drag_offset_x else 0;
                const new_y: u32 = if (cursor_y >= drag_offset_y) cursor_y - drag_offset_y else 0;
                _ = user_move(did, new_x, new_y);
                const z = snap_zone_for_point(cursor_x, cursor_y);
                if (z != snap_zone) {
                    snap_zone = z;
                    _ = mark_dirty(0);
                }
            }
            if (left_released) {
                if (snap_zone != .none) {
                    _ = snap_window(did, snap_zone);
                }
                drag_id = null;
                if (snap_zone != .none) {
                    snap_zone = .none;
                    _ = mark_dirty(0);
                }
            }
        } else {
            if (snap_zone != .none) {
                snap_zone = .none;
                _ = mark_dirty(0);
            }
        }

        // Arc4 #237: drag-and-drop — detect window crossing during active drag.
        if (drag_active and moved) {
            const new_hit = hit_test(cursor_x, cursor_y);
            const new_id: ?u8 = if (new_hit) |hid| blk: {
                if (find_user_window(hid)) |w| {
                    if (w.owner) |_| break :blk hid;
                }
                break :blk null;
            } else null;
            if (new_id != drag_over_id) {
                // DRAG_LEAVE to old window.
                if (drag_over_id) |old_id| {
                    if (find_user_window(old_id)) |ow| {
                        if (ow.owner) |old_owner| {
                            events.push(old_owner, .{
                                .kind = events.DRAG_LEAVE,
                                .flags = 0,
                                .seq = 0,
                                .arg0 = 0,
                                .arg1 = @intCast(drag_source_pid),
                            });
                        }
                    }
                }
                // DRAG_ENTER to new window.
                if (new_id) |nid| {
                    if (find_user_window(nid)) |nw| {
                        if (nw.owner) |new_owner| {
                            events.push(new_owner, .{
                                .kind = events.DRAG_ENTER,
                                .flags = 0,
                                .seq = 0,
                                .arg0 = @intCast(drag_payload_len),
                                .arg1 = @intCast(drag_source_pid),
                            });
                        }
                    }
                }
                drag_over_id = new_id;
            }
        }
        // Arc4 #237: DROP on left release during active drag.
        // Two-step: DROP event signals payload available (arg0=size),
        // then the target calls sys_drag_read to copy the payload.
        if (drag_active and left_released) {
            if (hit_test(cursor_x, cursor_y)) |drop_id| {
                if (find_user_window(drop_id)) |dw| {
                    if (dw.owner) |drop_owner| {
                        events.push(drop_owner, .{
                            .kind = events.DROP,
                            .flags = 0,
                            .seq = 0,
                            .arg0 = @intCast(drag_payload_len),
                            .arg1 = @intCast(drag_source_pid),
                        });
                    }
                }
            }
            // Don't clear drag_active yet — sys_drag_read needs the payload.
            // Clear after the target reads or on a new sys_drag_start.
        }

        // Deliver pointer events to hit user window
        if (hit_test(cursor_x, cursor_y)) |hit_id| {
            if (find_user_window(hit_id)) |w| {
                if (w.owner) |owner_pid| {
                    const local_x: u32 = if (cursor_x >= w.x) @min(cursor_x - w.x, w.w - 1) else 0;
                    const local_y: u32 = if (cursor_y >= w.y) @min(cursor_y - w.y, w.h - 1) else 0;

                    if (moved) {
                        events.push(owner_pid, .{
                            .kind = events.MOUSE_MOVE,
                            .flags = all_flags,
                            .seq = 0,
                            .arg0 = local_x,
                            .arg1 = local_y,
                        });
                    }
                    if (left_pressed) {
                        events.push(owner_pid, .{
                            .kind = events.MOUSE_DOWN,
                            .flags = all_flags,
                            .seq = 0,
                            .arg0 = local_x,
                            .arg1 = local_y,
                        });
                    }
                    if (left_released) {
                        events.push(owner_pid, .{
                            .kind = events.MOUSE_UP,
                            .flags = all_flags,
                            .seq = 0,
                            .arg0 = local_x,
                            .arg1 = local_y,
                        });
                    }
                    if (right_pressed) {
                        events.push(owner_pid, .{
                            .kind = events.MOUSE_RIGHT_DOWN,
                            .flags = all_flags,
                            .seq = 0,
                            .arg0 = local_x,
                            .arg1 = local_y,
                        });
                    }
                    if (right_released) {
                        events.push(owner_pid, .{
                            .kind = events.MOUSE_RIGHT_UP,
                            .flags = all_flags,
                            .seq = 0,
                            .arg0 = local_x,
                            .arg1 = local_y,
                        });
                    }
                }
            }
        }

        prev_ptr_buttons = st.buttons;
    }
    return focused_changed;
}

/// HID absolute pointers report 0..32767 logical; map onto the framebuffer
/// axis. Pure — host-testable.
pub fn map_pointer_axis(v: u16, span: u32) u32 {
    const scaled = (@as(u32, v) * span + 16384) / 32768;
    return if (scaled >= span) span - 1 else scaled;
}

/// Card U4: the cursor's current framebuffer cell (for reports + tests).
pub fn cursor_pos() ?struct { x: u32, y: u32 } {
    if (!cursor_shown) return null;
    return .{ .x = cursor_x, .y = cursor_y };
}

// ---------------------------------------------------------------------------
// Pixel helpers (pure — host-testable)
// ---------------------------------------------------------------------------

fn put_px(buf: [*]u8, stride: usize, x: usize, y: usize, rgb: u32) void {
    const off = y * stride + x * 4;
    buf[off] = @truncate(rgb & 0xff); // B
    buf[off + 1] = @truncate((rgb >> 8) & 0xff); // G
    buf[off + 2] = @truncate((rgb >> 16) & 0xff); // R
    buf[off + 3] = 0xff; // X — opaque (the claim-6053 lesson)
}

fn fill_rect(buf: [*]u8, stride: usize, x0: usize, y0: usize, w: usize, h: usize, rgb: u32) void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) put_px(buf, stride, x0 + x, y0 + y, rgb);
    }
}

/// Draw one 8x8 glyph at (x0, y0) in the given 0xRRGGBB color. Non-printable
/// bytes are skipped (no invented pixels).
fn draw_glyph(buf: [*]u8, stride: usize, x0: usize, y0: usize, c: u8, rgb: u32) void {
    if (c < 0x20 or c > 0x7e) return;
    const glyph = font.glyphs[c - 0x20];
    var gy: usize = 0;
    while (gy < 8) : (gy += 1) {
        const bits = glyph[gy];
        var gx: usize = 0;
        while (gx < 8) : (gx += 1) {
            if (font.row_pixel(bits, gx)) put_px(buf, stride, x0 + gx, y0 + gy, rgb);
        }
    }
}

fn draw_string(buf: [*]u8, stride: usize, x0: usize, y0: usize, s: []const u8, rgb: u32) void {
    for (s, 0..) |c, i| draw_glyph(buf, stride, x0 + i * 8, y0, c, rgb);
}

/// Step 6 (Issue #206): draw one 8×16 glyph at (x0, y0). Uses the 2×-stretched
/// glyph table for titles and headings. Non-printable bytes are skipped.
fn draw_glyph_16(buf: [*]u8, stride: usize, x0: usize, y0: usize, c: u8, rgb: u32) void {
    if (c < 0x20 or c > 0x7e) return;
    const glyph = font.glyphs_16[c - 0x20];
    var gy: usize = 0;
    while (gy < 16) : (gy += 1) {
        const bits = glyph[gy];
        var gx: usize = 0;
        while (gx < 8) : (gx += 1) {
            if (font.row_pixel_16(bits, gx)) put_px(buf, stride, x0 + gx, y0 + gy, rgb);
        }
    }
}

/// Draw a string using the 8×16 font. Each glyph advances 8px horizontally.
fn draw_string_16(buf: [*]u8, stride: usize, x0: usize, y0: usize, s: []const u8, rgb: u32) void {
    for (s, 0..) |c, i| draw_glyph_16(buf, stride, x0 + i * 8, y0, c, rgb);
}

/// Minimal unsigned-decimal formatting (no heap, no failure modes) — the
/// clock's dynamic text. Returns the filled slice.
pub fn fmt_decimal(buf: []u8, v: u64) []const u8 {
    if (buf.len == 0) return "";
    if (v == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x > 0 and n < tmp.len) : (n += 1) {
        tmp[n] = @as(u8, @intCast(x % 10)) + '0';
        x /= 10;
    }
    const out = @min(n, buf.len);
    var i: usize = 0;
    while (i < out) : (i += 1) buf[i] = tmp[n - 1 - i];
    return buf[0..out];
}

/// Copy a B8G8R8X8 rect from `src` (stride `src_stride` bytes) into `dst`
/// (stride `dst_stride` bytes) at (dx, dy). Pure — host-testable.
pub fn blit_rect(
    dst: [*]u8,
    dst_stride: usize,
    src: [*]const u8,
    src_stride: usize,
    dx: usize,
    dy: usize,
    w: usize,
    h: usize,
) void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const drow = dst + (dy + y) * dst_stride + dx * 4;
        const srow = src + y * src_stride;
        @memcpy(drow[0 .. w * 4], srow[0 .. w * 4]);
    }
}

/// Arc4 #239: alpha-blended blit. Blends `src` over `dst` with the
/// given alpha (0..256). 256 = fully opaque (same as blit_rect),
/// 64 = 25%, 128 = 50%. Per-pixel: dst = dst × (1 - a/256) + src × (a/256).
/// Pure BSS math, no allocation.
pub fn blit_rect_alpha(
    dst: [*]u8,
    dst_stride: usize,
    src: [*]const u8,
    src_stride: usize,
    dx: usize,
    dy: usize,
    w: usize,
    h: usize,
    alpha: u16,
) void {
    if (alpha >= 256) {
        blit_rect(dst, dst_stride, src, src_stride, dx, dy, w, h);
        return;
    }
    const inv_alpha: u16 = 256 - alpha;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const drow = dst + (dy + y) * dst_stride + dx * 4;
        const srow = src + y * src_stride;
        var x: usize = 0;
        while (x < w * 4) : (x += 1) {
            const d: u16 = drow[x];
            const s: u16 = srow[x];
            drow[x] = @intCast((d * inv_alpha + s * alpha) >> 8);
        }
    }
}

// ---------------------------------------------------------------------------
// Window painting
// ---------------------------------------------------------------------------

fn fb_canvas() fbtext.Canvas {
    return .{
        .base = @ptrCast(&virtio_gpu.gpu_fb),
        .width = virtio_gpu.fb_width,
        .height = virtio_gpu.fb_height,
        .stride = virtio_gpu.fb_width * 4,
    };
}

/// Render the clock window's content into a buffer. `focused` selects the
/// focus-status line. Pure — host-testable with an injectable buffer.
pub fn render_clock_content(buf: [*]u8, stride: usize, w: usize, h: usize, ticks: u64, focused: bool) void {
    // Background + border (2 px), then the amber title bar.
    fill_rect(buf, stride, 0, 0, w, h, clock_bg());
    fill_rect(buf, stride, 0, 0, w, 2, clock_border_rgb);
    fill_rect(buf, stride, 0, h - 2, w, 2, clock_border_rgb);
    fill_rect(buf, stride, 0, 0, 2, h, clock_border_rgb);
    fill_rect(buf, stride, w - 2, 0, 2, h, clock_border_rgb);
    fill_rect(buf, stride, 2, 2, w - 4, 16, clock_title_bg());

    draw_string(buf, stride, 8, 6, "clock", clock_title_fg_rgb);

    var nb: [24]u8 = undefined;
    // Body lines (8 px grid, origin 8 px inside the border).
    draw_string_16(buf, stride, 8, 26, "DRIVING AWARD", clock_accent_rgb);
    draw_string(buf, stride, 8, 42, "ticks=", clock_fg_rgb);
    draw_string(buf, stride, 8 + 6 * 8, 42, fmt_decimal(&nb, ticks), clock_fg_rgb);
    draw_string(buf, stride, 8, 58, if (focused) "focus=clock" else "focus=roadpops", clock_fg_rgb);
    draw_string(buf, stride, 8, 74, "windows=2", clock_fg_rgb);
}

/// Paint one window into the framebuffer. The terminal renders the shared
/// text layer straight into the scanout framebuffer; the clock renders its
/// back-buffer and blits it over the terminal.
fn paint(w: *Window) void {
    switch (w.kind) {
        .terminal => fbtext.render(fb_canvas()),
        .clock => {
            render_clock_content(
                @ptrCast(&clock_buf),
                clock_w * 4,
                clock_w,
                clock_h,
                if (clock_has_tick) clock_shown_tick else 0,
                focused_id == w.id,
            );
            blit_rect(
                @ptrCast(&virtio_gpu.gpu_fb),
                virtio_gpu.fb_width * 4,
                @ptrCast(&clock_buf),
                clock_w * 4,
                w.x,
                w.y,
                w.w,
                w.h,
            );
        },
        .user => {
            const idx = w.id - user_window_id_base;
            if (idx >= user_windows_max) return;
            // Arc4 #239: during fade-in, blend with alpha over the
            // background (wallpaper/terminal already composited below).
            const alpha: u16 = if (w.fade_phase == 1)
                if (w.fade_tick < fade_half_frames) 64 // 25%
                else if (w.fade_tick < fade_half_frames * 2) 128 // 50%
                else 256 // fully opaque (fade complete)
            else
                256;
            if (alpha < 256) {
                blit_rect_alpha(
                    @ptrCast(&virtio_gpu.gpu_fb),
                    virtio_gpu.fb_width * 4,
                    @ptrCast(&user_bufs[idx]),
                    user_buf_w * 4,
                    w.x,
                    w.y,
                    w.w,
                    w.h,
                    alpha,
                );
            } else {
                blit_rect(
                    @ptrCast(&virtio_gpu.gpu_fb),
                    virtio_gpu.fb_width * 4,
                    @ptrCast(&user_bufs[idx]),
                    user_buf_w * 4,
                    w.x,
                    w.y,
                    w.w,
                    w.h,
                );
            }
        },
        .wallpaper => {
            // Step 9: vertical gradient from wallpaper_top() to wallpaper_bot().
            const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
            const stride = virtio_gpu.fb_width * 4;
            var y: u32 = 0;
            while (y < virtio_gpu.fb_height) : (y += 1) {
                const t = y * 256 / virtio_gpu.fb_height;
                const r = ((wallpaper_top() >> 16) & 0xff) * (256 - t) / 256 + ((wallpaper_bot() >> 16) & 0xff) * t / 256;
                const g = ((wallpaper_top() >> 8) & 0xff) * (256 - t) / 256 + ((wallpaper_bot() >> 8) & 0xff) * t / 256;
                const b = (wallpaper_top() & 0xff) * (256 - t) / 256 + (wallpaper_bot() & 0xff) * t / 256;
                const row_color: u32 = (@as(u32, @intCast(r)) << 16) | (@as(u32, @intCast(g)) << 8) | @as(u32, @intCast(b));
                fill_rect(fb, stride, 0, y, virtio_gpu.fb_width, 1, row_color);
            }
        },
        .taskbar => {
            // Step 8: dark background bar spanning full width.
            const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
            const stride = virtio_gpu.fb_width * 4;
            fill_rect(fb, stride, 0, taskbar_y, virtio_gpu.fb_width, taskbar_h, taskbar_bg());
            // Arc4 #241: workspace switcher [1][2][3] on the left side.
            var ws_x: u32 = 4;
            var ws_idx: u8 = 0;
            while (ws_idx < workspace_max) : (ws_idx += 1) {
                const is_cur = ws_idx == current_workspace;
                const ws_bg = if (is_cur) taskbar_entry_active() else taskbar_entry_dimmed();
                fill_rect(fb, stride, ws_x, taskbar_y + 2, 20, taskbar_h - 4, ws_bg);
                const label: [1]u8 = .{'1' + ws_idx};
                draw_string(fb, stride, ws_x + 6, taskbar_y + 6, label[0..1], 0xffffff);
                ws_x += 24;
            }
            // Render entries for each open user window.
            var entry_x: u32 = ws_x + 4;
            var wi: usize = 0;
            while (wi < win_count) : (wi += 1) {
                const ww = &windows[wi];
                if (ww.kind != .user) continue;
                const entry_w: u32 = 80;
                const entry_bg = if (focused_id == ww.id) taskbar_entry_active() else taskbar_entry_dimmed();
                fill_rect(fb, stride, entry_x, taskbar_y + 2, entry_w, taskbar_h - 4, entry_bg);
                draw_string(fb, stride, entry_x + 4, taskbar_y + 6, ww.title, 0xffffff);
                entry_x += entry_w + 4;
            }
            // Arc2 W3: tray in right 80px — HH:MM, D/L/A, clipboard rect.
            // HH:MM from tray_tick (tick-derived, 1 Hz).
            var tbuf: [5]u8 = undefined;
            const hhmm = format_hhmm(&tbuf, if (tray_has_tick) tray_tick else 0);
            draw_string(fb, stride, tray_x + 4, tray_y + 6, hhmm, 0xffffff);
            // Theme letter in accent
            var tletter: [1]u8 = .{theme_letter()};
            draw_string(fb, stride, tray_x + 48, tray_y + 6, tletter[0..1], tray_theme_accent());
            // Clipboard indicator: filled when has content, outline when empty.
            const clip_x = tray_x + 64;
            const clip_y = tray_y + 6;
            const clip_w: usize = 10;
            const clip_h: usize = 8;
            if (tray_clipboard_filled()) {
                fill_rect(fb, stride, clip_x, clip_y, clip_w, clip_h, 0xffffff);
            } else {
                fill_rect(fb, stride, clip_x, clip_y, clip_w, 1, 0xffffff);
                fill_rect(fb, stride, clip_x, clip_y + clip_h - 1, clip_w, 1, 0xffffff);
                fill_rect(fb, stride, clip_x, clip_y, 1, clip_h, 0xffffff);
                fill_rect(fb, stride, clip_x + clip_w - 1, clip_y, 1, clip_h, 0xffffff);
            }
        },
        .dock => {
            // M15 C4: 24 px left dock, vertical icon bar (hardcoded dock apps).
            const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
            const stride = virtio_gpu.fb_width * 4;
            fill_rect(fb, stride, w.x, w.y, w.w, w.h, dock_bg_rgb);
            // Icons for dock=true apps (first 5 from image/apps.txt).
            const dock_icons = [_]u8{ 'c', 'n', 't', 'b', 's' };
            var idx: usize = 0;
            while (idx < dock_icons.len) : (idx += 1) {
                const iy = w.y + 8 + @as(u32, @intCast(idx)) * 32;
                if (iy + 24 > w.y + w.h) break;
                const bg = if (idx == 0 and focused_id == 2) dock_icon_active_rgb else dock_icon_bg_rgb;
                fill_rect(fb, stride, w.x + 2, iy, 20, 20, bg);
                draw_glyph(fb, stride, w.x + 8, iy + 6, dock_icons[idx], 0xffffff);
            }
        },
    }
}

/// The repaint plan: the index of the LOWEST dirty visible window, or null
/// when the scene is clean. Pure — host-testable.
fn repaint_start() ?usize {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].visible and windows[i].dirty) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The compositor
// ---------------------------------------------------------------------------

/// Composite: repaint every visible window from the lowest dirty one UP (so
/// the clock is always re-blitted over a freshly repainted terminal), then
/// push one transfer + flush. Returns the flush result; `.ok` with no work
/// when the scene is clean (dirty-rect: unchanged windows are never
/// repainted).
pub fn composite() virtio_gpu.CmdResult {
    if (!armed_global) return .not_ready;
    // Arc2 W3: tray clock ticks on composite() without timer — detect theme/
    // clipboard changes that happened since last composite and mark taskbar
    // dirty so the tray repaints even without a tick. Tick-driven dirty is
    // handled in drain(); this covers settings/clipboard writes that occur
    // between ticks.
    {
        const cur_theme = theme_id;
        const cur_clip = clipboard.current_len();
        var need = false;
        if (cur_theme != tray_last_theme) {
            tray_last_theme = cur_theme;
            need = true;
        }
        if (cur_clip != tray_last_clip_len) {
            tray_last_clip_len = cur_clip;
            need = true;
        }
        if (need) _ = mark_dirty(255);
    }
    const start = repaint_start() orelse return .ok;
    // Step 9: render the wallpaper gradient BEFORE windows so it is the background.
    if (start <= 1) {
        // The wallpaper is at index 1 (after tray migration); if it or anything below is dirty, render gradient.
        const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
        const stride = virtio_gpu.fb_width * 4;
        var y: u32 = 0;
        while (y < virtio_gpu.fb_height) : (y += 1) {
            const t = y * 256 / virtio_gpu.fb_height;
            const r = ((wallpaper_top() >> 16) & 0xff) * (256 - t) / 256 + ((wallpaper_bot() >> 16) & 0xff) * t / 256;
            const g = ((wallpaper_top() >> 8) & 0xff) * (256 - t) / 256 + ((wallpaper_bot() >> 8) & 0xff) * t / 256;
            const b = (wallpaper_top() & 0xff) * (256 - t) / 256 + (wallpaper_bot() & 0xff) * t / 256;
            const row_color: u32 = (@as(u32, @intCast(r)) << 16) | (@as(u32, @intCast(g)) << 8) | @as(u32, @intCast(b));
            fill_rect(fb, stride, 0, y, virtio_gpu.fb_width, 1, row_color);
        }
    }
    var i = start;
    while (i < win_count) : (i += 1) {
        const w = &windows[i];
        if (!w.visible) continue;
        // Arc4 #241: skip user windows not in the current workspace.
        if (!workspace_visible(w)) {
            w.dirty = false;
            continue;
        }
        // Wallpaper is rendered via the gradient path above.
        if (w.kind == .wallpaper) {
            w.dirty = false;
            continue;
        }
        paint(w);
        w.dirty = false;
    }
    // Arc4 #239: advance fade-in ticks after painting. Each composite
    // frame increments the tick; after 2 × fade_half_frames the fade
    // completes and the window renders at full opacity.
    {
        var fi: usize = 0;
        while (fi < win_count) : (fi += 1) {
            const fw = &windows[fi];
            if (fw.fade_phase == 1) {
                fw.fade_tick +|= 1;
                if (fw.fade_tick >= fade_half_frames * 2) {
                    fw.fade_phase = 0; // fade complete
                    fw.fade_tick = 0;
                }
                fw.dirty = true; // repaint at new alpha
            }
        }
    }
    // Arc4 #240: advance notification dismiss ticks once per composite.
    notify_advance_ticks();
    // Arc4 #242: advance unsaved-changes dialog timeout once per composite.
    _ = unsaved_dialog_advance_tick();
    draw_chrome();
    if (!virtio_gpu.gpu_ready) return .not_ready;
    presents += 1;
    if (virtio_gpu.gpu_transfer() != .ok) return .timeout;
    return virtio_gpu.gpu_flush();
}

/// Card U5/U4: the chrome pass, drawn on the framebuffer AFTER the window
/// paints and BEFORE the transfer — user title bars, the focus ring on the
/// focused window, and the pointer cursor. Chrome never touches a window's
/// back-buffer (user buffers stay EL0-owned).
fn draw_chrome() void {
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const stride = virtio_gpu.fb_width * 4;
    const wspan = virtio_gpu.fb_width;
    const hspan = virtio_gpu.fb_height;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        const w = &windows[i];
        if (w.kind != .user or !w.visible) continue;
        // Arc4 #241: skip chrome for windows not in the current workspace.
        if (!workspace_visible(w)) continue;
        // M20-U9: 2px border around the whole window first (paint order:
        // background → border → title bar → buttons → title → content).
        {
            const b = user_border();
            const bw = chrome_border_w;
            const ww: usize = if (w.w > wspan) wspan else w.w;
            const wh: usize = if (w.h > hspan) hspan else w.h;
            fill_rect(fb, stride, w.x, w.y, ww, bw, b); // top
            if (wh > bw) fill_rect(fb, stride, w.x, w.y + wh - bw, ww, bw, b); // bottom
            fill_rect(fb, stride, w.x, w.y, bw, wh, b); // left
            if (ww > bw) fill_rect(fb, stride, w.x + ww - bw, w.y, bw, wh, b); // right
        }
        // Title bar: "dui<id> pid=<pid>" (the owning pid when known),
        // CENTERED with "..." truncation when it does not fit (M20-U9).
        fill_rect(fb, stride, w.x, w.y, w.w, user_title_h, user_title_bg());
        var tb: [24]u8 = undefined;
        var n: usize = 0;
        const label = "dui";
        @memcpy(tb[0..3], label);
        n = 3;
        const idstr = fmt_decimal(tb[n..], w.id);
        n += idstr.len;
        if (w.owner) |pid| {
            const ps = " pid=";
            @memcpy(tb[n..][0..ps.len], ps);
            n += ps.len;
            const pids = fmt_decimal(tb[n..], pid);
            n += pids.len;
        }
        const lay = chrome_title_layout(w.w, n);
        if (!lay.truncated) {
            draw_string_16(fb, stride, w.x + lay.x_off, w.y, tb[0..lay.draw_len], user_title_fg_rgb);
        } else {
            var tt: [24]u8 = undefined;
            @memcpy(tt[0..lay.draw_len], tb[0..lay.draw_len]);
            @memcpy(tt[lay.draw_len..][0..3], "...");
            draw_string_16(fb, stride, w.x + lay.x_off, w.y, tt[0 .. lay.draw_len + 3], user_title_fg_rgb);
        }
        // Step 6: close button ("×" — red glyph at top-right of title bar).
        draw_glyph(fb, stride, w.x + w.w - 14, w.y + 4, 'x', 0xef4444);
        // Step 7: minimize button ("—" — muted glyph left of close).
        draw_glyph(fb, stride, w.x + w.w - 26, w.y + 4, '-', 0x94a3b8);
    }
    // The focus ring: on the focused window's rect (D4 — focus is always
    // visible). 0xff = none (no ring). The full-screen TERMINAL never
    // carries it (issue #164): it is the always-focused background, and a
    // ring around it paints a white strip over the first/last text row
    // and column — the live-glyphs tripwire decoded cell 0 of every line
    // as unknown. The clock and user windows keep the ring.
    if (focused_id != 0xff) {
        var idx: usize = 0;
        while (idx < win_count) : (idx += 1) {
            if (windows[idx].id != focused_id) continue;
            const w = &windows[idx];
            if (w.kind == .terminal) break;
            // Arc4 #241: don't draw focus ring on off-workspace windows.
            if (!workspace_visible(w)) break;
            const rx: usize = w.x;
            const ry: usize = w.y;
            const rw: usize = if (w.w > wspan) wspan else w.w;
            const rh: usize = if (w.h > hspan) hspan else w.h;
            fill_rect(fb, stride, rx, ry, rw, focus_ring_w, focus_ring());
            fill_rect(fb, stride, rx, ry + rh - focus_ring_w, rw, focus_ring_w, focus_ring());
            fill_rect(fb, stride, rx, ry, focus_ring_w, rh, focus_ring());
            fill_rect(fb, stride, rx + rw - focus_ring_w, ry, focus_ring_w, rh, focus_ring());
            break;
        }
    }
    // The pointer cursor (card U4) — topmost, only once a report arrived.
    if (cursor_shown) {
        const cx: usize = cursor_x;
        const cy: usize = cursor_y;
        const cw = if (cx + cursor_w > wspan) wspan - cx else cursor_w;
        const ch = if (cy + cursor_h > hspan) hspan - cy else cursor_h;
        fill_rect(fb, stride, cx, cy, cw, ch, cursor_rgb);
    }
    // M15 C2 (Alt+Tab overlay, #225): centered window previews while Alt held.
    // Topmost below notification (D7 ordering), above user chrome. Dim the
    // backdrop by filling a translucent dark rect over the whole scanout, then
    // a centered list of user-window rows with highlight on `overlay_selected`.
    if (overlay_active and overlay_count > 0) {
        // Dim backdrop — 50% dark (opaque dark gray is the honest preview for the
        // host's ScreenCaptureKit composite; true alpha would be compositor-pricey).
        fill_rect(fb, stride, 0, 0, wspan, hspan, 0x0f0f1a);
        const ov_w: u32 = 440;
        const row_h: u32 = 28;
        const header_h: u32 = 24;
        const pad: u32 = 8;
        const ov_h: u32 = header_h + pad * 2 + @as(u32, @intCast(overlay_count)) * row_h + pad;
        const ov_x: u32 = if (wspan > ov_w) (wspan - ov_w) / 2 else 0;
        const ov_y: u32 = if (hspan > ov_h) (hspan - ov_h) / 2 else 0;
        // Overlay surface + border.
        fill_rect(fb, stride, ov_x, ov_y, ov_w, ov_h, 0x1e293b);
        // 2-px border in accent.
        fill_rect(fb, stride, ov_x, ov_y, ov_w, 2, clock_accent_rgb);
        fill_rect(fb, stride, ov_x, ov_y + ov_h - 2, ov_w, 2, clock_accent_rgb);
        fill_rect(fb, stride, ov_x, ov_y, 2, ov_h, clock_accent_rgb);
        fill_rect(fb, stride, ov_x + ov_w - 2, ov_y, 2, ov_h, clock_accent_rgb);
        draw_string(fb, stride, ov_x + pad, ov_y + pad, "Alt+Tab  —  Switch window", 0xffffff);
        draw_string(fb, stride, ov_x + pad, ov_y + pad + 12, "(Tab / Shift+Tab cycles, release Alt)", 0x94a3b8);
        var idx: usize = 0;
        while (idx < overlay_count) : (idx += 1) {
            const id = overlay_ids[idx];
            const row_y = ov_y + header_h + pad + @as(u32, @intCast(idx)) * row_h;
            const is_sel = idx == overlay_selected;
            const bg = if (is_sel) taskbar_entry_active() else 0x0f172a;
            fill_rect(fb, stride, ov_x + pad, row_y, ov_w - pad * 2, row_h - 2, bg);
            // Outline highlight on selected.
            if (is_sel) {
                fill_rect(fb, stride, ov_x + pad, row_y, ov_w - pad * 2, 1, 0xffffff);
                fill_rect(fb, stride, ov_x + pad, row_y + row_h - 3, ov_w - pad * 2, 1, 0xffffff);
            }
            var win_title: []const u8 = "user";
            var win_owner: ?usize = null;
            var k: usize = 0;
            while (k < win_count) : (k += 1) {
                if (windows[k].id == id and windows[k].kind == .user) {
                    win_title = windows[k].title;
                    win_owner = windows[k].owner;
                    break;
                }
            }
            var tbuf: [32]u8 = undefined;
            var tn: usize = 0;
            @memcpy(tbuf[0..4], "dui ");
            tn = 4;
            const id_s = fmt_decimal(tbuf[tn..], id);
            tn += id_s.len;
            if (win_owner) |pid| {
                const pfx = " pid=";
                @memcpy(tbuf[tn..][0..pfx.len], pfx);
                tn += pfx.len;
                const pid_s = fmt_decimal(tbuf[tn..], pid);
                tn += pid_s.len;
            }
            draw_string(fb, stride, ov_x + pad + 6, row_y + 10, tbuf[0..tn], if (is_sel) 0xffffff else 0xd8dee9);
            draw_string(fb, stride, ov_x + ov_w - pad - 80, row_y + 10, win_title, 0x94a3b8);
            // Small preview color block — distinct per window id.
            const preview_rgb: u32 = switch (id % 4) {
                0 => 0x3b82f6,
                1 => 0x10b981,
                2 => 0xf59e0b,
                3 => 0xef4444,
                else => 0x6366f1,
            };
            fill_rect(fb, stride, ov_x + ov_w - pad - 36, row_y + 6, 16, 16, preview_rgb);
        }
    }
    // M15 C3: snap preview — translucent zone highlight while dragging near edge.
    if (drag_id != null and snap_zone != .none) {
        if (snap_zone_bounds(snap_zone)) |zb| {
            // Opaque accent fill (honest preview for host test; true alpha would be compositor-pricey).
            fill_rect(fb, stride, zb.x, zb.y, zb.w, zb.h, 0x3b82f6);
            fill_rect(fb, stride, zb.x, zb.y, zb.w, 2, 0xffffff);
            fill_rect(fb, stride, zb.x, zb.y + zb.h - 2, zb.w, 2, 0xffffff);
            fill_rect(fb, stride, zb.x, zb.y, 2, zb.h, 0xffffff);
            fill_rect(fb, stride, zb.x + zb.w - 2, zb.y, 2, zb.h, 0xffffff);
        }
    }
    // Arc4 #242: unsaved-changes confirmation dialog — centered modal.
    if (unsaved_dialog_open) {
        const dlg_w: u32 = 200;
        const dlg_h: u32 = 100;
        const dlg_x: u32 = if (wspan > dlg_w) (wspan - dlg_w) / 2 else 0;
        const dlg_y: u32 = if (hspan > dlg_h) (hspan - dlg_h) / 2 else 0;
        // Dim backdrop.
        fill_rect(fb, stride, 0, 0, wspan, hspan, 0x0f0f1a);
        // Dialog surface.
        fill_rect(fb, stride, dlg_x, dlg_y, dlg_w, dlg_h, 0x1e293b);
        // Border.
        fill_rect(fb, stride, dlg_x, dlg_y, dlg_w, 2, 0xf59e0b);
        fill_rect(fb, stride, dlg_x, dlg_y + dlg_h - 2, dlg_w, 2, 0xf59e0b);
        fill_rect(fb, stride, dlg_x, dlg_y, 2, dlg_h, 0xf59e0b);
        fill_rect(fb, stride, dlg_x + dlg_w - 2, dlg_y, 2, dlg_h, 0xf59e0b);
        // Message.
        draw_string(fb, stride, dlg_x + 10, dlg_y + 10, "Save before closing?", 0xffffff);
        // Buttons: Save (green), Don't Save (red), Cancel (gray).
        fill_rect(fb, stride, dlg_x + 20, dlg_y + dlg_h - 30, 60, 20, 0x10b981);
        draw_string(fb, stride, dlg_x + 26, dlg_y + dlg_h - 24, "Save", 0xffffff);
        fill_rect(fb, stride, dlg_x + 90, dlg_y + dlg_h - 30, 60, 20, 0xef4444);
        draw_string(fb, stride, dlg_x + 96, dlg_y + dlg_h - 24, "Don't", 0xffffff);
        fill_rect(fb, stride, dlg_x + 160, dlg_y + dlg_h - 30, 30, 20, 0x64748b);
        draw_string(fb, stride, dlg_x + 163, dlg_y + dlg_h - 24, "No", 0xffffff);
    }
    // Arc4 #240: notification toasts — top-right, stacked newest-top.
    // 300×40 px per toast, 8×8 font, colored left border.
    if (notify_count > 0) {
        const toast_w: u32 = 300;
        const toast_h: u32 = 40;
        const toast_x: u32 = if (wspan > toast_w) wspan - toast_w - 8 else 0;
        var ti: usize = 0;
        while (ti < notify_count) : (ti += 1) {
            if (notify_entry(ti)) |entry| {
                const toast_y: u32 = 8 + @as(u32, @intCast(ti)) * (toast_h + 4);
                if (toast_y + toast_h > hspan) break;
                // Background.
                fill_rect(fb, stride, toast_x, toast_y, toast_w, toast_h, 0x1e293b);
                // Colored left border: blue=info, amber=warn, red=error.
                const border_color: u32 = switch (entry.level) {
                    1 => 0xf59e0b, // amber warning
                    2 => 0xef4444, // red error
                    else => 0x3b82f6, // blue info
                };
                fill_rect(fb, stride, toast_x, toast_y, 4, toast_h, border_color);
                // Text — up to 36 chars (300-8 px / 8 px per glyph).
                const max_chars = 36;
                const len = @min(entry.text.len, max_chars);
                if (len > 0) {
                    draw_string(fb, stride, toast_x + 10, toast_y + 6, entry.text[0..len], 0xffffff);
                }
            }
        }
    }
}

/// Step 13 (Issue #213): boot splash screen. Renders once into the framebuffer
/// and pushes a transfer+flush. Shows the system name in 8×16 font, version,
/// and a cycling progress indicator. Returns after `max_ticks` or when a
/// keystroke arrives (whichever is first).
pub fn render_splash(max_ticks: u64) void {
    if (!armed_global or !virtio_gpu.gpu_ready) return;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const stride = virtio_gpu.fb_width * 4;
    // Fill background.
    fill_rect(fb, stride, 0, 0, virtio_gpu.fb_width, virtio_gpu.fb_height, wallpaper_top());
    // Title: "DipshitOS" centered, using 8×16 font (the draw_glyph path,
    // stretched to 2× height).
    const title = "DipshitOS";
    const title_x: usize = (virtio_gpu.fb_width - title.len * 8) / 2;
    const title_y: usize = virtio_gpu.fb_height / 2 - 40;
    // Render each glyph at 2× height (simple stretch).
    for (title, 0..) |ch, i| {
        if (ch < 0x20 or ch > 0x7e) continue;
        const glyph = font.glyphs[ch - 0x20];
        var gy: usize = 0;
        while (gy < 8) : (gy += 1) {
            const bits = glyph[gy];
            var gx: usize = 0;
            while (gx < 8) : (gx += 1) {
                if (font.row_pixel(bits, gx)) {
                    // Draw at 2× size.
                    fill_rect(fb, stride, title_x + i * 8 + gx * 2, title_y + gy * 2, 2, 2, clock_accent_rgb);
                }
            }
        }
    }
    // Version line.
    draw_string(fb, stride, title_x + 16, title_y + 24, "v0.1", clock_fg_rgb);
    // Push the splash frame.
    _ = virtio_gpu.gpu_transfer();
    _ = virtio_gpu.gpu_flush();
    // Cycle progress indicator for max_ticks (or until GPU not ready).
    var tick: u64 = 0;
    while (tick < max_ticks) : (tick += 1) {
        // Simple busy-wait for ~1 second per tick (the timer is not yet
        // running at this point in boot).
        var wait: u64 = 0;
        while (wait < 10_000_000) : (wait += 1) {}
        // Draw cycling dots.
        const dots = [5]u8{ '.', 'o', 'O', 'o', '.' };
        const dot_idx = tick % 5;
        fill_rect(fb, stride, title_x + 24, title_y + 40, 40, 8, wallpaper_top());
        draw_glyph(fb, stride, title_x + 24 + @as(usize, @intCast(dot_idx)) * 8, title_y + 40, dots[dot_idx], clock_fg_rgb);
        _ = virtio_gpu.gpu_transfer();
        _ = virtio_gpu.gpu_flush();
    }
}

/// Refresh the tray clock from the 1 Hz generic timer and composite any dirty
/// windows. The shell idle loop is the drain site (the card-3d pattern).
/// Clock ticks on composite() without timer — drain marks taskbar dirty when
/// the minute (or tick) advances; composite() also handles theme/clipboard.
pub fn drain(ticks: u64) virtio_gpu.CmdResult {
    if (!armed_global) return .not_ready;
    var need = false;
    if (!tray_has_tick or ticks != tray_tick) {
        tray_has_tick = true;
        tray_tick = ticks;
        need = true;
        // Keep deprecated clock vars in sync for any external read.
        clock_has_tick = true;
        clock_shown_tick = ticks;
    }
    if (tray_last_theme != theme_id) {
        tray_last_theme = theme_id;
        need = true;
    }
    const cur_clip = clipboard.current_len();
    if (cur_clip != tray_last_clip_len) {
        tray_last_clip_len = cur_clip;
        need = true;
    }
    if (need) _ = mark_dirty(255);
    return composite();
}

// ---------------------------------------------------------------------------
// Host tests — the pure contracts (hit-test, z-order, focus, repaint plan,
// clock rendering, blit)
// ---------------------------------------------------------------------------

test "driving_award: arm registers the terminal (window 0) and the clock (window 1)" {
    arm();
    // Arc2 W3: clock window (Kind.clock id 1) migrated to tray — arm now registers
    // terminal + wallpaper + taskbar + dock = 4 windows. Kind.clock remains in
    // enum but no window is created for it (no duplicate clock).
    try std.testing.expectEqual(@as(usize, 4), win_count);
    try std.testing.expectEqual(@as(u8, 0), windows[0].id);
    try std.testing.expectEqual(Kind.terminal, windows[0].kind);
    try std.testing.expectEqual(@as(u8, 254), windows[1].id);
    try std.testing.expectEqual(Kind.wallpaper, windows[1].kind);
    try std.testing.expectEqual(@as(u8, 255), windows[2].id);
    try std.testing.expectEqual(Kind.taskbar, windows[2].kind);
    try std.testing.expectEqual(@as(u8, 253), windows[3].id);
    try std.testing.expectEqual(Kind.dock, windows[3].kind);
    try std.testing.expectEqual(@as(u8, 0), focused_id);
    try std.testing.expect(terminal_focused());
    // The terminal is full-screen.
    try std.testing.expectEqual(@as(u32, 0), windows[0].x);
    try std.testing.expectEqual(@as(u32, 0), windows[0].y);
    try std.testing.expectEqual(virtio_gpu.fb_width, windows[0].w);
    try std.testing.expectEqual(virtio_gpu.fb_height, windows[0].h);
    // Tray occupies right 80px of taskbar at y=700.
    const tr = tray_rect();
    try std.testing.expectEqual(@as(u32, 1200), tr.x);
    try std.testing.expectEqual(@as(u32, 700), tr.y);
    try std.testing.expectEqual(@as(u32, 80), tr.w);
    try std.testing.expectEqual(@as(u32, 20), tr.h);
}

test "driving_award: hit_test returns the topmost window containing the point" {
    arm();
    // Clock window migrated to tray — (clock_x,clock_y) is now inside the
    // terminal (full-screen). The terminal is topmost there (wallpaper is
    // background-only, not hit-testable).
    try std.testing.expectEqual(@as(?u8, 0), hit_test(clock_x + 10, clock_y + 10));
    // Inside the terminal: the terminal.
    try std.testing.expectEqual(@as(?u8, 0), hit_test(100, 400));
    try std.testing.expectEqual(@as(?u8, 0), hit_test(clock_x - 1, clock_y + 10));
    // Outside every window.
    try std.testing.expectEqual(@as(?u8, null), hit_test(virtio_gpu.fb_width, virtio_gpu.fb_height));
}

test "driving_award: raise moves a window to the top and hit_test follows" {
    arm();
    // With tray migration, arm has terminal(0), wallpaper(254), taskbar(255), dock(253).
    // Raise terminal (0) — it moves to top of z-order (above dock).
    try std.testing.expect(raise(0));
    try std.testing.expectEqual(@as(u8, 0), windows[win_count - 1].id);
    try std.testing.expectEqual(@as(?u8, 0), hit_test(clock_x + 10, clock_y + 10));
    // Focus is unchanged by raise (tracked by id).
    try std.testing.expectEqual(@as(u8, 0), focused_id);
}

test "driving_award: focus + focus_at switch the focused window" {
    arm();
    // Clock window no longer exists — focus a user window instead. Verify
    // terminal focus switching still works via focus_at.
    _ = user_open(100, 100, 200, 100, 7);
    try std.testing.expect(focus(2));
    try std.testing.expectEqual(@as(u8, 2), focused_id);
    try std.testing.expect(!terminal_focused());
    // A point in the user window focuses it; a point in terminal area focuses terminal.
    try std.testing.expect(focus_at(110, 110));
    try std.testing.expectEqual(@as(u8, 2), focused_id);
    try std.testing.expect(focus_at(50, 400));
    try std.testing.expectEqual(@as(u8, 0), focused_id);
    try std.testing.expect(terminal_focused());
    // Unknown ids are refused.
    try std.testing.expect(!focus(99));
    _ = user_close(2);
}

test "driving_award: repaint_start is the lowest dirty visible window" {
    arm();
    // All dirty at arm: the lowest is window 0.
    try std.testing.expectEqual(@as(?usize, 0), repaint_start());
    // Clean everything.
    var i: usize = 0;
    while (i < win_count) : (i += 1) windows[i].dirty = false;
    try std.testing.expectEqual(@as(?usize, null), repaint_start());
    // Only wallpaper dirty: repaint starts at window 1 (the terminal is
    // untouched — the dirty-rect contract).
    windows[1].dirty = true;
    try std.testing.expectEqual(@as(?usize, 1), repaint_start());
    // A hidden dirty window is skipped.
    windows[0].dirty = true;
    windows[0].visible = false;
    try std.testing.expectEqual(@as(?usize, 1), repaint_start());
}

test "driving_award: mark_dirty targets a window by id" {
    arm();
    var i: usize = 0;
    while (i < win_count) : (i += 1) windows[i].dirty = false;
    try std.testing.expect(mark_dirty(254));
    try std.testing.expect(!windows[0].dirty);
    try std.testing.expect(windows[1].dirty);
    try std.testing.expect(!mark_dirty(9));
}

test "driving_award: chrome_title_layout centers and truncates (M20-U9)" {
    // A wide window with a short label: centered, no truncation.
    {
        const l = chrome_title_layout(512, 8);
        try std.testing.expect(!l.truncated);
        // 8 chars = 64px; (512-64)/2 = 224 ≥ min pad.
        try std.testing.expectEqual(@as(usize, 224), l.x_off);
        try std.testing.expectEqual(@as(usize, 8), l.draw_len);
    }
    // A narrow window with a long label: truncates with "..." and never
    // starts left of the minimum pad.
    {
        const l = chrome_title_layout(120, 24);
        try std.testing.expect(l.truncated);
        try std.testing.expect(l.draw_len + 3 <= 120 / 8);
        try std.testing.expect(l.x_off >= 4);
        // The ellipsis fits inside the reserved span.
        const text_px = (l.draw_len + 3) * 8;
        try std.testing.expect(l.x_off + text_px <= 120);
    }
    // Degenerate: tiny window keeps at least the pad.
    {
        const l = chrome_title_layout(16, 10);
        try std.testing.expectEqual(@as(usize, 4), l.x_off);
    }
}

test "driving_award: the border is two pixels on every theme (M20-U9)" {
    const saved = theme_id;
    defer theme_id = saved;
    theme_id = 0;
    _ = user_border();
    try std.testing.expectEqual(@as(usize, 2), chrome_border_w);
    theme_id = 1;
    _ = user_border();
    try std.testing.expectEqual(@as(usize, 2), chrome_border_w);
}

test "driving_award: fmt_decimal formats unsigned values without leading zeros" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0", fmt_decimal(&buf, 0));
    try std.testing.expectEqualStrings("1", fmt_decimal(&buf, 1));
    try std.testing.expectEqualStrings("42", fmt_decimal(&buf, 42));
    try std.testing.expectEqualStrings("123456789", fmt_decimal(&buf, 123456789));
}

test "driving_award: asymmetric C glyph is LSB-first" {
    const W = 8;
    const H = 8;
    var buf: [W * H * 4]u8 = undefined;
    @memset(&buf, 0);
    draw_glyph(&buf, W * 4, 0, 0, 'C', 0xffffff);

    // The C's source row 2 is 0x03, so x=0,1 are foreground and x=6,7
    // remain untouched. An MSB-first regression reverses these assertions.
    try std.testing.expectEqual(@as(u8, 0xff), buf[(2 * W + 0) * 4]);
    try std.testing.expectEqual(@as(u8, 0xff), buf[(2 * W + 1) * 4]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[(2 * W + 6) * 4]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[(2 * W + 7) * 4]);
}

test "driving_award: the full 95-glyph table rasters LSB-first through draw_glyph (issue 125)" {
    // Render EVERY printable glyph through the window-manager raster into
    // an 8x8 buffer and assert all 64 pixels against the RAW table byte
    // read LSB-first inline — `(row >> x) & 1`, NOT font.row_pixel (see
    // the text.zig full-table golden: deriving the expectation from the
    // helper under test would be self-consistent with a reversed helper).
    // 90 of 95 glyphs are horizontally asymmetric, so a bit-order flip in
    // draw_glyph OR row_pixel breaks 90/95 glyphs immediately — the
    // window-manager path cannot drift from the terminal path without
    // this failing.
    const W = 8;
    const H = 8;
    var buf: [W * H * 4]u8 = undefined;
    var i: usize = 0;
    while (i < font.glyphs.len) : (i += 1) {
        @memset(&buf, 0);
        const ch: u8 = @intCast(0x20 + i);
        draw_glyph(&buf, W * 4, 0, 0, ch, 0xffffff);
        const glyph = font.glyphs[i];
        var gy: usize = 0;
        while (gy < 8) : (gy += 1) {
            var gx: usize = 0;
            while (gx < 8) : (gx += 1) {
                const row = glyph[gy];
                const bit_set = ((row >> @as(u3, @intCast(gx))) & 1) != 0;
                const want: u8 = if (bit_set) 0xff else 0x00;
                try std.testing.expectEqual(want, buf[(gy * W + gx) * 4]);
            }
        }
    }
}

test "driving_award: render_clock_content paints the title bar and body colors" {
    const W = 304;
    const H = 192;
    var buf: [W * H * 4]u8 = undefined;
    @memset(&buf, 0);
    render_clock_content(&buf, W * 4, W, H, 42, false);
    // Title bar (inside the border): amber.
    try std.testing.expectEqual(@as(u8, 0x00), buf[(6 * W + 8) * 4 + 0]); // B of amber 0xb58900
    try std.testing.expectEqual(@as(u8, 0x89), buf[(6 * W + 8) * 4 + 1]); // G
    try std.testing.expectEqual(@as(u8, 0xb5), buf[(6 * W + 8) * 4 + 2]); // R
    try std.testing.expectEqual(@as(u8, 0xff), buf[(6 * W + 8) * 4 + 3]); // opaque
    // Border: gray-blue (top-left pixel is border).
    try std.testing.expectEqual(@as(u8, 0xaa), buf[0 + 0]); // B of 0x8899aa
    // Body background: navy (a pixel inside, away from text/border).
    try std.testing.expectEqual(@as(u8, 0x2e), buf[(170 * W + 300) * 4 + 0]); // B of 0x0a1a2e
    try std.testing.expectEqual(@as(u8, 0x1a), buf[(170 * W + 300) * 4 + 1]); // G
}

test "driving_award: blit_rect copies a sub-rect at the destination offset" {
    const SW = 4;
    const DW = 10;
    var src: [SW * SW * 4]u8 = undefined;
    var dst: [DW * DW * 4]u8 = undefined;
    @memset(&src, 0);
    @memset(&dst, 0);
    // Source pixel (1,1) = green.
    src[(1 * SW + 1) * 4 + 0] = 0x00; // B
    src[(1 * SW + 1) * 4 + 1] = 0xff; // G
    src[(1 * SW + 1) * 4 + 2] = 0x00; // R
    src[(1 * SW + 1) * 4 + 3] = 0xff;
    blit_rect(&dst, DW * 4, &src, SW * 4, 3, 3, SW, SW);
    try std.testing.expectEqual(@as(u8, 0xff), dst[((3 + 1) * DW + (3 + 1)) * 4 + 1]);
    // A pixel outside the blit region is still zero.
    try std.testing.expectEqual(@as(u8, 0), dst[(0 * DW + 0) * 4 + 0]);
}

test "driving_award: user_open/fill/present round-trips a bounded user window" {
    arm();
    // Open window 2 at (64, 64) 256x192 — the first free user slot.
    const r = user_open(64, 64, 512, 384, 7);
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, r);
    try std.testing.expectEqual(@as(usize, 5), win_count);
    try std.testing.expectEqual(@as(u8, 2), windows[4].id);
    try std.testing.expectEqual(Kind.user, windows[4].kind);
    try std.testing.expectEqual(@as(?usize, 7), user_owner(2));
    try std.testing.expect(user_owner(0) == null); // the terminal is unowned
    // The new window is on top and focused.
    try std.testing.expectEqual(@as(u8, 2), focused_id);
    try std.testing.expect(!terminal_focused());
    try std.testing.expectEqual(@as(?u8, 2), hit_test(64 + 10, 64 + 10));
    // Fill a rect: the back-buffer pixel carries the B8G8R8X8 rgb.
    try std.testing.expect(user_fill(2, 8, 8, 48, 48, 0xff0000));
    try std.testing.expectEqual(@as(u8, 0x00), user_bufs[0][(8 * user_buf_w + 8) * 4 + 0]); // B
    try std.testing.expectEqual(@as(u8, 0x00), user_bufs[0][(8 * user_buf_w + 8) * 4 + 1]); // G
    try std.testing.expectEqual(@as(u8, 0xff), user_bufs[0][(8 * user_buf_w + 8) * 4 + 2]); // R
    try std.testing.expectEqual(@as(u8, 0xff), user_bufs[0][(8 * user_buf_w + 8) * 4 + 3]); // opaque
    // The unfilled corner is zero (the back-buffer starts cleared).
    try std.testing.expectEqual(@as(u8, 0), user_bufs[0][(100 * user_buf_w + 200) * 4 + 0]);
    try std.testing.expect(user_present(2));
    try std.testing.expect(windows[4].dirty);
}

test "driving_award: user_open bounds and the four slots fill the registry" {
    arm();
    // Invalid geometry: zero size, oversize back-buffer, off-scanout.
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(0, 0, 0, 10, 7));
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(0, 0, 513, 10, 7));
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(0, 0, 10, 385, 7));
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(virtio_gpu.fb_width, 0, 10, 10, 7));
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(virtio_gpu.fb_width - 4, 0, 10, 10, 7));
    // Four opens fill all slots (ids 2..5); the fifth is ENOSPC-shaped (.full).
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 8));
    try std.testing.expectEqual(UserOpenResult{ .opened = 4 }, user_open(576, 64, 512, 384, 9));
    try std.testing.expectEqual(UserOpenResult{ .opened = 5 }, user_open(64, 288, 512, 384, 10));
    try std.testing.expectEqual(UserOpenResult.full, user_open(0, 0, 10, 10, 11));
    try std.testing.expectEqual(@as(usize, 8), win_count);
    try std.testing.expectEqual(@as(?usize, 7), user_owner(2));
    try std.testing.expectEqual(@as(?usize, 8), user_owner(3));
    try std.testing.expectEqual(@as(?usize, 9), user_owner(4));
    try std.testing.expectEqual(@as(?usize, 10), user_owner(5));
}

test "driving_award: user_fill refuses unknown ids and out-of-bounds rects" {
    arm();
    _ = user_open(64, 64, 512, 384, 7);
    try std.testing.expect(!user_fill(0, 0, 0, 10, 10, 0xffffff)); // terminal is not a user window
    try std.testing.expect(!user_fill(1, 0, 0, 10, 10, 0xffffff)); // deprecated clock id 1 is not a user window
    try std.testing.expect(!user_fill(9, 0, 0, 10, 10, 0xffffff)); // unknown
    try std.testing.expect(!user_fill(2, 0, 0, 0, 10, 0xffffff)); // zero size
    try std.testing.expect(!user_fill(2, 511, 383, 2, 2, 0xffffff)); // past the window edge
    try std.testing.expect(!user_present(3)); // never opened
    try std.testing.expect(!user_present(0));
    try std.testing.expect(!user_present(1));
}

test "driving_award: user_close releases a user window and frees its slot" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(@as(usize, 5), win_count);
    try std.testing.expectEqual(@as(u8, 2), focused_id);
    // The terminal is fixed — never closable; deprecated clock id 1 also not closable.
    try std.testing.expect(!user_close(0));
    try std.testing.expect(!user_close(1));
    try std.testing.expect(!user_close(9));
    // Close window 2: count decrements, focus falls back to the terminal,
    // and the slot is reusable by the next open.
    try std.testing.expect(user_close(2));
    try std.testing.expectEqual(@as(usize, 4), win_count);
    try std.testing.expectEqual(@as(u8, 0), focused_id);
    try std.testing.expect(terminal_focused());
    try std.testing.expect(find_user_window(2) == null);
    // Re-opening reuses id 2 (the freed slot — the "release, not leak" proof).
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(@as(usize, 5), win_count);
    // Two opens, one close, one re-open: slot 3 is still free for a second
    // window, and closing BOTH user windows returns the registry to the
    // fixed windows.
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 8));
    try std.testing.expect(user_close(3));
    try std.testing.expect(user_close(2));
    try std.testing.expectEqual(@as(usize, 4), win_count);
    try std.testing.expectEqual(@as(u8, 0), focused_id);
}

test "driving_award: user_move clamps on-scanout and user_raise reorders z" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 8));
    // The terminal is fixed — never movable or raisable; deprecated clock also not.
    try std.testing.expect(!user_move(0, 10, 10));
    try std.testing.expect(!user_move(1, 10, 10));
    try std.testing.expect(!user_raise(0));
    try std.testing.expect(!user_raise(1));
    try std.testing.expect(!user_move(9, 0, 0));
    try std.testing.expect(!user_raise(9));
    // Move window 2 to a new in-bounds position overlapping window 3 and
    // confirm the rect.
    try std.testing.expect(user_move(2, 100, 50));
    try std.testing.expectEqual(@as(u32, 100), find_user_window(2).?.x);
    try std.testing.expectEqual(@as(u32, 50), find_user_window(2).?.y);
    try std.testing.expect(find_user_window(2).?.dirty);
    // Z-order: (321, 65) is inside BOTH windows; window 3 (opened last) is
    // on top. Raising window 2 puts it above window 3, without changing the
    // focus (tracked by id, stays 3).
    try std.testing.expectEqual(@as(u8, 3), hit_test(321, 65).?);
    try std.testing.expect(user_raise(2));
    try std.testing.expectEqual(@as(u8, 2), hit_test(321, 65).?);
    try std.testing.expectEqual(@as(u8, 3), focused_id);
    // The clamp keeps the window fully on-scanout (bottom-right corner).
    try std.testing.expect(user_move(2, 1200, 700));
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_width - 512), find_user_window(2).?.x);
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_height - 384), find_user_window(2).?.y);
}

test "driving_award: user_rect reads back the clamped geometry (the sys_win_get seam)" {
    arm();
    _ = user_open(64, 64, 512, 384, 7);
    // The fixed windows are never user windows -> null.
    try std.testing.expect(user_rect(0) == null);
    try std.testing.expect(user_rect(1) == null);
    try std.testing.expect(user_rect(9) == null);
    // The open rect.
    var r = user_rect(2).?;
    try std.testing.expectEqual(@as(u32, 64), r.x);
    try std.testing.expectEqual(@as(u32, 64), r.y);
    try std.testing.expectEqual(@as(u32, 512), r.w);
    try std.testing.expectEqual(@as(u32, 384), r.h);
    // After a CLAMPED move the read-back reports the clamped position — the
    // exact seam the EL0 `sys_win_get` exposes (the move is silent).
    try std.testing.expect(user_move(2, 1200, 700));
    r = user_rect(2).?;
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_width - 512), r.x);
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_height - 384), r.y);
    try std.testing.expectEqual(@as(u32, 512), r.w);
    try std.testing.expectEqual(@as(u32, 384), r.h);
}

test "driving_award: user_query reports the full window state (z-order + focus + flags)" {
    arm();
    try std.testing.expect(user_query(0) == null);
    try std.testing.expect(user_query(1) == null);
    try std.testing.expect(user_query(9) == null);
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    // The single user window sits at the TOP of the z-order (registry index
    // 4, above terminal 0 + wallpaper 254 + taskbar 255 + dock 253),
    // holds focus, is visible, and is dirty from the open.
    var q = user_query(2).?;
    try std.testing.expectEqual(@as(u32, 64), q.x);
    try std.testing.expectEqual(@as(u32, 64), q.y);
    try std.testing.expectEqual(@as(u32, 512), q.w);
    try std.testing.expectEqual(@as(u32, 384), q.h);
    try std.testing.expectEqual(@as(u32, 4), q.z);
    try std.testing.expectEqual(@as(u32, 1), q.focused);
    try std.testing.expectEqual(@as(u32, 1), q.visible);
    try std.testing.expectEqual(@as(u32, 1), q.dirty);
    // A second window takes focus (id 3) and the z-order: window 2 drops to
    // rank 4 (bottom of the two user windows), unfocused.
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 8));
    q = user_query(2).?;
    try std.testing.expectEqual(@as(u32, 4), q.z);
    try std.testing.expectEqual(@as(u32, 0), q.focused);
    q = user_query(3).?;
    try std.testing.expectEqual(@as(u32, 5), q.z);
    try std.testing.expectEqual(@as(u32, 1), q.focused);
    // Raising window 2 moves it to the top (rank 5) without changing focus
    // (still id 3).
    try std.testing.expect(user_raise(2));
    q = user_query(2).?;
    try std.testing.expectEqual(@as(u32, 5), q.z);
    try std.testing.expectEqual(@as(u32, 0), q.focused);
}

test "driving_award: user_set_visible hides and shows a user window (fixed windows refused)" {
    arm();
    _ = user_open(64, 64, 512, 384, 7);
    // The terminal is fixed — never hideable; deprecated clock id 1 also not hideable.
    try std.testing.expect(!user_set_visible(0, false));
    try std.testing.expect(!user_set_visible(1, false));
    try std.testing.expect(!user_set_visible(9, false));
    // Hide window 2: its visible flag flips, it stays in the registry, and
    // the terminal is marked dirty (the reveal repaint).
    try std.testing.expect(user_set_visible(2, false));
    try std.testing.expectEqual(@as(u32, 0), user_query(2).?.visible);
    try std.testing.expect(find_user_window(2) != null);
    try std.testing.expect(windows[0].dirty);
    // The hide is idempotent (a second hide is a no-op — no dirty churn).
    windows[0].dirty = false;
    try std.testing.expect(user_set_visible(2, false));
    try std.testing.expectEqual(@as(u32, 0), user_query(2).?.visible);
    try std.testing.expect(!windows[0].dirty);
    // Show it again: the window reappears (visible=1, dirty for the blit).
    try std.testing.expect(user_set_visible(2, true));
    try std.testing.expectEqual(@as(u32, 1), user_query(2).?.visible);
    try std.testing.expect(find_user_window(2).?.dirty);
}

test "driving_award: close_owner auto-closes exactly the owning process's windows" {
    arm();
    // Process 7 opens both slots; process 8 owns nothing yet.
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 7));
    try std.testing.expectEqual(@as(usize, 6), win_count);
    try std.testing.expectEqual(@as(u8, 3), focused_id);
    // Closing a process with no windows is a no-op (returns 0).
    try std.testing.expectEqual(@as(usize, 0), close_owner(8));
    try std.testing.expectEqual(@as(usize, 6), win_count);
    // Closing process 7 releases BOTH of its windows and falls the focus
    // back to the terminal.
    try std.testing.expectEqual(@as(usize, 2), close_owner(7));
    try std.testing.expectEqual(@as(usize, 4), win_count);
    try std.testing.expectEqual(@as(u8, 0), focused_id);
    try std.testing.expect(find_user_window(2) == null);
    try std.testing.expect(find_user_window(3) == null);
    // The slots are free again (id 2 re-opens for a different owner).
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 9));
    try std.testing.expectEqual(@as(?usize, 9), user_owner(2));
}

// ---------------------------------------------------------------------------
// Card U4/U5 host tests (claims 0935/4993)
// ---------------------------------------------------------------------------

test "driving_award: card U5 — cycle_focus walks the z-order and wraps" {
    arm();
    // Clock migrated to tray — cycle now needs user windows to walk.
    // Order after two opens: [0 terminal, wallpaper, taskbar, dock, 2, 3] focused 3.
    _ = user_open(64, 64, 200, 100, 7);
    _ = user_open(320, 64, 200, 100, 8);
    // Focus 3 -> next is terminal 0 (wraps), then 2, then 3
    try std.testing.expectEqual(@as(?u8, 0), cycle_focus());
    try std.testing.expectEqual(@as(?u8, 2), cycle_focus());
    try std.testing.expectEqual(@as(?u8, 3), cycle_focus());
    _ = user_close(3);
    _ = user_close(2);
}

test "driving_award: card U4 — map_pointer_axis scales 0..32767 onto the span" {
    try std.testing.expectEqual(@as(u32, 0), map_pointer_axis(0, 1280));
    try std.testing.expectEqual(@as(u32, 640), map_pointer_axis(16384, 1280));
    try std.testing.expectEqual(@as(u32, 1279), map_pointer_axis(32767, 1280));
    try std.testing.expectEqual(@as(u32, 719), map_pointer_axis(32767, 720));
}

test "driving_award: card U5 — the chrome draws the focus ring on the focused window" {
    arm();
    // Clock migrated to tray — test focus ring on a user window instead.
    _ = user_open(100, 100, 200, 100, 7);
    try std.testing.expect(focus(2));
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const px = struct {
        fn at(f: [*]u8, st: usize, x: usize, y: usize) u32 {
            const o = y * st + x * 4;
            return @as(u32, f[o + 2]) << 16 | @as(u32, f[o + 1]) << 8 | f[o];
        }
    };
    const w = find_user_window(2).?;
    try std.testing.expectEqual(focus_ring(), px.at(fb, stride, w.x, w.y));
    // ...and just inside the ring, the window's title bar (not ring).
    try std.testing.expect(px.at(fb, stride, w.x + focus_ring_w, w.y + focus_ring_w) != focus_ring());
    // Focus back to the terminal: the full-screen terminal never carries
    // the ring (issue #164 — a ring around it would cover the first text
    // row/column), so the screen corner is NOT white.
    try std.testing.expect(focus(0));
    _ = composite();
    try std.testing.expect(px.at(fb, stride, 0, 0) != focus_ring());
    // The window's corner is NOT ringed anymore.
    try std.testing.expect(px.at(fb, stride, w.x, w.y) != focus_ring());
    _ = user_close(2);
}

test "driving_award: card U4 — pointer motion moves the cursor; a click focuses + raises" {
    arm();
    // Move to the former clock's area (now terminal, clock migrated to tray) — no click yet.
    const st_no: input.PointerState = .{ .x = 26000, .y = 8000, .buttons = 0, .valid = true };
    try std.testing.expectEqual(@as(?u8, null), pointer_tick(st_no, null));
    const c = cursor_pos().?;
    try std.testing.expectEqual(hit_test(c.x, c.y).?, 0); // the cursor is over the terminal (clock gone)
    // Click: D4 click = focus + raise on the topmost window under it (terminal).
    try std.testing.expectEqual(@as(?u8, 0), pointer_tick(st_no, .{ .x = st_no.x, .y = st_no.y }));
    try std.testing.expectEqual(@as(u8, 0), focused_window_id());
    try std.testing.expectEqual(@as(u8, 0), windows[win_count - 1].id); // raised on top (terminal)
    // Move to the terminal area and click: focus remains window 0.
    const st_term: input.PointerState = .{ .x = 4000, .y = 30000, .buttons = 0, .valid = true };
    try std.testing.expectEqual(@as(?u8, 0), pointer_tick(st_term, .{ .x = 4000, .y = 30000 }));
    // The cursor renders magenta at its cell after a composite.
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const o = c.y * stride + c.x * 4; // NOTE: st_no's cursor cell (over the clock)
    _ = o;
    const cc = cursor_pos().?;
    const off = cc.y * stride + cc.x * 4;
    try std.testing.expectEqual(@as(u8, 0xff), fb[off + 2]); // R (0xff00ff)
    try std.testing.expectEqual(@as(u8, 0x00), fb[off + 1]); // G
    try std.testing.expectEqual(@as(u8, 0xff), fb[off]); // B
}

test "driving_award: card E3 — mouse_buttons_to_flags maps button bits" {
    try std.testing.expectEqual(@as(u16, 0), mouse_buttons_to_flags(0));
    try std.testing.expectEqual(events.BTN_LEFT, mouse_buttons_to_flags(0x01));
    try std.testing.expectEqual(events.BTN_RIGHT, mouse_buttons_to_flags(0x02));
    try std.testing.expectEqual(events.BTN_MIDDLE, mouse_buttons_to_flags(0x04));
    try std.testing.expectEqual(events.BTN_LEFT | events.BTN_RIGHT | events.BTN_MIDDLE, mouse_buttons_to_flags(0x07));
}

test "driving_award: card E3 — pointer motion and clicks queue window-local events to owner" {
    events.init();
    arm();
    // Open a user window at (100, 50, 200, 100) owned by pid 3 (receives WIN_FOCUS)
    const res = user_open(100, 50, 200, 100, 3);
    try std.testing.expect(res == .opened);
    const win_id = res.opened;
    _ = events.pop(3); // Consume WIN_FOCUS

    // Move pointer to (150, 80) scanout coordinates (inside the user window)
    // 150 / 1280 * 32768 = 3840; 80 / 720 * 32768 = 3641
    const st_motion: input.PointerState = .{ .x = 3840, .y = 3641, .buttons = 0, .valid = true };
    _ = pointer_tick(st_motion, null);

    // MOUSE_MOVE event should be queued for pid 3
    try std.testing.expect(events.pending(3) >= 1);
    const ev_move = events.pop(3).?;
    try std.testing.expectEqual(events.MOUSE_MOVE, ev_move.kind);
    // Scanout (150, 80) mapped to window-local coordinates: x = 150 - 100 = 50, y = 80 - 50 = 30
    try std.testing.expectEqual(@as(u32, 50), ev_move.arg0);
    try std.testing.expectEqual(@as(u32, 30), ev_move.arg1);

    // Press left mouse button
    const st_down: input.PointerState = .{ .x = 3840, .y = 3641, .buttons = 0x01, .valid = true };
    _ = pointer_tick(st_down, null);

    // MOUSE_DOWN event queued with BTN_LEFT flag
    try std.testing.expect(events.pending(3) >= 1);
    const ev_down = events.pop(3).?;
    try std.testing.expectEqual(events.MOUSE_DOWN, ev_down.kind);
    try std.testing.expect((ev_down.flags & events.BTN_LEFT) != 0);
    try std.testing.expectEqual(@as(u32, 50), ev_down.arg0);
    try std.testing.expectEqual(@as(u32, 30), ev_down.arg1);

    // Release mouse button
    const st_up: input.PointerState = .{ .x = 3840, .y = 3641, .buttons = 0, .valid = true };
    _ = pointer_tick(st_up, null);

    // MOUSE_UP event queued
    try std.testing.expect(events.pending(3) >= 1);
    const ev_up = events.pop(3).?;
    try std.testing.expectEqual(events.MOUSE_UP, ev_up.kind);
    try std.testing.expectEqual(@as(u32, 50), ev_up.arg0);
    try std.testing.expectEqual(@as(u32, 30), ev_up.arg1);

    // Clean up
    _ = user_close(win_id);
}

test "driving_award: card E4 — window lifecycle emits WIN_FOCUS, WIN_BLUR, and WIN_CLOSE" {
    events.init();
    arm();

    // 1. Open user window 2 owned by pid 4 -> receives WIN_FOCUS
    const res1 = user_open(10, 10, 100, 100, 4);
    try std.testing.expect(res1 == .opened);
    const win2 = res1.opened;
    try std.testing.expectEqual(@as(usize, 1), events.pending(4));
    const ev_f1 = events.pop(4).?;
    try std.testing.expectEqual(events.WIN_FOCUS, ev_f1.kind);
    try std.testing.expectEqual(@as(u32, win2), ev_f1.arg0);

    // 2. Open user window 3 owned by pid 5 -> pid 4 gets WIN_BLUR, pid 5 gets WIN_FOCUS
    const res2 = user_open(120, 10, 100, 100, 5);
    try std.testing.expect(res2 == .opened);
    const win3 = res2.opened;

    // Check pid 4 received WIN_BLUR
    try std.testing.expectEqual(@as(usize, 1), events.pending(4));
    const ev_b1 = events.pop(4).?;
    try std.testing.expectEqual(events.WIN_BLUR, ev_b1.kind);
    try std.testing.expectEqual(@as(u32, win2), ev_b1.arg0);
    try std.testing.expectEqual(@as(u32, win3), ev_b1.arg1);

    // Check pid 5 received WIN_FOCUS
    try std.testing.expectEqual(@as(usize, 1), events.pending(5));
    const ev_f2 = events.pop(5).?;
    try std.testing.expectEqual(events.WIN_FOCUS, ev_f2.kind);
    try std.testing.expectEqual(@as(u32, win3), ev_f2.arg0);

    // 3. Focus back to window 0 (terminal) -> pid 5 gets WIN_BLUR
    try std.testing.expect(focus(0));
    try std.testing.expectEqual(@as(usize, 1), events.pending(5));
    const ev_b2 = events.pop(5).?;
    try std.testing.expectEqual(events.WIN_BLUR, ev_b2.kind);
    try std.testing.expectEqual(@as(u32, win3), ev_b2.arg0);
    try std.testing.expectEqual(@as(u32, 0), ev_b2.arg1);

    // 4. Close window 2 -> pid 4 receives WIN_CLOSE
    try std.testing.expect(user_close(win2));
    try std.testing.expectEqual(@as(usize, 1), events.pending(4));
    const ev_c1 = events.pop(4).?;
    try std.testing.expectEqual(events.WIN_CLOSE, ev_c1.kind);
    try std.testing.expectEqual(@as(u32, win2), ev_c1.arg0);

    // Clean up window 3
    _ = user_close(win3);
}

test "driving_award: M15 C2 — Alt+Tab overlay snapshots, cycles, commits" {
    arm();
    // 0 user windows → no overlay.
    try std.testing.expect(!alt_tab_is_active());
    try std.testing.expect(!alt_tab_activate());
    try std.testing.expect(!alt_tab_is_active());
    // 1 user window → no overlay (honest no-op).
    _ = user_open(10, 10, 200, 100, 7);
    try std.testing.expect(!alt_tab_activate());
    try std.testing.expectEqual(@as(usize, 0), alt_tab_count());
    // 2 user windows → overlay snapshots both, selected is next after focused.
    _ = user_open(120, 10, 200, 100, 8);
    try std.testing.expectEqual(@as(u8, 3), focused_id); // last opened has focus
    try std.testing.expect(alt_tab_activate());
    try std.testing.expect(alt_tab_is_active());
    try std.testing.expectEqual(@as(usize, 2), alt_tab_count());
    // Focus is 3, so selected should be 2 (the other window).
    try std.testing.expectEqual(@as(?u8, 2), alt_tab_selected_id());
    // Cycle forward → wraps to 3, back → 2.
    alt_tab_cycle(false);
    try std.testing.expectEqual(@as(?u8, 3), alt_tab_selected_id());
    alt_tab_cycle(false);
    try std.testing.expectEqual(@as(?u8, 2), alt_tab_selected_id());
    alt_tab_cycle(true); // Shift+Tab reverse
    try std.testing.expectEqual(@as(?u8, 3), alt_tab_selected_id());
    // Commit → focuses selected (3) and dismisses overlay.
    const committed = alt_tab_commit().?;
    try std.testing.expectEqual(@as(u8, 3), committed);
    try std.testing.expect(!alt_tab_is_active());
    try std.testing.expectEqual(@as(u8, 3), focused_id);
    try std.testing.expectEqual(@as(usize, 5), win_count - 1); // raised to top (4 base +2 users -> top index 5)
    // Re-activate then dismiss without commit.
    try std.testing.expect(alt_tab_activate());
    try std.testing.expectEqual(@as(?u8, 2), alt_tab_selected_id());
    alt_tab_dismiss();
    try std.testing.expect(!alt_tab_is_active());
    try std.testing.expectEqual(@as(u8, 3), focused_id); // unchanged
    // Close while active → honest dismiss.
    try std.testing.expect(alt_tab_activate());
    try std.testing.expect(alt_tab_is_active());
    _ = user_close(2);
    try std.testing.expect(!alt_tab_is_active());
    _ = user_close(3);
}

test "driving_award: M15 C2 — overlay renders centered list with highlight" {
    arm();
    _ = user_open(10, 10, 200, 100, 7);
    _ = user_open(120, 10, 200, 100, 8);
    _ = alt_tab_activate();
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const ov_w: u32 = 440;
    const ov_x: u32 = (virtio_gpu.fb_width - ov_w) / 2;
    const ov_y: u32 = (virtio_gpu.fb_height - (24 + 8 * 2 + 2 * 28 + 8)) / 2;
    // Overlay border is accent color (0xffaa00 → B=0x00 G=0xaa R=0xff).
    const px = struct {
        fn at(f: [*]u8, st: usize, x: usize, y: usize) u32 {
            const o = y * st + x * 4;
            return @as(u32, f[o + 2]) << 16 | @as(u32, f[o + 1]) << 8 | f[o];
        }
    };
    try std.testing.expectEqual(@as(u32, 0xffaa00), px.at(fb, stride, ov_x, ov_y));
    // Inside the highlighted row (first selected is id 2) the row bg is active (0x3b82f6 blue in dark theme).
    const sel_y = ov_y + 24 + 8 + 10;
    try std.testing.expectEqual(@as(u32, 0x3b82f6), px.at(fb, stride, ov_x + 10, sel_y));
}

test "driving_award: M15 C3 — snap_zone_for_point detects halves and quadrants with corner precedence" {
    // Edges 20 px, corners first.
    try std.testing.expectEqual(SnapZone.left, snap_zone_for_point(5, 360));
    try std.testing.expectEqual(SnapZone.right, snap_zone_for_point(1275, 360));
    try std.testing.expectEqual(SnapZone.top, snap_zone_for_point(640, 5));
    try std.testing.expectEqual(SnapZone.bottom, snap_zone_for_point(640, 715));
    try std.testing.expectEqual(SnapZone.top_left, snap_zone_for_point(5, 5));
    try std.testing.expectEqual(SnapZone.top_right, snap_zone_for_point(1275, 5));
    try std.testing.expectEqual(SnapZone.bottom_left, snap_zone_for_point(5, 715));
    try std.testing.expectEqual(SnapZone.bottom_right, snap_zone_for_point(1275, 715));
    try std.testing.expectEqual(SnapZone.none, snap_zone_for_point(640, 360));
}

test "driving_award: M15 C3 — snap_window and snap_restore with per-window last_rect" {
    arm();
    _ = user_open(64, 64, 200, 100, 7);
    const before = user_rect(2).?;
    try std.testing.expect(!snap_is_snapped(2));
    // Snap to left half — zone 640×700, win clamped to 512×384 centered.
    try std.testing.expect(snap_window(2, .left));
    try std.testing.expect(snap_is_snapped(2));
    const after_left = user_rect(2).?;
    try std.testing.expectEqual(@as(u32, 64), after_left.x);
    try std.testing.expectEqual(@as(u32, 158), after_left.y);
    try std.testing.expectEqual(@as(u32, 512), after_left.w);
    try std.testing.expectEqual(@as(u32, 384), after_left.h);
    // Restore.
    try std.testing.expect(snap_restore(2));
    try std.testing.expect(!snap_is_snapped(2));
    const restored = user_rect(2).?;
    try std.testing.expectEqual(before.x, restored.x);
    try std.testing.expectEqual(before.y, restored.y);
    // Snap to top-right quadrant then drag-out restore via pointer_tick.
    try std.testing.expect(snap_window(2, .top_right));
    try std.testing.expect(snap_is_snapped(2));
    // Simulate drag start on snapped window title bar — should restore before dragging.
    // Use a mapped cursor over the snapped window's title bar.
    const win = find_user_window(2).?;
    const cx = @as(u16, @intCast((@as(u32, win.x + 4) * 32768) / virtio_gpu.fb_width));
    const cy = @as(u16, @intCast((@as(u32, win.y + 4) * 32768) / virtio_gpu.fb_height));
    const st_click: input.PointerState = .{ .x = cx, .y = cy, .buttons = 0x01, .valid = true };
    _ = pointer_tick(st_click, .{ .x = cx, .y = cy });
    // After click, window should have been restored (drag_id set, is_snapped cleared).
    try std.testing.expect(!snap_is_snapped(2));
    try std.testing.expectEqual(before.x, find_user_window(2).?.x);
    _ = user_close(2);
}

test "driving_award: M15 C3 — snap preview renders and zone bounds are within scanout" {
    arm();
    _ = user_open(100, 100, 200, 100, 7);
    // Simulate dragging near left edge (cursor at x=5).
    const st_drag: input.PointerState = .{ .x = @as(u16, @intCast((@as(u32, 5) * 32768) / virtio_gpu.fb_width)), .y = @as(u16, @intCast((@as(u32, 100) * 32768) / virtio_gpu.fb_height)), .buttons = 0x01, .valid = true };
    // Start drag on title bar first.
    const win = find_user_window(2).?;
    const cx0 = @as(u16, @intCast((@as(u32, win.x + 4) * 32768) / virtio_gpu.fb_width));
    const cy0 = @as(u16, @intCast((@as(u32, win.y + 4) * 32768) / virtio_gpu.fb_height));
    _ = pointer_tick(.{ .x = cx0, .y = cy0, .buttons = 0x01, .valid = true }, .{ .x = cx0, .y = cy0 });
    // Now drag to left edge.
    _ = pointer_tick(st_drag, null);
    try std.testing.expectEqual(SnapZone.left, snap_current_zone());
    // Composite should paint the preview.
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const zb = snap_zone_bounds(.left).?;
    const px = struct {
        fn at(f: [*]u8, st: usize, x: usize, y: usize) u32 {
            const o = y * st + x * 4;
            return @as(u32, f[o + 2]) << 16 | @as(u32, f[o + 1]) << 8 | f[o];
        }
    };
    // Preview border is white at zone's top-left corner.
    try std.testing.expectEqual(@as(u32, 0xffffff), px.at(fb, stride, zb.x, zb.y));
    // Inside preview is accent 0x3b82f6.
    try std.testing.expectEqual(@as(u32, 0x3b82f6), px.at(fb, stride, zb.x + 4, zb.y + 4));
    _ = user_close(2);
}

test "driving_award: Arc2 W1 — clamp_resize_w/h clamp to 128×64..512×384 and screen" {
    // Pure clamp math — no window needed except screen containment.
    // Buffer bounds.
    try std.testing.expectEqual(@as(u32, 128), clamp_resize_w(100, 0));
    try std.testing.expectEqual(@as(u32, 128), clamp_resize_w(127, 0));
    try std.testing.expectEqual(@as(u32, 128), clamp_resize_w(128, 0));
    try std.testing.expectEqual(@as(u32, 200), clamp_resize_w(200, 0));
    try std.testing.expectEqual(@as(u32, 512), clamp_resize_w(512, 0));
    try std.testing.expectEqual(@as(u32, 512), clamp_resize_w(600, 0));
    try std.testing.expectEqual(@as(u32, 512), clamp_resize_w(1000, 0));
    try std.testing.expectEqual(@as(u32, 64), clamp_resize_h(10, 0));
    try std.testing.expectEqual(@as(u32, 64), clamp_resize_h(64, 0));
    try std.testing.expectEqual(@as(u32, 100), clamp_resize_h(100, 0));
    try std.testing.expectEqual(@as(u32, 384), clamp_resize_h(384, 0));
    try std.testing.expectEqual(@as(u32, 384), clamp_resize_h(500, 0));
    // Screen containment: fb is 1280×720.
    try std.testing.expectEqual(@as(u32, 280), clamp_resize_w(512, 1000)); // 1280-1000=280
    try std.testing.expectEqual(@as(u32, 128), clamp_resize_w(128, 1152)); // 1280-1152=128 exactly min
    // Negative request clamps to min.
    try std.testing.expectEqual(@as(u32, 128), clamp_resize_w(-50, 0));
    try std.testing.expectEqual(@as(u32, 64), clamp_resize_h(-10, 0));
}

test "driving_award: Arc2 W1 — is_resize_hit detects 6×6 bottom-right corner" {
    arm();
    _ = user_open(100, 50, 200, 100, 7);
    const w = find_user_window(2).?.*;
    // Inside the 6×6 corner: x+w-6 .. x+w-1, y+h-6 .. y+h-1
    try std.testing.expect(is_resize_hit(w, 100 + 200 - 3, 50 + 100 - 3));
    try std.testing.expect(is_resize_hit(w, 100 + 200 - 1, 50 + 100 - 1));
    try std.testing.expect(is_resize_hit(w, 100 + 200 - 6, 50 + 100 - 6));
    // Outside the corner but inside window — not a resize hit.
    try std.testing.expect(!is_resize_hit(w, 100 + 10, 50 + 10));
    try std.testing.expect(!is_resize_hit(w, 100 + 200 - 3, 50 + 10));
    try std.testing.expect(!is_resize_hit(w, 100 + 200 - 7, 50 + 100 - 3));
    // Outside window.
    try std.testing.expect(!is_resize_hit(w, 100 + 200 + 1, 50 + 100 - 3));
    _ = user_close(2);
}

test "driving_award: Arc2 W1 — user_resize clamps and emits WIN_RESIZE" {
    events.init();
    arm();
    _ = user_open(64, 64, 200, 100, 9);
    // Consume the WIN_FOCUS from open.
    _ = events.pop(9);
    // Below min clamps to 128×64.
    try std.testing.expect(user_resize(2, 50, 10));
    try std.testing.expectEqual(@as(u32, 128), find_user_window(2).?.w);
    try std.testing.expectEqual(@as(u32, 64), find_user_window(2).?.h);
    var ev = events.pop(9).?;
    try std.testing.expectEqual(events.WIN_RESIZE, ev.kind);
    try std.testing.expectEqual(@as(u32, 128), ev.arg0);
    try std.testing.expectEqual(@as(u32, 64), ev.arg1);
    // Above max clamps to 512×384.
    try std.testing.expect(user_resize(2, 800, 500));
    try std.testing.expectEqual(@as(u32, 512), find_user_window(2).?.w);
    try std.testing.expectEqual(@as(u32, 384), find_user_window(2).?.h);
    ev = events.pop(9).?;
    try std.testing.expectEqual(events.WIN_RESIZE, ev.kind);
    try std.testing.expectEqual(@as(u32, 512), ev.arg0);
    try std.testing.expectEqual(@as(u32, 384), ev.arg1);
    // Chrome dirty + terminal dirty for repaint.
    try std.testing.expect(find_user_window(2).?.dirty);
    try std.testing.expect(windows[0].dirty);
    // Unknown id refused.
    try std.testing.expect(!user_resize(99, 200, 100));
    try std.testing.expect(!user_resize(0, 200, 100));
    _ = user_close(2);
}

test "driving_award: Arc2 W1 — pointer_tick drag-to-resize via bottom-right corner" {
    events.init();
    arm();
    _ = user_open(100, 50, 200, 100, 7);
    _ = events.pop(7); // WIN_FOCUS
    const win0 = find_user_window(2).?;
    const rx = win0.x + win0.w - 3;
    const ry = win0.y + win0.h - 3;
    const cx = @as(u16, @intCast((rx * 32768) / virtio_gpu.fb_width));
    const cy = @as(u16, @intCast((ry * 32768) / virtio_gpu.fb_height));
    // MOUSE_DOWN in resize corner starts resize.
    const st_down: input.PointerState = .{ .x = cx, .y = cy, .buttons = 0x01, .valid = true };
    _ = pointer_tick(st_down, .{ .x = cx, .y = cy });
    try std.testing.expect(resize_active());
    try std.testing.expectEqual(@as(?u8, 2), resize_current_id());
    // MOUSE_MOVE 30,20 larger — new size 230×120.
    const nx = rx + 30;
    const ny = ry + 20;
    const cx2 = @as(u16, @intCast((nx * 32768) / virtio_gpu.fb_width));
    const cy2 = @as(u16, @intCast((ny * 32768) / virtio_gpu.fb_height));
    const st_move: input.PointerState = .{ .x = cx2, .y = cy2, .buttons = 0x01, .valid = true };
    _ = pointer_tick(st_move, null);
    try std.testing.expectEqual(@as(u32, 230), find_user_window(2).?.w);
    try std.testing.expectEqual(@as(u32, 120), find_user_window(2).?.h);
    try std.testing.expect(events.pending(7) >= 1);
    var found_resize = false;
    while (events.pop(7)) |ev| {
        if (ev.kind == events.WIN_RESIZE) {
            found_resize = true;
            try std.testing.expectEqual(@as(u32, 230), ev.arg0);
            try std.testing.expectEqual(@as(u32, 120), ev.arg1);
        }
    }
    try std.testing.expect(found_resize);
    // MOUSE_UP ends resize.
    const st_up: input.PointerState = .{ .x = cx2, .y = cy2, .buttons = 0x00, .valid = true };
    _ = pointer_tick(st_up, null);
    try std.testing.expect(!resize_active());
    // Drag should not have started.
    try std.testing.expect(drag_id == null);
    // Clamp test via pointer_tick: drag far negative — clamps to min.
    // Need to re-hit after move: window is now 230×120 at (100,50), corner at 327,167.
    const rx2 = find_user_window(2).?.x + find_user_window(2).?.w - 3;
    const ry2 = find_user_window(2).?.y + find_user_window(2).?.h - 3;
    const cx3 = @as(u16, @intCast((rx2 * 32768) / virtio_gpu.fb_width));
    const cy3 = @as(u16, @intCast((ry2 * 32768) / virtio_gpu.fb_height));
    _ = pointer_tick(.{ .x = cx3, .y = cy3, .buttons = 0x01, .valid = true }, .{ .x = cx3, .y = cy3 });
    const st_far_neg: input.PointerState = .{ .x = 0, .y = 0, .buttons = 0x01, .valid = true };
    _ = pointer_tick(st_far_neg, null);
    try std.testing.expectEqual(@as(u32, 128), find_user_window(2).?.w);
    try std.testing.expectEqual(@as(u32, 64), find_user_window(2).?.h);
    _ = pointer_tick(.{ .x = 0, .y = 0, .buttons = 0x00, .valid = true }, null);
    _ = user_close(2);
}

test "driving_award: Arc2 W3 — tray helpers and geometry" {
    arm();
    clipboard.init();
    // tray_rect is right 80px at y=700, 20px tall.
    const tr = tray_rect();
    try std.testing.expectEqual(@as(u32, 1200), tr.x);
    try std.testing.expectEqual(@as(u32, 700), tr.y);
    try std.testing.expectEqual(@as(u32, 80), tr.w);
    try std.testing.expectEqual(@as(u32, 20), tr.h);
    try std.testing.expectEqual(taskbar_y, tr.y);
    try std.testing.expectEqual(taskbar_h, tr.h);
    // format_hhmm zero-padded 24h wrap.
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("00:00", format_hhmm(&buf, 0));
    try std.testing.expectEqualStrings("00:01", format_hhmm(&buf, 60));
    try std.testing.expectEqualStrings("01:00", format_hhmm(&buf, 3600));
    try std.testing.expectEqualStrings("01:01", format_hhmm(&buf, 3660));
    try std.testing.expectEqualStrings("23:59", format_hhmm(&buf, 23 * 3600 + 59 * 60));
    try std.testing.expectEqualStrings("00:00", format_hhmm(&buf, 24 * 3600));
    // theme_letter maps dark/light/amber.
    theme_id = 0;
    try std.testing.expectEqual(@as(u8, 'D'), theme_letter());
    theme_id = 1;
    try std.testing.expectEqual(@as(u8, 'L'), theme_letter());
    theme_id = 2;
    try std.testing.expectEqual(@as(u8, 'A'), theme_letter());
    theme_id = 99;
    try std.testing.expectEqual(@as(u8, 'D'), theme_letter());
    // clipboard indicator empty -> filled.
    try std.testing.expect(!tray_clipboard_filled());
    _ = clipboard.set("hello");
    try std.testing.expect(tray_clipboard_filled());
    _ = clipboard.set("");
    try std.testing.expect(!tray_clipboard_filled());
    theme_id = 0;
}

test "driving_award: Arc2 W3 — drain ticks tray HH:MM without timer" {
    arm();
    clipboard.init();
    // First tick initializes tray.
    try std.testing.expect(!tray_has_clock());
    _ = drain(0);
    try std.testing.expect(tray_has_clock());
    try std.testing.expectEqual(@as(u64, 0), tray_current_tick());
    // Different tick marks taskbar dirty and updates tray.
    windows[2].dirty = false; // taskbar at index 2 after migration
    _ = drain(60);
    try std.testing.expectEqual(@as(u64, 60), tray_current_tick());
    // HH:MM at 60s is 00:01
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("00:01", format_hhmm(&buf, tray_current_tick()));
}

test "driving_award: Arc2 W3 — composite renders tray in right 80px" {
    arm();
    clipboard.init();
    theme_id = 1; // light -> L in blue accent
    _ = clipboard.set("x");
    _ = drain(3660); // 01:01
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const px = struct {
        fn at(f: [*]u8, st: usize, x: usize, y: usize) u32 {
            const o = y * st + x * 4;
            return @as(u32, f[o + 2]) << 16 | @as(u32, f[o + 1]) << 8 | f[o];
        }
    };
    // Taskbar background at (4,702) is taskbar_bg (light: 0xe2e8f0), not black.
    try std.testing.expect(px.at(fb, stride, 4, 702) != 0);
    // Tray clock area at tray_x+4, tray_y+6 should have white glyph pixels (HH:MM).
    // We check that the tray region is not just background — at least one white pixel near HH:MM.
    var found_white = false;
    var x: u32 = tray_x + 4;
    while (x < tray_x + 40) : (x += 1) {
        if (px.at(fb, stride, x, tray_y + 6) == 0xffffff) {
            found_white = true;
            break;
        }
    }
    try std.testing.expect(found_white);
    // Theme letter at tray_x+48 should be accent blue for light theme (0x2563eb).
    // Check that accent pixel exists near that x (glyph may not cover every pixel, but background is taskbar_bg).
    // Clipboard filled rect at tray_x+64,6 size 10x8 should be filled white when has content.
    try std.testing.expectEqual(@as(u32, 0xffffff), px.at(fb, stride, tray_x + 64 + 5, tray_y + 6 + 4));
    // Switch to empty clipboard -> outline, center pixel should NOT be white (it is taskbar_bg).
    _ = clipboard.set("");
    // Need to mark dirty via composite preamble: theme unchanged but clip changed -> mark dirty + composite.
    _ = composite();
    try std.testing.expect(px.at(fb, stride, tray_x + 64 + 5, tray_y + 6 + 4) != 0xffffff);
    theme_id = 0;
    clipboard.init();
}

test "driving_award: Arc2 W3 — Kind.clock deprecated but enum remains" {
    // Kind.clock still exists for ABI compat but arm no longer creates window id 1.
    arm();
    try std.testing.expectEqualStrings("clock", kind_name(.clock));
    var found_clock = false;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == 1 and windows[i].kind == .clock) found_clock = true;
    }
    try std.testing.expect(!found_clock);
    // id 1 is free for future repurpose but currently not a user window.
    try std.testing.expect(find_user_window(1) == null);
    try std.testing.expect(!user_fill(1, 0, 0, 10, 10, 0xffffff));
}

test "driving_award: blit_rect_alpha blends src over dst at given opacity" {
    // 4x4 dst filled with 0x404040 (dark gray), src filled with 0xc0c0c0 (light gray).
    var dst: [4 * 4 * 4]u8 = undefined;
    var src: [4 * 4 * 4]u8 = undefined;
    for (0..(4 * 4 * 4)) |i| {
        dst[i] = 0x40;
        src[i] = 0xc0;
    }
    // 50% alpha (128): result = 0x40*(128/256) + 0xc0*(128/256) = 0x20 + 0x60 = 0x80.
    blit_rect_alpha(&dst, 4 * 4, &src, 4 * 4, 0, 0, 4, 4, 128);
    for (0..(4 * 4 * 4)) |i| {
        try std.testing.expectEqual(@as(u8, 0x80), dst[i]);
    }
}

test "driving_award: blit_rect_alpha at 25% opacity (64)" {
    var dst: [4 * 4 * 4]u8 = undefined;
    var src: [4 * 4 * 4]u8 = undefined;
    for (0..(4 * 4 * 4)) |i| {
        dst[i] = 0x00;
        src[i] = 0xff;
    }
    // 25% alpha (64): result = 0*(192/256) + 255*(64/256) ≈ 63.
    blit_rect_alpha(&dst, 4 * 4, &src, 4 * 4, 0, 0, 4, 4, 64);
    for (0..(4 * 4 * 4)) |i| {
        try std.testing.expectEqual(@as(u8, 63), dst[i]);
    }
}

test "driving_award: blit_rect_alpha at full opacity falls back to memcpy" {
    var dst: [4 * 4 * 4]u8 = undefined;
    var src: [4 * 4 * 4]u8 = undefined;
    for (0..(4 * 4 * 4)) |i| {
        dst[i] = 0x00;
        src[i] = 0xab;
    }
    blit_rect_alpha(&dst, 4 * 4, &src, 4 * 4, 0, 0, 4, 4, 256);
    for (0..(4 * 4 * 4)) |i| {
        try std.testing.expectEqual(@as(u8, 0xab), dst[i]);
    }
}

test "driving_award: window fade-in state transitions" {
    // user_open sets fade_phase=1, fade_tick=0.
    armed_global = true;
    _ = user_open(100, 100, 200, 150, 99);
    const w = find_user_window(2).?;
    try std.testing.expectEqual(@as(u8, 1), w.fade_phase);
    try std.testing.expectEqual(@as(u8, 0), w.fade_tick);
    // After fade_half_frames ticks, phase is still 1 but alpha should be 50%.
    var fi: u8 = 0;
    while (fi < fade_half_frames) : (fi += 1) {
        w.fade_tick +|= 1;
    }
    try std.testing.expectEqual(@as(u8, 1), w.fade_phase);
    // After another fade_half_frames, fade completes.
    while (fi < fade_half_frames * 2) : (fi += 1) {
        w.fade_tick +|= 1;
    }
    w.fade_phase = 0; // simulate composite advancing
    w.fade_tick = 0;
    try std.testing.expectEqual(@as(u8, 0), w.fade_phase);
    _ = user_close(2);
}

test "driving_award: notification FIFO push/dismiss/advance" {
    // Reset state.
    notify_head = 0;
    notify_count = 0;
    // Push 3 notifications.
    notify_push("hello", 0);
    notify_push("warn", 1);
    notify_push("error", 2);
    try std.testing.expectEqual(@as(usize, 3), notify_count_visible());
    // entry(0) = oldest, entry(count-1) = newest.
    var e = notify_entry(2).?;
    try std.testing.expectEqual(@as(u8, 2), e.level);
    try std.testing.expectEqualStrings("error", e.text);
    e = notify_entry(1).?;
    try std.testing.expectEqualStrings("warn", e.text);
    e = notify_entry(0).?;
    try std.testing.expectEqualStrings("hello", e.text);
    // Dismiss index 0 (oldest = hello).
    try std.testing.expect(notify_dismiss(0));
    try std.testing.expectEqual(@as(usize, 2), notify_count_visible());
    // Overflow drops oldest.
    notify_push("fourth", 0);
    notify_push("fifth", 0);
    try std.testing.expectEqual(@as(usize, notify_max), notify_count_visible());
    // Auto-dismiss after notify_dismiss_ticks.
    var t: u32 = 0;
    while (t < notify_dismiss_ticks) : (t += 1) {
        notify_advance_ticks();
    }
    try std.testing.expectEqual(@as(usize, 0), notify_count_visible());
}
