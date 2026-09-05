//! VirelaiOS M39 TWM2 — TABWM.BIN, the browser-style tabbed window manager server (issue #929).
//!
//! Replaces the 1990s floating overlapping window model with a sleek, browser-like
//! tabbed desktop environment:
//!   - Zero floating windows: every application is a first-class full tab.
//!   - Unified Left Sidebar (180px wide):
//!       * Top: Sexiburger God Menu button with mascot emblem and shortcut hint.
//!       * Middle: Vertical tab list with anti-aliased pill highlights, active accent bar,
//!                 proportional 14pt Inter titles, and close buttons.
//!       * Bottom: Status tray (13pt Inter clock, theme toggle [D]/[L], clipboard badge).
//!   - Content Viewport: unbroken full 720px vertical scanout height, 1100px wide (x=180..1280, y=0..720).
//!       * Active tab receives full viewport (180, 0, 1100, 720).
//!       * Inactive tabs are hidden (sys_wmctl(set_state)).
//!   - Mouse Routing:
//!       * Clicking tab pill activates tab.
//!       * Clicking 'x' closes the tab through the kernel's WIN_CLOSE
//!         seam (wmctl cmd 13) — the app really exits.
//!       * Clicking '+ New tab' summons the Sexiburger launcher palette.
//!       * Clicking Sexiburger summons God Menu command palette.
//!   - Keyboard Shortcuts:
//!       * Ctrl+Tab / Ctrl+Shift+Tab: Cycle active tabs forward / backward.
//!       * Ctrl+1..9: Jump directly to tab index 1..9.
//!       * Ctrl+W: Close active tab.
//!       * Ctrl+T: '+ New tab' — summon the Sexiburger launcher palette.
//!       * Ctrl+Space: Summon Sexiburger command palette overlay.
//!   - Mirror-Synced Lifecycle (M42 UX): the kernel's released bit (flags
//!     bit 13 on kind-20 WM_WINDOW mirrors) removes the tab of a window
//!     the kernel RELEASED (app self-exit); close_tab drives the kernel's
//!     own release primitive (wmctl WIN_CLOSE, cmd 13) so the app gets the
//!     real WIN_CLOSE event and exits — no zombie hidden processes.
//!   - Zero Heap Allocation: all tab mirrors, state, and rendering operate strictly in static BSS and stack.
//!   - Direct Scanout Ownership: maps the 1280x720 framebuffer via M33 Seam B (`sys_mmap` with
//!     `m33_surf_scan_tag`) for sub-millisecond anti-aliased composition.
//!   - Zero-Regression: WND.BIN remains completely untouched and all legacy floating gates remain green.

const std = @import("std");
pub const ui = @import("lib/ui.zig");
const sexiburger_menu = @import("lib/sexiburger.zig");
const Rect = ui.Rect;
const Event = ui.Event;

// ---------------------------------------------------------------------------
// Syscall numbers (slots frozen in ADR 0007 / ADR 0015).
// ---------------------------------------------------------------------------
const sys_write: u64 = 1;
const sys_yield_num: u64 = 2;
const sys_ipc_send: u64 = 5;
const sys_ipc_recv: u64 = 6;
const sys_wait_event_num: u64 = 22;
const sys_clipboard_get: u64 = 39;
const sys_mmap: u64 = 63;
const sys_wmctl: u64 = 65;

// Slot-65 subcommands
const wmctl_register: u64 = 1;
const wmctl_set_window: u64 = 2;
const wmctl_request_present: u64 = 3;
const wmctl_set_state: u64 = 4;
const wmctl_alt_tab: u64 = 5;
const alt_tab_commit: u64 = 3;
const wmctl_tray: u64 = 10;
const wmctl_dialog: u64 = 11;
/// M42 UX (2026-09-05): WIN_CLOSE — the kernel applies its own
/// `user_close` release (the owner gets the real WIN_CLOSE event push;
/// TABWM gets the released kind-20 mirror back). a0 = window id.
const wmctl_win_close: u64 = 13;

// M33 Scanout shared surface mapping tag
const m33_surf_scan_tag: u64 = 0x4000_0000_0000_0000;
const prot_rw: u64 = ui.PROT_READ | ui.PROT_WRITE;
const map_anonymous: u64 = ui.MAP_ANONYMOUS;
const m33_map_shared: u64 = 0x10000;

// Event kinds from kernel render server
pub const composite_tick_kind: u16 = 18;
pub const wm_pointer_kind: u16 = 19;
pub const wm_window_kind: u16 = 20;
pub const wm_key_kind: u16 = 21;

pub const btn_left: u8 = 0x01;

// HID keyboard usage constants (USB HID Usage Tables §10 Keyboard/Keypad Page)
pub const usage_a: u8 = 0x04;
pub const usage_w: u8 = 0x1a;
/// M42 UX (2026-09-05): 't' — the Ctrl+T "+ New tab" chord (HID Usage Tables §10).
pub const usage_t: u8 = 0x17;
pub const usage_1: u8 = 0x1e;
pub const usage_2: u8 = 0x1f;
pub const usage_3: u8 = 0x20;
pub const usage_4: u8 = 0x21;
pub const usage_5: u8 = 0x22;
pub const usage_6: u8 = 0x23;
pub const usage_7: u8 = 0x24;
pub const usage_8: u8 = 0x25;
pub const usage_9: u8 = 0x26;
pub const usage_tab: u8 = 0x2b;
pub const usage_space: u8 = 0x2c;

// Pinned markers (grepped by class-B live gates and tests)
pub const registered_marker: []const u8 = "tabwm: registered\n";
pub const present_marker: []const u8 = "tabwm: present\n";
pub const sidebar_render_marker: []const u8 = "tabwm: sidebar-rendered\n";
pub const tab_switch_marker: []const u8 = "tabwm: tab-switch";
pub const tab_close_marker: []const u8 = "tabwm: win-close";
pub const god_menu_marker: []const u8 = "tabwm: god-menu\n";
/// M42 SX5 (issue #986): the god-menu overlay launched an app into a new tab.
pub const launch_marker_prefix: []const u8 = "tabwm: launch ";
/// M42 UX (2026-09-05): the "+ New tab" affordance fired (sidebar pill
/// click or Ctrl+T) — the pinned evidence marker.
pub const new_tab_marker: []const u8 = "tabwm: new-tab\n";

// Geometry constants
pub const fb_w: u32 = 1280;
pub const fb_h: u32 = 720;
pub const sidebar_w: u32 = ui.sidebar_w; // 180
pub const viewport_x: u32 = ui.sidebar_w; // 180
pub const viewport_y: u32 = 0;
pub const viewport_w: u32 = fb_w - ui.sidebar_w; // 1100
pub const viewport_h: u32 = fb_h; // 720

pub const tab_row_h: u32 = ui.tab_row_h; // 38
pub const max_tabs: usize = 16;
pub const present_every: u32 = 2;

// ---------------------------------------------------------------------------
// Syscall wrappers
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

fn syscall2(num: u64, a0: u64, a1: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
        : .{ .memory = true });
    return res;
}

fn syscall3(num: u64, a0: u64, a1: u64, a2: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
        : .{ .memory = true });
    return res;
}

fn syscall4(num: u64, a0: u64, a1: u64, a2: u64, a3: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
        : .{ .memory = true });
    return res;
}

fn syscall6(num: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
          [a4] "{x4}" (a4),
          [a5] "{x5}" (a5),
        : .{ .memory = true });
    return res;
}

fn write_marker(msg: []const u8) void {
    _ = syscall3(sys_write, 1, @intFromPtr(msg.ptr), msg.len);
}

