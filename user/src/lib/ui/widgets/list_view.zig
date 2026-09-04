//! ListView UI widget (M39 UI1, M41 TS2).
const std = @import("std");
pub const abi = @import("../abi.zig");
pub const theme = @import("../theme.zig");
pub const draw = @import("../draw.zig");

// ABI types & constants
const Event = abi.Event;
const MOUSE_DOWN = abi.MOUSE_DOWN;
const KEY_DOWN = abi.KEY_DOWN;

// Theme tokens & styling
const theme_accent = theme.theme_accent;
const theme_bg = theme.theme_bg;
const theme_surface = theme.theme_surface;
const theme_on_accent = theme.theme_on_accent;
const theme_text_primary = theme.theme_text_primary;

// Draw operations
const Rect = draw.Rect;
const draw_rect = draw.draw_rect;
const draw_text = draw.draw_text;

// ---------------------------------------------------------------------------
// Component: ListView
// ---------------------------------------------------------------------------

pub const ListView = struct {
    rect: Rect,
    row_height: u32 = 14,
    selected_idx: ?usize = null,
    item_count: usize = 0,

    pub fn init(rect: Rect, row_height: u32) ListView {
        return .{
            .rect = rect,
            .row_height = row_height,
        };
    }

    pub fn handle_event(self: *ListView, ev: *const Event) bool {
        switch (ev.kind) {
            MOUSE_DOWN => {
                if (self.rect.contains(ev.arg0, ev.arg1)) {
                    const rel_y = ev.arg1 - self.rect.y;
                    const clicked_row = rel_y / self.row_height;
                    if (clicked_row < self.item_count) {
                        const prev = self.selected_idx;
                        self.selected_idx = clicked_row;
                        return prev != self.selected_idx;
                    }
                }
                return false;
            },
            KEY_DOWN => {
                const keycode = ev.arg0;
                // Up arrow (keycode 0x52)
                if (keycode == 0x52) {
                    if (self.selected_idx) |idx| {
                        if (idx > 0) {
                            self.selected_idx = idx - 1;
                            return true;
                        }
                    } else if (self.item_count > 0) {
                        self.selected_idx = 0;
                        return true;
                    }
                }
                // Down arrow (keycode 0x51)
                if (keycode == 0x51) {
                    if (self.selected_idx) |idx| {
                        if (idx + 1 < self.item_count) {
                            self.selected_idx = idx + 1;
                            return true;
                        }
                    } else if (self.item_count > 0) {
                        self.selected_idx = 0;
                        return true;
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn draw_row(self: *const ListView, win_id: u32, row: usize, text: []const u8, is_selected: bool) void {
        const row_y = self.rect.y + @as(u32, @intCast(row)) * self.row_height;
        if (row_y + self.row_height > self.rect.y + self.rect.h) return;

        const row_rect = Rect.make(self.rect.x, row_y, self.rect.w, self.row_height);
        const bg = if (is_selected)
            theme_accent()
        else if (row % 2 == 0)
            theme_surface()
        else
            theme_bg();

        draw_rect(win_id, row_rect, bg);
        const text_y = row_rect.y + (if (self.row_height > 12) (self.row_height - 12) / 2 else 0);
        draw_text(win_id, text, row_rect.x + 4, text_y, if (is_selected) theme_on_accent() else theme_text_primary());
    }
};
