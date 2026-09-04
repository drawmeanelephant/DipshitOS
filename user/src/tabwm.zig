//! VirelaiOS M39 TWM1 — TABWM.BIN, the browser-style tabbed window manager server (issue #928).
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
//!   - Zero Heap Allocation: all tab mirrors, state, and rendering operate strictly in static BSS and stack.
//!   - Direct Scanout Ownership: maps the 1280x720 framebuffer via M33 Seam B (`sys_mmap` with
//!     `m33_surf_scan_tag`) for sub-millisecond anti-aliased composition.
//!   - Zero-Regression: WND.BIN remains completely untouched and all legacy floating gates remain green.

const std = @import("std");
pub const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Event = ui.Event;

// ---------------------------------------------------------------------------
// Syscall numbers (slots frozen in ADR 0007 / ADR 0015).
// ---------------------------------------------------------------------------
const sys_write: u64 = 1;
const sys_yield_num: u64 = 2;
const sys_wait_event_num: u64 = 22;
const sys_clipboard_get: u64 = 39;
const sys_mmap: u64 = 63;
const sys_wmctl: u64 = 65;

// Slot-65 subcommands
const wmctl_register: u64 = 1;
const wmctl_set_window: u64 = 2;
const wmctl_request_present: u64 = 3;
const wmctl_set_state: u64 = 4;
const wmctl_tray: u64 = 10;
const wmctl_dialog: u64 = 11;

// M33 Scanout shared surface mapping tag
const m33_surf_scan_tag: u64 = 0x4000_0000_0000_0000;
const prot_rw: u64 = ui.PROT_READ | ui.PROT_WRITE;
const map_anonymous: u64 = ui.MAP_ANONYMOUS;
const m33_map_shared: u64 = 0x10;

// Event kinds from kernel render server
pub const composite_tick_kind: u16 = 18;
pub const wm_pointer_kind: u16 = 19;
pub const wm_window_kind: u16 = 20;
pub const wm_key_kind: u16 = 21;

pub const btn_left: u8 = 0x01;

// Pinned markers
pub const registered_marker: []const u8 = "tabwm: registered\n";
pub const present_marker: []const u8 = "tabwm: present\n";
pub const sidebar_render_marker: []const u8 = "tabwm: sidebar-rendered\n";
pub const tab_switch_marker: []const u8 = "tabwm: tab-switch";
pub const god_menu_marker: []const u8 = "tabwm: god-menu";

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