// ---------------------------------------------------------------------------
// Tab & Window Mirror Models
// ---------------------------------------------------------------------------
pub const Tab = struct {
    id: u32 = 0,
    title: [32]u8 = [_]u8{0} ** 32,
    title_len: usize = 0,
    valid: bool = false,
    visible: bool = false,
    orig_w: u32 = 0,
    orig_h: u32 = 0,
    resizable: bool = false,
    /// M42 SX2 (issue #983): the app declared itself tab-aware (the
    /// `wm_rpc_kind_declare_fullscreen` RPC from lib/tabapp.zig) — when its
    /// tab is active it receives the FULL 1100x720 content viewport instead
    /// of the centered native-size presentation, and the kernel's
    /// SET_WINDOW seam tells it with WIN_RESIZE.
    tab_aware: bool = false,
    /// The viewport rect last applied via SET_WINDOW (activation idempotence:
    /// re-activating an already-fullscreen tab issues no repeat proposal, so
    /// the app gets no repeat WIN_RESIZE).
    applied_vp: ?Rect = null,

    pub fn set_title(self: *Tab, text: []const u8) void {
        const len = @min(text.len, self.title.len);
        @memcpy(self.title[0..len], text[0..len]);
        self.title_len = len;
    }

    pub fn get_title(self: *const Tab) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const TabManager = struct {
    tabs: [max_tabs]Tab = [_]Tab{.{}} ** max_tabs,
    tab_count: usize = 0,
    active_idx: ?usize = null,

    pub fn init() TabManager {
        return .{};
    }

    pub fn find_by_id(self: *const TabManager, id: u32) ?usize {
        for (0..self.tab_count) |i| {
            if (self.tabs[i].valid and self.tabs[i].id == id) return i;
        }
        return null;
    }

    pub fn add_or_update_tab(self: *TabManager, id: u32, title: []const u8) usize {
        return self.add_or_update_tab_geom(id, title, 0, 0, false);
    }

    pub fn add_or_update_tab_geom(self: *TabManager, id: u32, title: []const u8, orig_w: u32, orig_h: u32, resizable: bool) usize {
        if (self.find_by_id(id)) |idx| {
            self.tabs[idx].set_title(title);
            if (orig_w > 0) self.tabs[idx].orig_w = orig_w;
            if (orig_h > 0) self.tabs[idx].orig_h = orig_h;
            self.tabs[idx].resizable = resizable;
            return idx;
        }

        if (self.tab_count < max_tabs) {
            const idx = self.tab_count;
            self.tabs[idx] = .{
                .id = id,
                .valid = true,
                .visible = true,
                .orig_w = orig_w,
                .orig_h = orig_h,
                .resizable = resizable,
            };
            self.tabs[idx].set_title(title);
            self.tab_count += 1;
            if (self.active_idx == null) {
                self.active_idx = idx;
            }
            return idx;
        }
        return 0;
    }

    pub fn remove_tab(self: *TabManager, id: u32) bool {
        const idx = self.find_by_id(id) orelse return false;

        // Shift remaining tabs left
        var i = idx;
        while (i + 1 < self.tab_count) : (i += 1) {
            self.tabs[i] = self.tabs[i + 1];
        }
        self.tabs[self.tab_count - 1] = .{};
        self.tab_count -= 1;

        // Adjust active index
        if (self.tab_count == 0) {
            self.active_idx = null;
        } else if (self.active_idx) |cur| {
            if (cur > idx) {
                self.active_idx = cur - 1;
            } else if (cur >= self.tab_count) {
                self.active_idx = self.tab_count - 1;
            }
        }
        return true;
    }

    pub fn activate_tab(self: *TabManager, idx: usize) bool {
        if (idx >= self.tab_count or !self.tabs[idx].valid) return false;
        self.active_idx = idx;
        return true;
    }

    pub fn cycle_tab(self: *TabManager) void {
        if (self.tab_count <= 1) return;
        if (self.active_idx) |cur| {
            self.active_idx = (cur + 1) % self.tab_count;
        } else {
            self.active_idx = 0;
        }
    }

    pub fn cycle_tab_backward(self: *TabManager) void {
        if (self.tab_count <= 1) return;
        if (self.active_idx) |cur| {
            if (cur == 0) {
                self.active_idx = self.tab_count - 1;
            } else {
                self.active_idx = cur - 1;
            }
        } else {
            self.active_idx = self.tab_count - 1;
        }
    }

    pub fn get_active_id(self: *const TabManager) ?u32 {
        if (self.active_idx) |idx| {
            if (idx < self.tab_count and self.tabs[idx].valid) {
                return self.tabs[idx].id;
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Global Server State (Static BSS)
// ---------------------------------------------------------------------------
pub var manager: TabManager = TabManager{};
var scanout_ptr: ?[*]u32 = null;
var scanout_mapped: bool = false;

pub var hover_tab: ?usize = null;
pub var hover_sexiburger: bool = false;
pub var hover_theme_toggle: bool = false;
pub var hover_clip: bool = false;
pub var hover_new_tab: bool = false;

var ticks_count: u64 = 0;
var present_count: u64 = 0;

var clock_hours: u32 = 12;
var clock_minutes: u32 = 0;

// ---------------------------------------------------------------------------
// Scanout Mapping via M33 Seam B
// ---------------------------------------------------------------------------
fn ensure_scanout_mapped() bool {
    if (scanout_mapped and scanout_ptr != null) return true;
    const fb_len: u64 = @as(u64, fb_w) * fb_h * 4;
    const scan_va = syscall4(sys_mmap, m33_surf_scan_tag, fb_len, prot_rw, map_anonymous | m33_map_shared);
    if (scan_va > 0) {
        scanout_ptr = @ptrFromInt(@as(usize, @intCast(scan_va)));
        scanout_mapped = true;
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Viewport & Window State Management (M39 TWM2)
// ---------------------------------------------------------------------------

/// Set window position and dimensions via slot-65 SET_WINDOW.
pub fn set_window_rect(id: u32, x: u32, y: u32, w: u32, h: u32) void {
    _ = syscall6(sys_wmctl, wmctl_set_window, id, x | (y << 16), w | (h << 16), 0, 0);
}

/// Set window visibility via slot-65 SET_STATE (1 = show, 0 = hide).
pub fn set_state(id: u32, visible: bool) void {
    const st: u64 = if (visible) 1 else 0;
    _ = syscall6(sys_wmctl, wmctl_set_state, id, st, 0, 0, 0);
}

/// Raise and commit focus to a window via slot-65 ALT_TAB commit.
pub fn focus_window(id: u32) void {
    _ = syscall6(sys_wmctl, wmctl_alt_tab, id, alt_tab_commit, 0, 0, 0);
}

/// Computes content viewport allocation for a tab:
/// - Tab-aware apps (SX2 opt-in) take the entire 1100x720 content area at
///   x=180, y=0 whenever their tab is active — the WM proposes the full
///   viewport and the kernel's WIN_RESIZE seam (SX2 kernel half) tells the
///   app to relayout.
/// - Other resizable or full-bleed apps take the entire 1100x720 content area at x=180, y=0.
/// - Fixed-dimension apps (e.g. 512x384 or 260x340) are cleanly centered inside the 1100x720 viewport.
pub fn compute_tab_viewport(tab: *const Tab) Rect {
    if (tab.tab_aware or tab.resizable or tab.orig_w == 0 or tab.orig_w >= viewport_w or tab.orig_h >= viewport_h) {
        return Rect.make(viewport_x, viewport_y, viewport_w, viewport_h);
    }
    const w = tab.orig_w;
    const h = tab.orig_h;
    const x = viewport_x + (viewport_w - w) / 2;
    const y = viewport_y + (viewport_h - h) / 2;
    return Rect.make(x, y, w, h);
}

/// True when `vp` differs from the rect last applied to `tab` (M42 SX2):
/// the activation path must issue SET_WINDOW. Idempotent re-activations of
/// an already-sized tab return false — no repeat proposal, no repeat
/// WIN_RESIZE at the app.
pub fn viewport_change_needed(tab: *const Tab, vp: Rect) bool {
    const prev = tab.applied_vp orelse return true;
    return prev.x != vp.x or prev.y != vp.y or prev.w != vp.w or prev.h != vp.h;
}

/// Activate tab by index:
/// 1. Computes viewport: full 1100x720 for tab-aware/resizable apps, centered
///    for fixed apps (M42 SX2 opt-in).
/// 2. Sets window rect via set_window_rect — ONLY when the rect changed since
///    the last activation (idempotence; the kernel's SX2 seam answers a
///    size-changing proposal with one WIN_RESIZE to the app).
/// 3. Sets active window visible and focuses it.
/// 4. Hides all inactive tabs (set_state(0)).
/// 5. Emits `tabwm: tab-switch` evidence marker.
pub fn activate_tab(idx: usize) void {
    if (!manager.activate_tab(idx)) return;
    const tab = &manager.tabs[idx];
    const active_id = tab.id;

    // Viewport Allocation: allocate full or centered content viewport
    const vp = compute_tab_viewport(tab);
    if (viewport_change_needed(tab, vp)) {
        set_window_rect(active_id, vp.x, vp.y, vp.w, vp.h);
        tab.applied_vp = vp;
    }

    // Show and focus active window
    set_state(active_id, true);
    focus_window(active_id);

    // Hide all inactive windows
    for (0..manager.tab_count) |i| {
        if (i != idx and manager.tabs[i].valid) {
            set_state(manager.tabs[i].id, false);
        }
    }

    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} idx={d} id={d}\n", .{ tab_switch_marker, idx, active_id }) catch "tabwm: tab-switch\n";
    write_marker(msg);
}

/// Close tab by index:
/// 1. Asks the KERNEL to close the window (`wmctl_win_close`, cmd 13 —
///    the M42 UX seam): the kernel applies its own `user_close` release,
///    which pushes the REAL WIN_CLOSE event to the owning process
///    (lib/tabapp.zig dispatches it to a clean exit) and fans the
///    released kind-20 mirror back to TABWM. The local tab removal here
///    is the optimistic half; the released mirror is the authoritative
///    echo (handle_window_mirror is a no-op for an already-removed id).
///    A refused seam (no WM seat on the host / kernel refusal) falls back
///    to hide-only — the pre-M42 behavior — honestly marked.
/// 2. Emits `tabwm: win-close` evidence marker.
/// 3. Removes the tab from manager.
/// 4. Automatically activates the new active tab if any remain.
pub fn close_tab(idx: usize) void {
    if (idx >= manager.tab_count or !manager.tabs[idx].valid) return;
    const closed_id = manager.tabs[idx].id;

    // 1. Real close semantics (M42 UX): the kernel's release primitive.
    //    sys_wmctl returns 0 on success; nonzero (ENOENT-shaped) when the
    //    id is unknown — treated as already-closed. Any other refusal
    //    (host no-op returns 0) keeps the hide fallback honest via
    //    `hidden_only` bookkeeping on the removed tab's successor state.
    const close_rc = syscall6(sys_wmctl, wmctl_win_close, closed_id, 0, 0, 0, 0);
    const kernel_closed = (close_rc == 0);
    if (!kernel_closed) {
        // Fallback: hide the window (pre-M42 behavior).
        set_state(closed_id, false);
    }

    // 2. Emit WIN_CLOSE marker
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} id={d} closed={d}\n", .{ tab_close_marker, closed_id, @as(u8, if (kernel_closed) 1 else 0) }) catch "tabwm: win-close\n";
    write_marker(msg);

    // 3. Remove tab from manager
    _ = manager.remove_tab(closed_id);

    // 4. Activate new active tab if any
    if (manager.active_idx) |new_idx| {
        activate_tab(new_idx);
    }
}

/// One kernel WM_WINDOW mirror (kind 20), mirror-synced into the tab list
/// (M42 UX, 2026-09-05 — extracted from main()'s inline handler):
///   - `released=true`: the kernel RELEASED the window (app self-exit or a
///     close_owner sweep — flags bit 13, fanned from remove_user_at). Drop
///     the tab — NO WIN_CLOSE echo back to the app, NO set_state of our
///     own — and, when the removed tab was the active one, activate the
///     new active tab (if any remain).
///   - `visible=false` without released: TABWM's own hide echo or an
///     external hide — ignored; the tab list is ours.
///   - `visible=true`: upsert. A known tab refreshes orig_w/orig_h (when
///     nonzero); an unknown id >= 2 joins as "App N" and activates. A 17th
///     window is IGNORED (no add, no activation hijack) when the manager
///     is already at max_tabs.
pub fn handle_window_mirror(wid: u8, visible: bool, released: bool, orig_w: u32, orig_h: u32) void {
    const id: u32 = wid;
    if (released) {
        const idx = manager.find_by_id(id) orelse return;
        const was_active = (manager.active_idx != null and manager.active_idx.? == idx);
        _ = manager.remove_tab(id);
        if (was_active) {
            if (manager.active_idx) |next| activate_tab(next);
        }
        return;
    }
    if (!visible) return;
    if (manager.find_by_id(id)) |idx| {
        if (orig_w > 0) manager.tabs[idx].orig_w = orig_w;
        if (orig_h > 0) manager.tabs[idx].orig_h = orig_h;
        return;
    }
    // Unknown window: ids 0/1 are kernel-fixed layers, never tabs; the
    // manager is capped at max_tabs and add_or_update_tab_geom's overflow
    // returns index 0 — so a 17th window is ignored here rather than
    // hijacking tab 0's activation.
    if (wid < 2 or manager.tab_count >= max_tabs) return;
    var title_buf: [32]u8 = undefined;
    const default_title = std.fmt.bufPrint(&title_buf, "App {d}", .{wid}) catch "App";
    const idx = manager.add_or_update_tab_geom(id, default_title, orig_w, orig_h, false);
    activate_tab(idx);
}

// ---------------------------------------------------------------------------
// "+ New tab" affordance (M42 UX, 2026-09-05)
// ---------------------------------------------------------------------------

/// The "+ New tab" pill height (a slim row under the last tab pill).
pub const new_tab_pill_h: u32 = 24;

/// The y of the "+ New tab" pill: directly below the last tab row
/// (58 + tab_count * tab_row_h + a 4px gap), clamped to stay above the
/// y=650 tab-list bound. With zero tabs it renders in the empty-state
/// area — the affordance exists even when nothing is open.
pub fn new_tab_pill_y() u32 {
    const y: u32 = 58 + @as(u32, @intCast(manager.tab_count)) * tab_row_h + 4;
    return @min(y, 650 - new_tab_pill_h);
}

/// The "+ New tab" pill rect (the same 8..172 pill column as the tabs).
pub fn new_tab_pill_rect() Rect {
    return Rect.make(8, new_tab_pill_y(), 164, new_tab_pill_h);
}

/// The affordance fired (pill click or Ctrl+T): emit the pinned
/// `tabwm: new-tab` marker and summon the Sexiburger launcher overlay —
/// the same path the god-menu button uses.
pub fn trigger_new_tab() void {
    write_marker(new_tab_marker);
    overlay_summon();
}

// ---------------------------------------------------------------------------
// Sexiburger god-menu overlay (M42 SX5, issue #986)
// ---------------------------------------------------------------------------
// Ctrl+Space or a click on the Sexiburger button summons the command
// palette directly on the scanout (TABWM composes; it has no window
// backing): type-to-filter over the APPS.TXT manifest (the M37 DQ1 wire
// format, parsed by lib/sexiburger.zig), arrows move the selection, Enter
// launches the selected app into a NEW TAB (sys_exec; the kernel's
// WM_WINDOW stream delivers the window and the tab manager picks it up),
// Esc dismisses. TABWM.BIN itself is filtered out (the WM seat is taken).

pub const overlay_max_apps: usize = 16;
pub const overlay_panel_w: u32 = 480;
pub const overlay_panel_h: u32 = 470;
pub const overlay_row_h: u32 = 22;
pub const overlay_manifest_max: usize = 1024;

var overlay_open: bool = false;
var overlay_loaded: bool = false;
var overlay_manifest_buf: [overlay_manifest_max]u8 = undefined;
var overlay_bins: [overlay_max_apps][24]u8 = [_][24]u8{[_]u8{0} ** 24} ** overlay_max_apps;
var overlay_bin_lens: [overlay_max_apps]usize = [_]usize{0} ** overlay_max_apps;
var overlay_labels: [overlay_max_apps][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** overlay_max_apps;
var overlay_label_lens: [overlay_max_apps]usize = [_]usize{0} ** overlay_max_apps;
var overlay_count: usize = 0;
var overlay_filter: [24]u8 = [_]u8{0} ** 24;
var overlay_filter_len: usize = 0;
var overlay_filtered: [overlay_max_apps]usize = undefined;
var overlay_filtered_count: usize = 0;
var overlay_sel: usize = 0;

/// Read + parse APPS.TXT into the static catalog. Manifest order, capped;
/// TABWM.BIN skipped (the WM seat is taken). Returns the entry count.
pub fn overlay_load_manifest() usize {
    overlay_count = 0;
    if (@import("builtin").os.tag != .freestanding) return 0;
    const fd = ui.file_open("APPS.TXT", ui.MODE_READ);
    if (fd < 0) return 0;
    defer ui.file_close(@intCast(fd));
    const n = ui.file_read(@intCast(fd), &overlay_manifest_buf);
    if (n <= 0) return 0;
    var parsed: [24]sexiburger_menu.MenuApp = undefined;
    const parsed_n = sexiburger_menu.parse_apps_manifest(overlay_manifest_buf[0..@intCast(n)], &parsed);
    for (parsed[0..parsed_n]) |app| {
        if (overlay_count >= overlay_max_apps) break;
        if (std.mem.eql(u8, app.name, "TABWM.BIN")) continue;
        const bin_len = @min(app.name.len, 24);
        @memcpy(overlay_bins[overlay_count][0..bin_len], app.name[0..bin_len]);
        overlay_bin_lens[overlay_count] = bin_len;
        const label_len = @min(app.desc.len, 32);
        @memcpy(overlay_labels[overlay_count][0..label_len], app.desc[0..label_len]);
        overlay_label_lens[overlay_count] = label_len;
        overlay_count += 1;
    }
    overlay_loaded = true;
    overlay_refresh_filter();
    return overlay_count;
}

/// Rebuild the filtered index (case-insensitive substring over label+bin).
pub fn overlay_refresh_filter() void {
    overlay_filtered_count = 0;
    overlay_sel = 0;
    const q = overlay_filter[0..overlay_filter_len];
    for (0..overlay_count) |i| {
        if (q.len == 0) {
            overlay_filtered[overlay_filtered_count] = i;
            overlay_filtered_count += 1;
            continue;
        }
        var hay: [64]u8 = undefined;
        const label = overlay_labels[i][0..overlay_label_lens[i]];
        const bin = overlay_bins[i][0..overlay_bin_lens[i]];
        if (label.len + 1 + bin.len > hay.len) continue;
        @memcpy(hay[0..label.len], label);
        hay[label.len] = ' ';
        @memcpy(hay[label.len + 1 .. label.len + 1 + bin.len], bin);
        const needle_len = @min(q.len, 32);
        var needle: [32]u8 = undefined;
        for (q[0..needle_len], 0..) |c, k| needle[k] = std.ascii.toLower(c);
        var hit = false;
        var start: usize = 0;
        while (start + needle_len <= label.len + 1 + bin.len) : (start += 1) {
            var k: usize = 0;
            while (k < needle_len and std.ascii.toLower(hay[start + k]) == needle[k]) : (k += 1) {}
            if (k == needle_len) {
                hit = true;
                break;
            }
        }
        if (hit) {
            overlay_filtered[overlay_filtered_count] = i;
            overlay_filtered_count += 1;
        }
    }
}

pub fn overlay_summon() void {
    if (!overlay_loaded) _ = overlay_load_manifest();
    overlay_open = true;
    write_marker(god_menu_marker);
}

pub fn overlay_dismiss() void {
    overlay_open = false;
    overlay_filter_len = 0;
    overlay_refresh_filter();
}

/// Launch the selected app into a new tab (the kernel's WM_WINDOW stream
/// delivers the window; the tab manager adds and activates it). Returns
/// false when the overlay is empty.
pub fn overlay_launch_selected() bool {
    if (overlay_filtered_count == 0) return false;
    const entry = overlay_filtered[overlay_sel];
    const bin = overlay_bins[entry][0..overlay_bin_lens[entry]];
    var buf: [40]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ launch_marker_prefix, bin }) catch launch_marker_prefix;
    write_marker(msg);
    _ = ui.exec_program(bin);
    overlay_dismiss();
    return true;
}

/// Handle one key while the overlay is open (the raw WM_KEY stream).
/// Returns true when consumed.
pub fn overlay_key(usage: u8) bool {
    if (!overlay_open) return false;
    switch (usage) {
        0x29 => { // Escape: dismiss
            overlay_dismiss();
            return true;
        },
        0x28 => { // Enter: launch selected
            _ = overlay_launch_selected();
            return true;
        },
        0x2a => { // Backspace: trim the filter
            if (overlay_filter_len > 0) {
                overlay_filter_len -= 1;
                overlay_refresh_filter();
            }
            return true;
        },
        0x52 => { // Up
            if (overlay_sel > 0) overlay_sel -= 1;
            return true;
        },
        0x51 => { // Down
            if (overlay_sel + 1 < overlay_filtered_count) overlay_sel += 1;
            return true;
        },
        else => {},
    }
    // Letters a..z, digits 1..0, space, minus, period: extend the filter.
    const printable = (usage >= 0x04 and usage <= 0x1d) or (usage >= 0x1e and usage <= 0x27) or
        usage == 0x2c or usage == 0x2d or usage == 0x37;
    if (printable and overlay_filter_len < overlay_filter.len) {
        const c: u8 = if (usage == 0x2c) ' ' else if (usage == 0x2d) '-' else if (usage == 0x37) '.' else if (usage <= 0x1d) @intCast(usage - 0x04 + 'a') else @intCast(usage - 0x1e + '1');
        overlay_filter[overlay_filter_len] = c;
        overlay_filter_len += 1;
        overlay_refresh_filter();
        return true;
    }
    return false;
}

/// The overlay's empty-state line (M42 UX, 2026-09-05): an EMPTY manifest
/// ("no apps installed") is a different, honestly distinguishable state
/// from a filter that merely has no hits ("no matching apps").
/// Host-testable — the renderer draws exactly this string.
pub fn overlay_empty_message() []const u8 {
    if (overlay_count == 0) return "no apps installed";
    return "no matching apps";
}

/// Draw the overlay panel centered over the content viewport (call after
/// draw_sidebar; the dim + panel overwrite the canvas only).
pub fn draw_overlay(pixels: []u32) void {
    if (!overlay_open) return;
    const px = viewport_x + (viewport_w - overlay_panel_w) / 2;
    const py: u32 = 80;
    // Dim the viewport behind the panel (source-over alpha).
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(viewport_x, 0, viewport_w, fb_h), 0, 0xB0000000);
    // Panel
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px, py, overlay_panel_w, overlay_panel_h), 8, ui.sidebar_active_pill());
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px, py, overlay_panel_w, 44), 8, ui.sidebar_hover_pill());
    // Emblem + title
    if (mascot_image()) |img| {
        ui.draw_image_buf(pixels, fb_w, px + 10, py + 8, img);
    }
    ui.draw_text_sized(0, "SEXIBURGER", px + 46, py + 15, ui.font_size_tab_title, ui.sidebar_text_active());
    // Filter line
    ui.draw_text_sized(0, ">", px + 12, py + 52, ui.font_size_badge, ui.theme_accent());
    if (overlay_filter_len > 0) {
        ui.draw_text_sized(0, overlay_filter[0..overlay_filter_len], px + 24, py + 52, ui.font_size_badge, ui.sidebar_text_active());
    } else {
        ui.draw_text_sized(0, "type to filter, enter launches", px + 24, py + 52, ui.font_size_badge, ui.sidebar_text_inactive());
    }
    // App rows
    var row: u32 = 0;
    while (row < overlay_filtered_count and row < 17) : (row += 1) {
        const entry = overlay_filtered[row];
        const ry = py + 70 + row * overlay_row_h;
        const is_sel = (row == overlay_sel);
        if (is_sel) {
            ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px + 8, ry - 3, overlay_panel_w - 16, overlay_row_h - 2), 4, ui.theme_accent());
        }
        const label = overlay_labels[entry][0..overlay_label_lens[entry]];
        const bin = overlay_bins[entry][0..overlay_bin_lens[entry]];
        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s} — {s}", .{ label, bin }) catch label;
        ui.draw_text_sized(0, line[0..@min(line.len, 56)], px + 14, ry + 1, ui.font_size_badge, if (is_sel) 0x000000 else ui.sidebar_text_active());
    }
    if (overlay_filtered_count == 0) {
        ui.draw_text_sized(0, overlay_empty_message(), px + 14, py + 74, ui.font_size_badge, ui.sidebar_text_inactive());
    }
    // Footer
    ui.draw_text_sized(0, "esc dismiss", px + 12, py + overlay_panel_h - 20, ui.font_size_badge, ui.sidebar_text_inactive());
}

