//! Checkbox and Toggle UI widgets (GH #219, Arc1, M41 TS2).
const std = @import("std");
pub const abi = @import("../abi.zig");
pub const theme = @import("../theme.zig");
pub const draw = @import("../draw.zig");

// ABI types & constants
const Event = abi.Event;
const BTN_LEFT = abi.BTN_LEFT;
const MOUSE_DOWN = abi.MOUSE_DOWN;
const win_fill = abi.win_fill;

// Theme tokens & styling
const theme_accent = theme.theme_accent;
const theme_border = theme.theme_border;
const theme_surface = theme.theme_surface;

// Draw operations
const Rect = draw.Rect;
const draw_rect = draw.draw_rect;
const draw_rect_outline = draw.draw_rect_outline;

// ---------------------------------------------------------------------------
// Component: Checkbox — 12×12 boolean (GH #219, Arc1)
// ---------------------------------------------------------------------------

pub const Checkbox = struct {
    rect: Rect,
    checked: *bool,

    pub fn init(rect: Rect, checked: *bool) Checkbox {
        return .{ .rect = rect, .checked = checked };
    }

    pub fn handle_event(self: *Checkbox, ev: *const Event) bool {
        if (ev.kind != MOUSE_DOWN) return false;
        if ((ev.flags & BTN_LEFT) == 0) return false;
        if (!self.rect.contains(ev.arg0, ev.arg1)) return false;
        self.checked.* = !self.checked.*;
        return true;
    }

    pub fn draw(self: *const Checkbox, win_id: u32) void {
        // Box outline
        draw_rect(win_id, self.rect, theme_surface());
        draw_rect_outline(win_id, self.rect, 1, theme_border());
        if (self.checked.*) {
            // Filled inner square (inset 3) in accent
            const inner = self.rect.inset(3, 3);
            // Clamp to at least 6×6 for 12×12 box -> 6×6 inner
            win_fill(win_id, inner.x, inner.y, inner.w, inner.h, theme_accent());
        }
    }
};

// ---------------------------------------------------------------------------
// Component: Toggle — 48×20 pill boolean (GH #219, Arc1)
// ---------------------------------------------------------------------------

pub const Toggle = struct {
    rect: Rect,
    enabled: *bool,

    pub fn init(rect: Rect, enabled: *bool) Toggle {
        return .{ .rect = rect, .enabled = enabled };
    }

    pub fn handle_event(self: *Toggle, ev: *const Event) bool {
        if (ev.kind != MOUSE_DOWN) return false;
        if ((ev.flags & BTN_LEFT) == 0) return false;
        if (!self.rect.contains(ev.arg0, ev.arg1)) return false;
        self.enabled.* = !self.enabled.*;
        return true;
    }

    pub fn draw(self: *const Toggle, win_id: u32) void {
        // Pill background
        const bg = if (self.enabled.*) theme_accent() else theme_border();
        draw_rect(win_id, self.rect, bg);
        // Knob: 16×16 circle approximated as square, inset 2, left or right
        const knob_w: u32 = 16;
        const knob_h: u32 = 16;
        const knob_y = self.rect.y + (self.rect.h - knob_h) / 2;
        const knob_x = if (self.enabled.*)
            self.rect.x + self.rect.w - knob_w - 2
        else
            self.rect.x + 2;
        // Knob in surface (contrasts with accent/border bg)
        win_fill(win_id, knob_x, knob_y, knob_w, knob_h, theme_surface());
        draw_rect_outline(win_id, Rect.make(knob_x, knob_y, knob_w, knob_h), 1, theme_border());
    }
};