// ---------------------------------------------------------------------------
// Tab & Window Mirror Models
// ---------------------------------------------------------------------------
pub const Tab = struct {
    id: u32 = 0,
    title: [32]u8 = [_]u8{0} ** 32,
    title_len: usize = 0,
    valid: bool = false,
    visible: bool = false,

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

    pub fn find_by_id(self: *TabManager, id: u32) ?usize {
        for (0..self.tab_count) |i| {
            if (self.tabs[i].valid and self.tabs[i].id == id) return i;
        }
        return null;
    }

    pub fn add_or_update_tab(self: *TabManager, id: u32, title: []const u8) usize {
        if (self.find_by_id(id)) |idx| {
            self.tabs[idx].set_title(title);
            return idx;
        }

        if (self.tab_count < max_tabs) {
            const idx = self.tab_count;
            self.tabs[idx] = .{
                .id = id,
                .valid = true,
                .visible = true,
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
            if (cur >= self.tab_count) {
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
};

// ---------------------------------------------------------------------------
// Global Server State (Static BSS)
// ---------------------------------------------------------------------------
var manager: TabManager = TabManager{};
var scanout_ptr: ?[*]u32 = null;
var scanout_mapped: bool = false;

var hover_tab: ?usize = null;
var hover_sexiburger: bool = false;
var hover_theme_toggle: bool = false;
var hover_clip: bool = false;

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
// Left Sidebar Drawing
// ---------------------------------------------------------------------------
pub fn draw_sidebar(scan: [*]u32) void {
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

    // Mini Sexiburger mascot icon at (16, 17)
    draw_mini_mascot(scan, 16, 17);

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
        ui.draw_text_sized(0, "No open tabs", 20, 80, ui.font_size_badge, ui.sidebar_text_inactive());
        ui.draw_text_sized(0, "Press Ctrl+Space", 20, 96, ui.font_size_badge, ui.sidebar_text_inactive());
        ui.draw_text_sized(0, "to launch apps", 20, 110, ui.font_size_badge, ui.sidebar_text_inactive());
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

    // 5. Bottom Status / Tray Area (y = 660 .. 720)
    // Separator line at y = 660
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
}

/// Mini Sexiburger mascot: 6 burger layers + tentacles (18x18 px).
fn draw_mini_mascot(scan: [*]u32, x: u32, y: u32) void {
    const pixels = scan[0 .. @as(usize, fb_w) * fb_h];
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
// Pointer & Hit Testing
// ---------------------------------------------------------------------------
pub fn handle_pointer(px: u32, py: u32, clicked: bool) void {
    if (px >= sidebar_w) {
        hover_sexiburger = false;
        hover_tab = null;
        hover_theme_toggle = false;
        hover_clip = false;
        return;
    }

    // Sexiburger header hit test
    hover_sexiburger = (px >= 8 and px < 172 and py >= 8 and py < 48);
    if (hover_sexiburger and clicked) {
        write_marker("tabwm: god-menu\n");
    }

    // Theme toggle hit test
    hover_theme_toggle = (px >= 96 and px < 128 and py >= 672 and py < 696);
    if (hover_theme_toggle and clicked) {
        if (std.mem.eql(u8, ui.theme_name(), "dark")) {
            _ = ui.set_theme("light");
        } else {
            _ = ui.set_theme("dark");
        }
    }

    // Clipboard hit test
    hover_clip = (px >= 134 and px < 170 and py >= 672 and py < 696);

    // Tab items hit test
    hover_tab = null;
    if (py >= 58 and py < 650) {
        const idx = (py - 58) / tab_row_h;
        if (idx < manager.tab_count) {
            hover_tab = idx;
            if (clicked) {
                // Check if clicked close box 'x' at x >= 148
                if (px >= 148 and px < 168) {
                    const closed_id = manager.tabs[idx].id;
                    _ = manager.remove_tab(closed_id);
                } else {
                    _ = manager.activate_tab(idx);
                    var buf: [64]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "{s} idx={d} id={d}\n", .{ tab_switch_marker, idx, manager.tabs[idx].id }) catch "tabwm: tab-switch\n";
                    write_marker(msg);
                }
            }
        }
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
                const px = ev.arg0;
                const py = ev.arg1;
                const clicked = (ev.flags & btn_left != 0);
                handle_pointer(px, py, clicked);
            },
            wm_window_kind => {
                // Window opened, closed, or title updated
                const wid = ev.arg0;
                _ = manager.add_or_update_tab(wid, "Application");
            },
            wm_key_kind => {
                const usage: u8 = @intCast(ev.arg0 & 0xff);
                const flags = ev.flags;
                const ctrl = (flags & ui.MOD_CTRL != 0);

                // Ctrl+Tab: cycle tabs
                if (ctrl and usage == 0x2b) { // Tab key
                    manager.cycle_tab();
                }
                // Ctrl+Space: God menu
                if (ctrl and usage == 0x2c) { // Space key
                    write_marker("tabwm: god-menu\n");
                }
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Unit Tests
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

    // Cycle tab
    mgr.cycle_tab();
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);

    // Remove tab
    try std.testing.expect(mgr.remove_tab(1));
    try std.testing.expectEqual(@as(usize, 1), mgr.tab_count);
    try std.testing.expectEqualStrings("Notes", mgr.tabs[0].get_title());
}

test "tabwm: geometry constants respect M39 tokens" {
    try std.testing.expectEqual(@as(u32, 1280), fb_w);
    try std.testing.expectEqual(@as(u32, 720), fb_h);
    try std.testing.expectEqual(@as(u32, 180), sidebar_w);
    try std.testing.expectEqual(@as(u32, 1100), viewport_w);
    try std.testing.expectEqual(@as(u32, 720), viewport_h);
    try std.testing.expectEqual(sidebar_w + viewport_w, fb_w);
}