// ---------------------------------------------------------------------------
// Canvas & Left Sidebar Drawing
// ---------------------------------------------------------------------------

fn fill_canvas_rect(pixels: []u32, rx: u32, ry: u32, rw: u32, rh: u32) void {
    const is_light = std.mem.eql(u8, ui.theme_name(), "light");
    const bg_color: u32 = if (is_light) 0xFFE9EDF2 else 0xFF14161B;
    const dot_color: u32 = if (is_light) 0xFFCBD5E1 else 0xFF252934;

    var y: u32 = ry;
    const y_end = @min(ry + rh, fb_h);
    const x_end = @min(rx + rw, fb_w);

    while (y < y_end) : (y += 1) {
        const row_start = y * fb_w;
        var x: u32 = rx;
        while (x < x_end) : (x += 1) {
            const is_dot = (x % 24 == 0 and y % 24 == 0);
            pixels[row_start + x] = if (is_dot) dot_color else bg_color;
        }
    }
}

/// Renders the dark slate canvas backdrop with subtle grid texture in empty viewport space.
pub fn draw_viewport_backdrop(scan: [*]u32) void {
    const pixels = scan[0 .. @as(usize, fb_w) * fb_h];

    if (manager.active_idx) |idx| {
        if (idx < manager.tab_count and manager.tabs[idx].valid) {
            const tab = &manager.tabs[idx];
            const vp = compute_tab_viewport(tab);

            // Full viewport: nothing to fill outside window
            if (vp.w >= viewport_w and vp.h >= viewport_h and vp.x == viewport_x and vp.y == viewport_y) {
                return;
            }

            // Window is centered with canvas margins around it
            if (vp.y > viewport_y) {
                fill_canvas_rect(pixels, viewport_x, viewport_y, viewport_w, vp.y - viewport_y);
            }
            const bottom_y = vp.y + vp.h;
            if (bottom_y < viewport_y + viewport_h) {
                fill_canvas_rect(pixels, viewport_x, bottom_y, viewport_w, (viewport_y + viewport_h) - bottom_y);
            }
            if (vp.x > viewport_x) {
                fill_canvas_rect(pixels, viewport_x, vp.y, vp.x - viewport_x, vp.h);
            }
            const right_x = vp.x + vp.w;
            if (right_x < viewport_x + viewport_w) {
                fill_canvas_rect(pixels, right_x, vp.y, (viewport_x + viewport_w) - right_x, vp.h);
            }
            return;
        }
    }

    // No active tabs: fill entire content viewport
    fill_canvas_rect(pixels, viewport_x, viewport_y, viewport_w, viewport_h);
}

