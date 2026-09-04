//! DropDown UI widget (M39 UI1, M41 TS2).
const std = @import("std");
pub const abi = @import("../abi.zig");
pub const theme = @import("../theme.zig");
pub const draw = @import("../draw.zig");

// ABI types & constants
const Event = abi.Event;
const MOUSE_DOWN = abi.MOUSE_DOWN;
const MOUSE_MOVE = abi.MOUSE_MOVE;
const KEY_DOWN = abi.KEY_DOWN;
const win_fill = abi.win_fill;

// Theme tokens & styling
const theme_accent = theme.theme_accent;
const theme_border = theme.theme_border;
const theme_btn_hover = theme.theme_btn_hover;
const theme_btn_idle = theme.theme_btn_idle;
const theme_btn_pressed = theme.theme_btn_pressed;
const theme_surface = theme.theme_surface;
const theme_text_muted = theme.theme_text_muted;
const theme_text_primary = theme.theme_text_primary;

// Draw operations
const Rect = draw.Rect;
const draw_rect = draw.draw_rect;
const draw_rect_outline = draw.draw_rect_outline;
const draw_text = draw.draw_text;

// ---------------------------------------------------------------------------
// Component: DropDown
// ---------------------------------------------------------------------------

pub const DropDown = struct {
    rect: Rect,
    options: []const []const u8,
    selected: usize = 0,
    open: bool = false,
    hover_idx: ?usize = null,
    row_height: u32 = 16,
    max_visible: u32 = 6,

    pub fn init(rect: Rect, options: []const []const u8) DropDown {
        return .{ .rect = rect, .options = options };
    }

    pub fn selected_text(self: *const DropDown) []const u8 {
        if (self.selected < self.options.len) return self.options[self.selected];
        return "";
    }

    pub fn set_selected_by_name(self: *DropDown, name: []const u8) void {
        for (self.options, 0..) |opt, i| {
            if (eql_str(opt, name)) {
                self.selected = i;
                return;
            }
        }
    }

    fn eql_str(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            if (ca != cb) return false;
        }
        return true;
    }

    fn overlay_rect(self: *const DropDown) Rect {
        const visible = @min(@as(u32, @intCast(self.options.len)), self.max_visible);
        return Rect.make(self.rect.x, self.rect.y + self.rect.h, self.rect.w, visible * self.row_height);
    }

    fn hit_test_overlay(self: *const DropDown, px: u32, py: u32) ?usize {
        if (!self.open) return null;
        const ov = self.overlay_rect();
        if (!ov.contains(px, py)) return null;
        const rel_y = py - ov.y;
        const idx = rel_y / self.row_height;
        if (idx < self.options.len) return idx;
        return null;
    }

    pub fn handle_event(self: *DropDown, ev: *const Event) bool {
        switch (ev.kind) {
            MOUSE_DOWN => {
                if (self.open) {
                    if (self.hit_test_overlay(ev.arg0, ev.arg1)) |idx| {
                        self.selected = idx;
                        self.open = false;
                        self.hover_idx = null;
                        return true;
                    }
                    self.open = false;
                    self.hover_idx = null;
                }
                if (self.rect.contains(ev.arg0, ev.arg1)) {
                    self.open = true;
                    return false;
                }
                return false;
            },
            MOUSE_MOVE => {
                if (self.open) {
                    self.hover_idx = self.hit_test_overlay(ev.arg0, ev.arg1);
                }
                return false;
            },
            KEY_DOWN => {
                if (!self.open) return false;
                const keycode = ev.arg0;
                // Up arrow (0x52)
                if (keycode == 0x52) {
                    if (self.selected > 0) {
                        self.selected -= 1;
                        return true;
                    }
                }
                // Down arrow (0x51)
                if (keycode == 0x51) {
                    if (self.selected + 1 < self.options.len) {
                        self.selected += 1;
                        return true;
                    }
                }
                // Enter (0x28) or Escape (0x29)
                if (keycode == 0x28 or keycode == 0x29) {
                    self.open = false;
                    self.hover_idx = null;
                    return false;
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const DropDown, win_id: u32) void {
        // Button body.
        const bg = if (self.open) theme_btn_pressed() else theme_btn_idle();
        draw_rect(win_id, self.rect, bg);
        draw_rect_outline(win_id, self.rect, 1, if (self.open) theme_accent() else theme_border());
        draw_text(win_id, self.selected_text(), self.rect.x + 4, self.rect.y + (self.rect.h - 8) / 2, theme_text_primary());
        // Down arrow indicator.
        const ax = self.rect.x + self.rect.w - 12;
        const ay = self.rect.y + (self.rect.h - 4) / 2;
        win_fill(win_id, ax, ay, 6, 2, theme_text_muted());
        win_fill(win_id, ax + 1, ay + 2, 4, 2, theme_text_muted());
        win_fill(win_id, ax + 2, ay + 4, 2, 2, theme_text_muted());

        // Dropdown overlay.
        if (self.open) {
            const ov = self.overlay_rect();
            draw_rect(win_id, ov, theme_surface());
            draw_rect_outline(win_id, ov, 1, theme_border());
            var i: u32 = 0;
            while (i < self.options.len and i < self.max_visible) : (i += 1) {
                const row_y = ov.y + i * self.row_height;
                const row_bg = if (self.hover_idx != null and self.hover_idx.? == i)
                    theme_btn_hover()
                else if (i == self.selected)
                    theme_accent()
                else
                    theme_surface();
                win_fill(win_id, ov.x + 1, row_y, ov.w - 2, self.row_height, row_bg);
                draw_text(win_id, self.options[i], ov.x + 4, row_y + (self.row_height - 8) / 2, theme_text_primary());
            }
        }
    }
};