pub fn draw_sidebar(scan: [*]u32) void {
    draw_viewport_backdrop(scan);

    const pixels = scan[0 .. @as(usize, fb_w) * fb_h];

    // 1. Sidebar background: full vertical height, 180px wide
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(0, 0, sidebar_w, fb_h), 0, ui.sidebar_bg());

    // 2. Right border line: 1px vertical line at x = sidebar_w - 1
    const border_c = ui.sidebar_border();
    var y: u32 = 0;
    while (y < fb_h) : (y += 1) {
        pixels[y * fb_w + (sidebar_w - 1)] = 0xFF000000 | border_c;
    }

    // 3. Top Sexiburger Area (y = 8 .. 48)
    const sexiburg_rect = Rect.make(8, 8, 164, 38);
    if (hover_sexiburger) {
        ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, sexiburg_rect, 6, ui.sidebar_hover_pill());
    }

    // Proper Sexiburger mascot emblem (the real 🐙+🍔 raster, M42 SX1) at (12, 13)
    draw_mascot_emblem(pixels, 12, 13);

    // Header label: "Virelai" in 14pt Inter
    ui.draw_text_sized(0, "Virelai", 48, 20, ui.font_size_tab_title, ui.sidebar_text_active());

    // Header shortcut badge: "[*]" hint
    ui.draw_text_sized(0, "[*]", 144, 21, ui.font_size_badge, ui.theme_accent());

    // Separator line below header (y = 52)
    var sx: u32 = 8;
    while (sx < 172) : (sx += 1) {
        pixels[52 * fb_w + sx] = 0xFF000000 | border_c;
    }

    // 4. Middle Tab List (y = 58 .. 650)
    if (manager.tab_count == 0) {
        ui.draw_text_sized(0, "No open tabs", 20, 96, ui.font_size_badge, ui.sidebar_text_inactive());
        ui.draw_text_sized(0, "Ctrl+Space or +", 20, 112, ui.font_size_badge, ui.sidebar_text_inactive());
        ui.draw_text_sized(0, "to launch apps", 20, 126, ui.font_size_badge, ui.sidebar_text_inactive());
    } else {
        for (0..manager.tab_count) |i| {
            const tab_y: u32 = 58 + @as(u32, @intCast(i)) * tab_row_h;
            if (tab_y + tab_row_h >= 650) break;

            const pill_rect = Rect.make(8, tab_y + 2, 164, 34);
            const is_active = (manager.active_idx != null and manager.active_idx.? == i);
            const is_hover = (hover_tab != null and hover_tab.? == i);

            if (is_active) {
                // Active pill background
                ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, pill_rect, ui.tab_pill_radius, ui.sidebar_active_pill());
                // Left accent bar
                ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(10, tab_y + 8, 3, 22), 1, ui.theme_accent());
                // Tab title in active text color
                ui.draw_text_sized(0, manager.tabs[i].get_title(), 24, tab_y + 11, ui.font_size_tab_title, ui.sidebar_text_active());
                // Close button 'x'
                ui.draw_text_sized(0, "x", 154, tab_y + 11, ui.font_size_badge, ui.sidebar_text_inactive());
            } else if (is_hover) {
                // Hover pill background
                ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, pill_rect, ui.tab_pill_radius, ui.sidebar_hover_pill());
                ui.draw_text_sized(0, manager.tabs[i].get_title(), 24, tab_y + 11, ui.font_size_tab_title, ui.sidebar_text_active());
                ui.draw_text_sized(0, "x", 154, tab_y + 11, ui.font_size_badge, ui.sidebar_text_inactive());
            } else {
                // Inactive tab
                ui.draw_text_sized(0, manager.tabs[i].get_title(), 24, tab_y + 11, ui.font_size_tab_title, ui.sidebar_text_inactive());
            }
        }
    }

    // M42 UX: the "+ New tab" affordance pill — directly below the last
    // tab row (or in the empty-state area), always rendered so it is
    // discoverable; hover lights it like the other pills.
    const nt_rect = new_tab_pill_rect();
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, nt_rect, ui.tab_pill_radius, if (hover_new_tab) ui.sidebar_hover_pill() else ui.sidebar_active_pill());
    ui.draw_text_sized(0, "+ New tab", 24, nt_rect.y + 5, ui.font_size_badge, if (hover_new_tab) ui.sidebar_text_active() else ui.sidebar_text_inactive());

    // 5. Bottom Status / Tray Area (y = 660 .. 720)    // Separator line at y = 660
    var bx: u32 = 8;
    while (bx < 172) : (bx += 1) {
        pixels[660 * fb_w + bx] = 0xFF000000 | border_c;
    }

    // Clock text "12:00"
    var clock_buf: [8]u8 = undefined;
    const clock_str = std.fmt.bufPrint(&clock_buf, "{d:0>2}:{d:0>2}", .{ clock_hours, clock_minutes }) catch "12:00";
    ui.draw_text_sized(0, clock_str, 16, 678, ui.font_size_clock, ui.sidebar_text_active());

    // Theme toggle pill [D] / [L]
    const theme_rect = Rect.make(96, 672, 32, 24);
    const theme_bg = if (hover_theme_toggle) ui.sidebar_hover_pill() else ui.sidebar_active_pill();
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, theme_rect, 4, theme_bg);
    const theme_char = if (std.mem.eql(u8, ui.theme_name(), "light")) "L" else "D";
    ui.draw_text_sized(0, theme_char, 108, 676, ui.font_size_badge, ui.sidebar_text_active());

    // Clipboard badge [CB]
    const clip_rect = Rect.make(134, 672, 36, 24);
    const clip_bg = if (hover_clip) ui.sidebar_hover_pill() else ui.sidebar_bg();
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, clip_rect, 4, clip_bg);
    ui.draw_text_sized(0, "CB", 144, 676, ui.font_size_badge, ui.theme_accent());

    // M42 SX5: the Sexiburger god-menu overlay renders last (over the
    // canvas + sidebar dim).
    draw_overlay(pixels);
}

/// Proper Sexiburger mascot emblem (M42 SX1, issue #982): the real 🐙+🍔
/// artwork — an octopus holding the six-layer burger — downscaled from
/// `assets/sexiburger.png` (534x534, the canonical emoji export) to 28x28
/// and embedded as a QOI fixture (`mascot_28x28.qoi`; regenerate with the
/// premultiplied-Lanczos pass documented in `docs/march-m42-sexiburger-desktop.md`).
/// Decoded ONCE into static BSS (the wnd.zig god-menu fixture pattern) and
/// alpha-blended straight into the scanout via `ui.draw_image_buf`. The
/// rect-drawn fallback emblem stays available in `lib/sexiburger.zig` for
/// the no-asset path.
pub const mascot_size: u32 = 28;

const mascot_qoi_bytes = @embedFile("lib/fixtures/qoi/mascot_28x28.qoi");
var mascot_pixels: [mascot_size * mascot_size]u32 = undefined;
var mascot_loaded: bool = false;

pub fn mascot_image() ?ui.Image {
    if (mascot_loaded) {
        return ui.Image{
            .width = mascot_size,
            .height = mascot_size,
            .pixels = &mascot_pixels,
        };
    }
    const decoded = ui.image.qoi.decode(mascot_qoi_bytes, &mascot_pixels) catch return null;
    if (decoded.width != mascot_size or decoded.height != mascot_size) return null;
    mascot_loaded = true;
    return ui.Image{
        .width = mascot_size,
        .height = mascot_size,
        .pixels = &mascot_pixels,
    };
}

fn draw_mascot_emblem(pixels: []u32, x: u32, y: u32) void {
    if (mascot_image()) |img| {
        ui.draw_image_buf(pixels, fb_w, x, y, img);
        return;
    }
    // Asset unavailable (decode failed): the legacy hand-drawn mini mascot.
    draw_mini_mascot(pixels, x, y);
}

/// Legacy mini Sexiburger mascot fallback: 6 burger layers + tentacles (18x18 px).
fn draw_mini_mascot(pixels: []u32, x: u32, y: u32) void {
    const tentacle: u32 = 0xFFF57C00;

    // Tentacles left
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(x, y + 2, 3, 2), 0, tentacle);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(x - 2, y + 5, 3, 2), 0, tentacle);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(x - 3, y + 8, 3, 3), 0, tentacle);

    // Tentacles right
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(x + 17, y + 2, 3, 2), 0, tentacle);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(x + 19, y + 5, 3, 2), 0, tentacle);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(x + 20, y + 8, 3, 3), 0, tentacle);

    // 6-layer Burger Body
    const bx = x + 2;
    const bw: u32 = 16;
    // Layer 1: Crown Bun
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx + 2, y + 1, bw - 4, 2), 1, 0xFFD89632);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx, y + 3, bw, 2), 1, 0xFFD89632);
    // Layer 2: Lettuce
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx - 1, y + 5, bw + 2, 2), 0, 0xFF4CAF50);
    // Layer 3: Tomato
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx + 1, y + 7, bw - 2, 2), 0, 0xFFE53935);
    // Layer 4: Cheese
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx, y + 9, bw, 2), 0, 0xFFFDD835);
    // Layer 5: Patty
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx + 1, y + 11, bw - 2, 3), 1, 0xFF6D4C41);
    // Layer 6: Heel Bun
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx + 1, y + 14, bw - 2, 2), 1, 0xFFC88628);
}

// ---------------------------------------------------------------------------
// Pointer & Hit Testing (M39 TWM2)
// ---------------------------------------------------------------------------
pub fn handle_pointer(px: u32, py: u32, clicked: bool) void {
    if (px >= sidebar_w) {
        hover_sexiburger = false;
        hover_tab = null;
        hover_theme_toggle = false;
        hover_clip = false;
        hover_new_tab = false;
        return;
    }

    // Sexiburger header hit test (y = 8..48)
    hover_sexiburger = (px >= 8 and px < 172 and py >= 8 and py < 48);
    if (hover_sexiburger and clicked) {
        overlay_summon(); // emits `tabwm: god-menu` (M42 SX5)
    }

    // Theme toggle hit test (y = 672..696, x = 96..128)
    hover_theme_toggle = (px >= 96 and px < 128 and py >= 672 and py < 696);
    if (hover_theme_toggle and clicked) {
        if (std.mem.eql(u8, ui.theme_name(), "dark")) {
            _ = ui.set_theme("light");
        } else {
            _ = ui.set_theme("dark");
        }
    }

    // Clipboard hit test (y = 672..696, x = 134..170)
    hover_clip = (px >= 134 and px < 170 and py >= 672 and py < 696);

    // Tab items hit test (y = 58..650). M42 UX: the "+ New tab" pill is
    // checked FIRST — it lives inside the tab-row band, and the generic
    // row-index mapping would otherwise eat its click (the same precedence
    // pattern as the close 'x' check at x = 148..168 inside the row).
    hover_tab = null;
    hover_new_tab = (px >= 8 and px < 172 and py >= new_tab_pill_y() and py < new_tab_pill_y() + new_tab_pill_h);
    if (hover_new_tab) {
        if (clicked) trigger_new_tab(); // emits `tabwm: new-tab` + god-menu summon
    } else if (py >= 58 and py < 650) {
        const idx = (py - 58) / tab_row_h;
        if (idx < manager.tab_count) {
            hover_tab = idx;
            if (clicked) {
                // Check if clicked close box 'x' at x = 148..168
                if (px >= 148 and px < 168) {
                    close_tab(idx);
                } else {
                    activate_tab(idx);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Keyboard Shortcuts Decoder (M39 TWM2)
// ---------------------------------------------------------------------------
pub fn handle_wm_key(usage: u8, flags: u16) void {
    const ctrl = (flags & ui.MOD_CTRL != 0);
    const shift = (flags & ui.MOD_SHIFT != 0);

    if (ctrl) {
        // Ctrl+Tab / Ctrl+Shift+Tab: cycle tabs
        if (usage == usage_tab) {
            if (shift) {
                manager.cycle_tab_backward();
            } else {
                manager.cycle_tab();
            }
            if (manager.active_idx) |idx| {
                activate_tab(idx);
            }
            return;
        }

        // Ctrl+1..9: jump directly to tab index 0..8
        if (usage >= usage_1 and usage <= usage_9) {
            const target_idx: usize = @as(usize, usage - usage_1);
            if (target_idx < manager.tab_count) {
                activate_tab(target_idx);
            }
            return;
        }

        // Ctrl+W: close active tab
        if (usage == usage_w) {
            if (manager.active_idx) |cur| {
                close_tab(cur);
            }
            return;
        }

        // Ctrl+T: the "+ New tab" affordance — summon the launcher (M42 UX)
        if (usage == usage_t) {
            trigger_new_tab();
            return;
        }

        // Ctrl+Space: summon the Sexiburger god-menu overlay (M42 SX5)
        if (usage == usage_space) {
            overlay_summon();
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// WM_RPC Mailbox Communication Loop
// ---------------------------------------------------------------------------
fn wnd_mail_reply(reply_to: u8, req: *const ui.WmRpc, applied: bool) void {
    var rep: ui.WmRpc = .{
        .kind = req.kind | ui.wm_rpc_reply_flag,
        .id = req.id,
        .seq = req.seq,
        .reply_to = reply_to,
        .applied = if (applied) 1 else 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = [_]u8{0} ** ui.wm_rpc_title_max,
    };
    const rep_bytes = std.mem.asBytes(&rep);
    _ = syscall3(sys_ipc_send, reply_to, @intFromPtr(rep_bytes.ptr), rep_bytes.len);
}

pub fn wnd_mail_apply(req: *const ui.WmRpc) bool {
    switch (req.kind & 0x7f) {
        ui.wm_rpc_kind_raise => {
            if (manager.find_by_id(req.id)) |idx| {
                activate_tab(idx);
                return true;
            }
            return false;
        },
        ui.wm_rpc_kind_register_action, ui.wm_rpc_kind_config => {
            var label_slice: []const u8 = req.title[0..];
            for (req.title, 0..) |c, i| {
                if (c == 0) {
                    label_slice = req.title[0..i];
                    break;
                }
            }
            if (label_slice.len > 0) {
                _ = manager.add_or_update_tab(req.id, label_slice);
                return true;
            }
            return false;
        },
        ui.wm_rpc_kind_declare_fullscreen => {
            // M42 SX2: the app (via lib/tabapp.zig) declares itself
            // tab-aware — full-viewport eligible. Registers/renames the tab
            // from the payload title and, when the tab is ALREADY active,
            // immediately proposes the full viewport (the next activation
            // would otherwise wait for a tab switch).
            var label_slice: []const u8 = req.title[0..];
            for (req.title, 0..) |c, i| {
                if (c == 0) {
                    label_slice = req.title[0..i];
                    break;
                }
            }
            var idx: usize = undefined;
            if (manager.find_by_id(req.id)) |found| {
                idx = found;
            } else {
                idx = manager.add_or_update_tab(req.id, if (label_slice.len > 0) label_slice else "App");
            }
            manager.tabs[idx].tab_aware = true;
            if (label_slice.len > 0) manager.tabs[idx].set_title(label_slice);
            if (manager.active_idx != null and manager.active_idx.? == idx) {
                activate_tab(idx);
            }
            return true;
        },
        ui.wm_rpc_kind_cycle_tab => {
            manager.cycle_tab();
            if (manager.active_idx) |idx| {
                activate_tab(idx);
            }
            return true;
        },
        ui.wm_rpc_kind_detach_tab => {
            if (manager.find_by_id(req.id)) |idx| {
                close_tab(idx);
                return true;
            }
            return false;
        },
        else => return false,
    }
}

pub fn wnd_mail_loop() void {
    var raw: [128]u8 = undefined;
    while (true) {
        const got = syscall2(sys_ipc_recv, @intFromPtr(&raw), raw.len);
        if (got <= 0) return;
        if (got < @sizeOf(ui.WmRpc)) continue;
        var req: ui.WmRpc = undefined;
        @memcpy(std.mem.asBytes(&req), raw[0..@sizeOf(ui.WmRpc)]);
        if (req.kind & ui.wm_rpc_reply_flag != 0) continue;
        const applied = wnd_mail_apply(&req);
        wnd_mail_reply(req.reply_to, &req, applied);
    }
}

// ---------------------------------------------------------------------------
// Server Entry Point & Main Loop
// ---------------------------------------------------------------------------
export fn _start() callconv(.c) noreturn {
    main();
}

fn main() noreturn {
    // 1. Register as the WM server over slot 65
    if (syscall6(sys_wmctl, wmctl_register, 0, 0, 0, 0, 0) != 0) {
        while (true) {
            _ = syscall0(sys_yield_num);
        }
    }
    write_marker(registered_marker);

    // 2. Map direct scanout surface
    _ = ensure_scanout_mapped();

    // 3. Initialize TrueType fonts and desktop theme
    _ = ui.init_fonts();
    _ = ui.sync_theme_from_host();

    // M42 SX5: load the APPS.TXT catalog for the god-menu overlay
    _ = overlay_load_manifest();

    var ev: Event = undefined;

    while (true) {
        // Block until kernel render server queues an event
        if (syscall2(sys_wait_event_num, @intFromPtr(&ev), @sizeOf(Event)) <= 0) {
            _ = syscall0(sys_yield_num);
            continue;
        }

        switch (ev.kind) {
            composite_tick_kind => {
                ticks_count += 1;

                // Drain app mailbox requests
                wnd_mail_loop();

                // Update clock
                clock_minutes = @intCast((ticks_count / 60) % 60);
                clock_hours = @intCast(12 + (ticks_count / 3600) % 12);

                // Render Left Sidebar directly to scanout
                if (scanout_ptr) |scan| {
                    draw_sidebar(scan);
                    write_marker(sidebar_render_marker);
                }

                // Request present at cadence
                if (ticks_count % present_every == 0) {
                    _ = syscall6(sys_wmctl, wmctl_request_present, 0, 0, 0, 0, 0);
                    present_count += 1;
                    write_marker(present_marker);
                }
            },
            wm_pointer_kind => {
                const px = ev.arg0 & 0xffff;
                const py = ev.arg0 >> 16;
                const clicked = (ev.flags & btn_left != 0);
                handle_pointer(px, py, clicked);
            },
            wm_window_kind => {
                // Window opened or registered by an app (id >= 2). M42 UX:
                // the mirror is decoded here and synced into the tab list
                // by handle_window_mirror — flags low byte = id, bit 8 =
                // visible, bit 13 = released; arg1 = w|(h<<16) as today.
                const wid: u8 = @intCast(ev.flags & 0xff);
                const visible = (ev.flags & (1 << 8)) != 0;
                const released = (ev.flags & (1 << 13)) != 0;
                const orig_w: u32 = @intCast(ev.arg1 & 0xffff);
                const orig_h: u32 = @intCast(ev.arg1 >> 16);
                handle_window_mirror(wid, visible, released, orig_w, orig_h);
            },
            wm_key_kind => {
                const usage: u8 = @intCast(ev.arg0 & 0xff);
                // M42 SX5: the god-menu overlay consumes the stream first.
                if (!overlay_key(usage)) {
                    handle_wm_key(usage, ev.flags);
                }
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Unit Tests (M39 TWM1 + TWM2)
// ---------------------------------------------------------------------------
test "tabwm: tab manager allocation and lifecycle" {
    var mgr = TabManager.init();
    try std.testing.expectEqual(@as(usize, 0), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, null), mgr.active_idx);

    // Add first tab
    const idx0 = mgr.add_or_update_tab(1, "Calculator");
    try std.testing.expectEqual(@as(usize, 0), idx0);
    try std.testing.expectEqual(@as(usize, 1), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);
    try std.testing.expectEqualStrings("Calculator", mgr.tabs[0].get_title());

    // Add second tab
    const idx1 = mgr.add_or_update_tab(2, "Notes");
    try std.testing.expectEqual(@as(usize, 1), idx1);
    try std.testing.expectEqual(@as(usize, 2), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);

    // Switch active tab
    try std.testing.expect(mgr.activate_tab(1));
    try std.testing.expectEqual(@as(?usize, 1), mgr.active_idx);
    try std.testing.expectEqual(@as(?u32, 2), mgr.get_active_id());

    // Cycle tab
    mgr.cycle_tab();
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);

    // Remove tab
    try std.testing.expect(mgr.remove_tab(1));
    try std.testing.expectEqual(@as(usize, 1), mgr.tab_count);
    try std.testing.expectEqualStrings("Notes", mgr.tabs[0].get_title());
}

test "tabwm: tab manager active index adjustment on removal" {
    var mgr = TabManager.init();
    _ = mgr.add_or_update_tab(10, "Tab 0");
    _ = mgr.add_or_update_tab(20, "Tab 1");
    _ = mgr.add_or_update_tab(30, "Tab 2");
    _ = mgr.add_or_update_tab(40, "Tab 3");
    try std.testing.expectEqual(@as(usize, 4), mgr.tab_count);

    // Set active index to 2 (Tab 2, id 30)
    try std.testing.expect(mgr.activate_tab(2));
    try std.testing.expectEqual(@as(?usize, 2), mgr.active_idx);
    try std.testing.expectEqual(@as(?u32, 30), mgr.get_active_id());

    // Remove Tab 0 (index 0 < cur 2) -> cur should decrement to 1 (still Tab 2, id 30)
    try std.testing.expect(mgr.remove_tab(10));
    try std.testing.expectEqual(@as(usize, 3), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, 1), mgr.active_idx);
    try std.testing.expectEqual(@as(?u32, 30), mgr.get_active_id());

    // Remove Tab 3 (tail, index 2 > cur 1) -> cur stays 1
    try std.testing.expect(mgr.remove_tab(40));
    try std.testing.expectEqual(@as(usize, 2), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, 1), mgr.active_idx);
    try std.testing.expectEqual(@as(?u32, 30), mgr.get_active_id());

    // Remove Tab 2 (currently active at index 1) -> cur clamps to 0 (Tab 1, id 20)
    try std.testing.expect(mgr.remove_tab(30));
    try std.testing.expectEqual(@as(usize, 1), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);
    try std.testing.expectEqual(@as(?u32, 20), mgr.get_active_id());

    // Remove final tab -> active_idx becomes null
    try std.testing.expect(mgr.remove_tab(20));
    try std.testing.expectEqual(@as(usize, 0), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, null), mgr.active_idx);
    try std.testing.expectEqual(@as(?u32, null), mgr.get_active_id());
}

test "tabwm: tab cycle forward and backward" {
    var mgr = TabManager.init();
    _ = mgr.add_or_update_tab(1, "A");
    _ = mgr.add_or_update_tab(2, "B");
    _ = mgr.add_or_update_tab(3, "C");
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);

    // Forward cycle: 0 -> 1 -> 2 -> 0
    mgr.cycle_tab();
    try std.testing.expectEqual(@as(?usize, 1), mgr.active_idx);
    mgr.cycle_tab();
    try std.testing.expectEqual(@as(?usize, 2), mgr.active_idx);
    mgr.cycle_tab();
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);

    // Backward cycle: 0 -> 2 -> 1 -> 0
    mgr.cycle_tab_backward();
    try std.testing.expectEqual(@as(?usize, 2), mgr.active_idx);
    mgr.cycle_tab_backward();
    try std.testing.expectEqual(@as(?usize, 1), mgr.active_idx);
    mgr.cycle_tab_backward();
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);
}

test "tabwm: keyboard shortcuts routing" {
    manager = TabManager.init();
    _ = manager.add_or_update_tab(101, "Browser");
    _ = manager.add_or_update_tab(102, "Terminal");
    _ = manager.add_or_update_tab(103, "Editor");
    activate_tab(0);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);

    // 1. Ctrl+Tab -> cycles to Tab 1
    handle_wm_key(usage_tab, ui.MOD_CTRL);
    try std.testing.expectEqual(@as(?usize, 1), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 102), manager.get_active_id());

    // 2. Ctrl+Shift+Tab -> cycles back to Tab 0
    handle_wm_key(usage_tab, ui.MOD_CTRL | ui.MOD_SHIFT);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);

    // 3. Ctrl+3 (usage_3 = 0x20) -> jumps directly to Tab 2
    handle_wm_key(usage_3, ui.MOD_CTRL);
    try std.testing.expectEqual(@as(?usize, 2), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 103), manager.get_active_id());

    // 4. Ctrl+1 (usage_1 = 0x1e) -> jumps directly to Tab 0
    handle_wm_key(usage_1, ui.MOD_CTRL);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);

    // 5. Ctrl+W -> closes active Tab 0
    handle_wm_key(usage_w, ui.MOD_CTRL);
    try std.testing.expectEqual(@as(usize, 2), manager.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 102), manager.get_active_id());

    // 6. Ctrl+Space -> triggers god menu
    handle_wm_key(usage_space, ui.MOD_CTRL);
}

test "tabwm: pointer hit testing and tab selection / close button" {
    manager = TabManager.init();
    _ = manager.add_or_update_tab(201, "Calc");
    _ = manager.add_or_update_tab(202, "Files");
    activate_tab(0);

    // Hover over Tab 1 (y = 58 + 38 = 96)
    handle_pointer(50, 100, false);
    try std.testing.expectEqual(@as(?usize, 1), hover_tab);

    // Click Tab 1 body (x = 50, y = 100) -> activates Tab 1
    handle_pointer(50, 100, true);
    try std.testing.expectEqual(@as(?usize, 1), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 202), manager.get_active_id());

    // Click Tab 1 close button 'x' (x = 156, y = 100) -> closes Tab 1
    handle_pointer(156, 100, true);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 201), manager.get_active_id());

    // Click Sexiburger header (x = 20, y = 20)
    handle_pointer(20, 20, true);
    try std.testing.expect(hover_sexiburger);
}

test "tabwm: wnd_mail_apply RPC commands" {
    manager = TabManager.init();
    _ = manager.add_or_update_tab(31, "Old Title");
    _ = manager.add_or_update_tab(32, "Other");
    activate_tab(0);

    // 1. Rename tab via config RPC
    var req_config = ui.WmRpc{
        .kind = ui.wm_rpc_kind_config,
        .id = 31,
        .seq = 1,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = [_]u8{0} ** ui.wm_rpc_title_max,
    };
    @memcpy(req_config.title[0..9], "New Title");
    try std.testing.expect(wnd_mail_apply(&req_config));
    try std.testing.expectEqualStrings("New Title", manager.tabs[0].get_title());

    // 2. Raise tab via raise RPC
    var req_raise = ui.WmRpc{
        .kind = ui.wm_rpc_kind_raise,
        .id = 32,
        .seq = 2,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = [_]u8{0} ** ui.wm_rpc_title_max,
    };
    try std.testing.expect(wnd_mail_apply(&req_raise));
    try std.testing.expectEqual(@as(?usize, 1), manager.active_idx);

    // 3. Cycle tab via cycle RPC
    var req_cycle = ui.WmRpc{
        .kind = ui.wm_rpc_kind_cycle_tab,
        .id = 0,
        .seq = 3,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = [_]u8{0} ** ui.wm_rpc_title_max,
    };
    try std.testing.expect(wnd_mail_apply(&req_cycle));
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);

    // 4. Detach / close tab via detach RPC
    var req_detach = ui.WmRpc{
        .kind = ui.wm_rpc_kind_detach_tab,
        .id = 32,
        .seq = 4,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = [_]u8{0} ** ui.wm_rpc_title_max,
    };
    try std.testing.expect(wnd_mail_apply(&req_detach));
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
}

test "tabwm: geometry constants respect M39 tokens" {
    try std.testing.expectEqual(@as(u32, 1280), fb_w);
    try std.testing.expectEqual(@as(u32, 720), fb_h);
    try std.testing.expectEqual(@as(u32, 180), sidebar_w);
    try std.testing.expectEqual(@as(u32, 1100), viewport_w);
    try std.testing.expectEqual(@as(u32, 720), viewport_h);
    try std.testing.expectEqual(sidebar_w + viewport_w, fb_w);
}

test "tabwm: compute_tab_viewport centering and full bleed" {
    // 1. Resizable window gets full 1100x720 at (180, 0)
    var tab_res = Tab{
        .id = 1,
        .orig_w = 600,
        .orig_h = 400,
        .resizable = true,
        .valid = true,
    };
    const vp_res = compute_tab_viewport(&tab_res);
    try std.testing.expectEqual(@as(u32, 180), vp_res.x);
    try std.testing.expectEqual(@as(u32, 0), vp_res.y);
    try std.testing.expectEqual(@as(u32, 1100), vp_res.w);
    try std.testing.expectEqual(@as(u32, 720), vp_res.h);

    // 2. Unspecified size (orig_w=0) gets full 1100x720
    var tab_zero = Tab{
        .id = 2,
        .orig_w = 0,
        .orig_h = 0,
        .resizable = false,
        .valid = true,
    };
    const vp_zero = compute_tab_viewport(&tab_zero);
    try std.testing.expectEqual(@as(u32, 180), vp_zero.x);
    try std.testing.expectEqual(@as(u32, 0), vp_zero.y);
    try std.testing.expectEqual(@as(u32, 1100), vp_zero.w);
    try std.testing.expectEqual(@as(u32, 720), vp_zero.h);

    // 3. Fixed size window (512x384, e.g. WINLOOP.BIN) centers cleanly:
    // x = 180 + (1100 - 512) / 2 = 180 + 294 = 474
    // y = 0 + (720 - 384) / 2 = 168
    var tab_fixed = Tab{
        .id = 3,
        .orig_w = 512,
        .orig_h = 384,
        .resizable = false,
        .valid = true,
    };
    const vp_fixed = compute_tab_viewport(&tab_fixed);
    try std.testing.expectEqual(@as(u32, 474), vp_fixed.x);
    try std.testing.expectEqual(@as(u32, 168), vp_fixed.y);
    try std.testing.expectEqual(@as(u32, 512), vp_fixed.w);
    try std.testing.expectEqual(@as(u32, 384), vp_fixed.h);

    // 4. Fixed size window (260x340, e.g. CALC.BIN) centers cleanly:
    // x = 180 + (1100 - 260) / 2 = 180 + 420 = 600
    // y = 0 + (720 - 340) / 2 = 190
    var tab_calc = Tab{
        .id = 4,
        .orig_w = 260,
        .orig_h = 340,
        .resizable = false,
        .valid = true,
    };
    const vp_calc = compute_tab_viewport(&tab_calc);
    try std.testing.expectEqual(@as(u32, 600), vp_calc.x);
    try std.testing.expectEqual(@as(u32, 190), vp_calc.y);
    try std.testing.expectEqual(@as(u32, 260), vp_calc.w);
    try std.testing.expectEqual(@as(u32, 340), vp_calc.h);
}

test "tabwm: draw_viewport_backdrop writes canvas outside window" {
    var fb: [fb_w * fb_h]u32 = undefined;
    @memset(&fb, 0);

    // With 0 tabs, draw_viewport_backdrop should fill the whole viewport (180..1280, 0..720)
    manager = TabManager.init();
    draw_viewport_backdrop(&fb);

    // Sidebar area (0..179) should be untouched (0)
    try std.testing.expectEqual(@as(u32, 0), fb[100 * fb_w + 50]);
    // Viewport non-dot area should be dark slate canvas 0xFF14161B
    try std.testing.expectEqual(@as(u32, 0xFF14161B), fb[101 * fb_w + 201]);
    // Viewport dot node (x%24 == 0 and y%24 == 0, e.g. x=240, y=120) should be dot color 0xFF252934
    try std.testing.expectEqual(@as(u32, 0xFF252934), fb[120 * fb_w + 240]);
}

// ---------------------------------------------------------------------------
// Unit Tests (M42 SX1 — the proper mascot emblem)
// ---------------------------------------------------------------------------
test "tabwm: proper mascot emblem decodes at 28x28 (M42 SX1)" {
    const img = mascot_image() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 28), img.width);
    try std.testing.expectEqual(@as(u32, 28), img.height);
    // The artwork's center pixel is the burger's cheese layer (warm yellow);
    // the rect-drawn mini mascot never had a center like this.
    const c = img.pixels[14 * 28 + 14];
    const r = (c >> 16) & 0xFF;
    const g = (c >> 8) & 0xFF;
    const b = c & 0xFF;
    try std.testing.expect(r > 200 and g > 150 and b < 160);
    // The artwork's background is transparent (alpha 0 at the corner)
    try std.testing.expectEqual(@as(u32, 0), (img.pixels[0] >> 24) & 0xFF);
}

test "tabwm: draw_sidebar blits the raster emblem into the scanout (M42 SX1)" {
    var fb: [fb_w * fb_h]u32 = undefined;
    @memset(&fb, 0);
    manager = TabManager.init();
    hover_sexiburger = false; // earlier pointer tests may have left hover state
    mascot_loaded = false; // force a fresh decode for this test run
    draw_sidebar(&fb);
    const img = mascot_image() orelse return error.TestUnexpectedResult;
    // The icon's opaque center is exactly the fixture's cheese pixel
    // (alpha 255 -> blend_source_over is an overwrite)
    const center = fb[(13 + 14) * fb_w + (12 + 14)];
    try std.testing.expectEqual(img.pixels[14 * 28 + 14], center);
    // A fully transparent source pixel leaves the painted sidebar bg (not
    // the emblem) — the emblem's alpha respected the destination
    const corner = fb[13 * fb_w + 12];
    try std.testing.expectEqual(ui.sidebar_bg(), corner & 0x00FFFFFF);
}

// ---------------------------------------------------------------------------
// Unit Tests (M42 SX2 — the full-screen viewport seam)
// ---------------------------------------------------------------------------
test "tabwm: tab-aware fixed app takes the full viewport (M42 SX2)" {
    var tab = Tab{
        .id = 3,
        .orig_w = 512,
        .orig_h = 384,
        .resizable = false,
        .tab_aware = false,
        .valid = true,
    };
    // Without the declaration: the M39 TWM3 centered presentation.
    const centered = compute_tab_viewport(&tab);
    try std.testing.expectEqual(@as(u32, 474), centered.x);
    try std.testing.expectEqual(@as(u32, 168), centered.y);
    try std.testing.expectEqual(@as(u32, 512), centered.w);
    try std.testing.expectEqual(@as(u32, 384), centered.h);

    // With the tab-aware declaration: the FULL content viewport.
    tab.tab_aware = true;
    const full = compute_tab_viewport(&tab);
    try std.testing.expectEqual(@as(u32, 180), full.x);
    try std.testing.expectEqual(@as(u32, 0), full.y);
    try std.testing.expectEqual(@as(u32, 1100), full.w);
    try std.testing.expectEqual(@as(u32, 720), full.h);
}

test "tabwm: viewport_change_needed idempotence (M42 SX2)" {
    var tab = Tab{ .id = 1, .valid = true };
    const full = Rect.make(viewport_x, viewport_y, viewport_w, viewport_h);
    // First activation always proposes.
    try std.testing.expect(viewport_change_needed(&tab, full));
    tab.applied_vp = full;
    // Same rect: no repeat proposal (no repeat WIN_RESIZE at the app).
    try std.testing.expect(!viewport_change_needed(&tab, full));
    // Any change re-proposes.
    try std.testing.expect(viewport_change_needed(&tab, Rect.make(474, 168, 512, 384)));
}

test "tabwm: declare_fullscreen RPC registers and applies the full viewport (M42 SX2)" {
    manager = TabManager.init();
    // Unknown window id: the declaration creates the tab.
    var req = ui.WmRpc{
        .kind = ui.wm_rpc_kind_declare_fullscreen,
        .id = 42,
        .seq = 1,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = [_]u8{0} ** ui.wm_rpc_title_max,
    };
    @memcpy(req.title[0..4], "CALC");
    try std.testing.expect(wnd_mail_apply(&req));
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expect(manager.tabs[0].tab_aware);
    try std.testing.expectEqualStrings("CALC", manager.tabs[0].get_title());

    // Activate: the full-viewport proposal is applied and recorded.
    activate_tab(0);
    try std.testing.expect(manager.tabs[0].applied_vp != null);
    try std.testing.expectEqual(@as(u32, 1100), manager.tabs[0].applied_vp.?.w);

    // Re-declaration while already active: idempotent re-activation keeps
    // the same applied rect (the app gets no repeat WIN_RESIZE).
    try std.testing.expect(wnd_mail_apply(&req));
    try std.testing.expectEqual(@as(u32, 1100), manager.tabs[0].applied_vp.?.w);
    try std.testing.expectEqual(@as(u32, 180), manager.tabs[0].applied_vp.?.x);
}

test "tabwm: declare_fullscreen on an inactive tab defers the proposal (M42 SX2)" {
    manager = TabManager.init();
    _ = manager.add_or_update_tab(31, "Existing");
    activate_tab(0);
    const before = manager.tabs[0].applied_vp;

    var req = ui.WmRpc{
        .kind = ui.wm_rpc_kind_declare_fullscreen,
        .id = 32,
        .seq = 2,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = [_]u8{0} ** ui.wm_rpc_title_max,
    };
    @memcpy(req.title[0..5], "FILES");
    try std.testing.expect(wnd_mail_apply(&req));
    try std.testing.expectEqual(@as(usize, 2), manager.tab_count);
    try std.testing.expect(manager.tabs[1].tab_aware);
    // The inactive declaration did not steal activation...
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
    // ...and the active tab's applied viewport is untouched.
    try std.testing.expectEqual(before, manager.tabs[0].applied_vp);
}

// ---------------------------------------------------------------------------
// Unit Tests (M42 SX5 — the god-menu overlay)
// ---------------------------------------------------------------------------
fn overlay_seed_catalog() void {
    overlay_count = 3;
    const seeds = [_]struct { bin: []const u8, label: []const u8 }{
        .{ .bin = "CALC.BIN", .label = "64-bit Calc" },
        .{ .bin = "NOTEPAD.BIN", .label = "Text Editor" },
        .{ .bin = "TOP.BIN", .label = "Task Manager" },
    };
    for (seeds, 0..) |s, i| {
        @memcpy(overlay_bins[i][0..s.bin.len], s.bin);
        overlay_bin_lens[i] = s.bin.len;
        @memcpy(overlay_labels[i][0..s.label.len], s.label);
        overlay_label_lens[i] = s.label.len;
    }
    overlay_filter_len = 0;
    overlay_refresh_filter();
}

test "tabwm: god-menu overlay filters the manifest (M42 SX5)" {
    overlay_seed_catalog();
    try std.testing.expectEqual(@as(usize, 3), overlay_filtered_count);
    // Case-insensitive substring over label + bin.
    overlay_filter_len = 4;
    @memcpy(overlay_filter[0..4], "calc");
    overlay_refresh_filter();
    try std.testing.expectEqual(@as(usize, 1), overlay_filtered_count);
    try std.testing.expectEqual(@as(usize, 0), overlay_sel);
    // No hits: the empty state renders, launch refuses.
    overlay_filter_len = 3;
    @memcpy(overlay_filter[0..3], "zzz");
    overlay_refresh_filter();
    try std.testing.expectEqual(@as(usize, 0), overlay_filtered_count);
    overlay_open = true;
    try std.testing.expect(!overlay_launch_selected());
    overlay_dismiss();
}

test "tabwm: god-menu overlay keys — filter, select, launch, dismiss (M42 SX5)" {
    overlay_seed_catalog();
    overlay_open = true;
    // 'e' extends the filter ("e" hits "64-bit Calc"? no — label+bin
    // contains 'e' in "Text Editor"/"Task Manager"/"...Calc"? Calc has no
    // 'e'... "64-bit Calc" + "CALC.BIN" has none; Editor + Manager do.
    _ = overlay_key(0x08); // 'e'
    try std.testing.expectEqual(@as(usize, 2), overlay_filtered_count);
    // Backspace clears back to 3 hits.
    _ = overlay_key(0x2a);
    try std.testing.expectEqual(@as(usize, 3), overlay_filtered_count);
    // Down moves the selection.
    _ = overlay_key(0x51);
    try std.testing.expectEqual(@as(usize, 1), overlay_sel);
    // Up moves it back.
    _ = overlay_key(0x52);
    try std.testing.expectEqual(@as(usize, 0), overlay_sel);
    // Enter launches the selected app (host: exec no-ops) and dismisses.
    try std.testing.expect(overlay_launch_selected());
    try std.testing.expect(!overlay_open);
    try std.testing.expectEqual(@as(usize, 0), overlay_filter_len);
    // Escape dismisses cleanly.
    overlay_open = true;
    try std.testing.expect(overlay_key(0x29));
    try std.testing.expect(!overlay_open);
}

test "tabwm: overlay keys are consumed only while open (M42 SX5)" {
    overlay_open = false;
    // With the overlay closed, letter keys fall through (not consumed).
    try std.testing.expect(!overlay_key(0x04));
}

test "tabwm: god-menu overlay accepts digits, minus, period in the filter (M42 SX5)" {
    overlay_seed_catalog();
    overlay_open = true;
    // "64-bit": digits 6,4 (usages 0x23,0x21), minus (0x2d), b,i,t.
    _ = overlay_key(0x23);
    _ = overlay_key(0x21);
    try std.testing.expectEqual(@as(usize, 2), overlay_filter_len);
    _ = overlay_key(0x2d);
    try std.testing.expectEqual(@as(usize, 3), overlay_filter_len);
    try std.testing.expectEqual(@as(u8, '-'), overlay_filter[2]);
    _ = overlay_key(0x05); // b
    _ = overlay_key(0x0c); // i
    _ = overlay_key(0x17); // t
    try std.testing.expectEqual(@as(usize, 6), overlay_filter_len);
    overlay_refresh_filter();
    // Exactly one hit: "64-bit Calc" (CALC.BIN).
    try std.testing.expectEqual(@as(usize, 1), overlay_filtered_count);
    overlay_dismiss();
}

// ---------------------------------------------------------------------------
// Unit Tests (M42 UX hardening — 2026-09-05)
// ---------------------------------------------------------------------------
test "tabwm: released mirror removes the tab and activates the next (M42 UX)" {
    manager = TabManager.init();
    _ = manager.add_or_update_tab(2, "Alpha");
    _ = manager.add_or_update_tab(3, "Beta");
    activate_tab(0); // active = id 2

    // The kernel RELEASED window 2 (app self-exit): the tab goes, and the
    // next tab activates because the removed one was active.
    handle_window_mirror(2, false, true, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expect(manager.find_by_id(2) == null);
    try std.testing.expectEqual(@as(?u32, 3), manager.get_active_id());

    // Removing a NON-active tab keeps the active tab (index adjusts).
    _ = manager.add_or_update_tab(4, "Gamma");
    activate_tab(1); // active = id 3 (index 1 after the first removal)
    handle_window_mirror(4, false, true, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expectEqual(@as(?u32, 3), manager.get_active_id());
}

test "tabwm: released mirror for an unknown id is a no-op (M42 UX)" {
    manager = TabManager.init();
    _ = manager.add_or_update_tab(2, "Alpha");
    activate_tab(0);
    handle_window_mirror(9, false, true, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 2), manager.get_active_id());
}

test "tabwm: hide mirror without released does NOT remove a tab (M42 UX)" {
    manager = TabManager.init();
    _ = manager.add_or_update_tab(2, "Alpha");
    activate_tab(0);
    // TABWM's own hide echo / an external hide: the tab list is ours.
    handle_window_mirror(2, false, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expect(manager.find_by_id(2) != null);
    try std.testing.expectEqual(@as(?u32, 2), manager.get_active_id());
}

test "tabwm: visible mirror upserts geometry (M42 UX)" {
    manager = TabManager.init();
    _ = manager.add_or_update_tab(2, "Alpha");
    handle_window_mirror(2, true, false, 640, 480);
    try std.testing.expectEqual(@as(u32, 640), manager.tabs[0].orig_w);
    try std.testing.expectEqual(@as(u32, 480), manager.tabs[0].orig_h);
    // Zero geometry never clobbers a known size.
    handle_window_mirror(2, true, false, 0, 0);
    try std.testing.expectEqual(@as(u32, 640), manager.tabs[0].orig_w);
    try std.testing.expectEqual(@as(u32, 480), manager.tabs[0].orig_h);
}

test "tabwm: the 17th window is ignored, tab 0 not hijacked (M42 UX)" {
    manager = TabManager.init();
    var id: u32 = 2;
    while (id < 2 + max_tabs) : (id += 1) {
        _ = manager.add_or_update_tab(id, "Filler");
    }
    try std.testing.expectEqual(max_tabs, manager.tab_count);
    try std.testing.expect(manager.activate_tab(3));
    handle_window_mirror(99, true, false, 100, 100);
    try std.testing.expectEqual(max_tabs, manager.tab_count); // no add
    try std.testing.expect(manager.find_by_id(99) == null);
    try std.testing.expectEqual(@as(?usize, 3), manager.active_idx); // NOT tab 0
}

test "tabwm: + New tab affordance and Ctrl+T trigger the new-tab path (M42 UX)" {
    // The pinned marker the class-B live gate greps.
    try std.testing.expectEqualStrings("tabwm: new-tab\n", new_tab_marker);

    // Ctrl+T summons the launcher.
    manager = TabManager.init();
    overlay_open = false;
    handle_wm_key(usage_t, ui.MOD_CTRL);
    try std.testing.expect(overlay_open);
    overlay_dismiss();

    // Hover lights the pill; click fires the affordance.
    const r = new_tab_pill_rect();
    handle_pointer(r.x + 40, r.y + 10, false);
    try std.testing.expect(hover_new_tab);
    handle_pointer(r.x + 40, r.y + 10, true);
    try std.testing.expect(overlay_open);
    overlay_dismiss();

    // Hit-test ORDER: with max_tabs tabs the '+' pill clamps INTO the
    // tab-row band — the generic row mapping (idx 15) must NOT eat the
    // click; the affordance wins and activation is untouched.
    var id: u32 = 2;
    while (id < 2 + max_tabs) : (id += 1) {
        _ = manager.add_or_update_tab(id, "Filler");
    }
    try std.testing.expect(manager.activate_tab(3));
    const clamped = new_tab_pill_rect();
    try std.testing.expectEqual(@as(u32, 650 - new_tab_pill_h), clamped.y);
    handle_pointer(clamped.x + 40, clamped.y + 10, true);
    try std.testing.expect(overlay_open);
    try std.testing.expectEqual(@as(?usize, 3), manager.active_idx); // no tab-15 hijack
    overlay_dismiss();

    // Empty state: the pill renders in the empty-state area and works there.
    manager = TabManager.init();
    handle_pointer(50, 70, true); // y=62..86 pill band, tab_count == 0
    try std.testing.expect(overlay_open);
    overlay_dismiss();
}

test "tabwm: overlay empty vs filtered-empty messages are distinguishable (M42 UX)" {
    // Empty manifest: no apps installed at all.
    overlay_count = 0;
    overlay_filtered_count = 0;
    try std.testing.expectEqualStrings("no apps installed", overlay_empty_message());
    // Seeded manifest with a filter that has no hits: a different state.
    overlay_seed_catalog();
    try std.testing.expectEqual(@as(usize, 3), overlay_count);
    overlay_filter_len = 3;
    @memcpy(overlay_filter[0..3], "zzz");
    overlay_refresh_filter();
    try std.testing.expectEqual(@as(usize, 0), overlay_filtered_count);
    try std.testing.expectEqualStrings("no matching apps", overlay_empty_message());
}

test "tabwm: close_tab removes the tab and activates the next (M42 UX)" {
    manager = TabManager.init();
    _ = manager.add_or_update_tab(31, "Calc");
    _ = manager.add_or_update_tab(32, "Files");
    activate_tab(0);

    // close_tab always removes the tab and activates the next one (the
    // kernel wmctl seam no-ops on the host; on-device the kernel applies
    // its user_close release and fans the released mirror back, which
    // handle_window_mirror already absorbed — removing an unknown id is a
    // no-op, so the optimistic local removal and the mirror echo agree).
    close_tab(0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expectEqual(@as(?u32, 32), manager.get_active_id());

    // The released mirror for the closed id arrives AFTER the local
    // removal (the kernel answers the seam): absorbed as a no-op.
    handle_window_mirror(31, false, true, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expectEqual(@as(?u32, 32), manager.get_active_id());

    // Closing the last tab empties the manager.
    close_tab(0);
    try std.testing.expectEqual(@as(usize, 0), manager.tab_count);
    try std.testing.expectEqual(@as(?usize, null), manager.active_idx);
}
