//! Button and Label UI widgets (M39 UI1, M41 TS2).
const std = @import("std");
pub const abi = @import("../abi.zig");
pub const theme = @import("../theme.zig");
pub const draw = @import("../draw.zig");

// ABI types & constants
const Event = abi.Event;
const MOUSE_MOVE = abi.MOUSE_MOVE;
const MOUSE_DOWN = abi.MOUSE_DOWN;
const MOUSE_UP = abi.MOUSE_UP;

// Theme tokens & styling
const COLOR_TEXT_PRIMARY = theme.COLOR_TEXT_PRIMARY;
const WidgetState = theme.WidgetState;
const border_w = theme.border_w;
const live_color = theme.live_color;
const theme_accent = theme.theme_accent;
const theme_on_accent = theme.theme_on_accent;
const theme_text_primary = theme.theme_text_primary;
const widget_bg = theme.widget_bg;
const widget_border = theme.widget_border;
const widget_text = theme.widget_text;

// Draw operations
const Rect = draw.Rect;
const draw_rect = draw.draw_rect;
const draw_rect_outline = draw.draw_rect_outline;
const draw_text = draw.draw_text;
const draw_text_centered = draw.draw_text_centered;

// ---------------------------------------------------------------------------
// Component: Button
// ---------------------------------------------------------------------------

pub const ButtonState = enum {
    idle,
    hover,
    pressed,
    disabled,
    focused,
    normal,
    hovered,

    pub fn to_widget_state(self: ButtonState) WidgetState {
        return switch (self) {
            .idle, .normal => .normal,
            .hover, .hovered => .hover,
            .pressed => .pressed,
            .disabled => .disabled,
            .focused => .focused,
        };
    }
};

pub const Button = struct {
    rect: Rect,
    label: []const u8,
    state: ButtonState = .idle,
    bg_color: ?u32 = null,
    text_color: u32 = 0xffffff,
    is_active: bool = false,

    pub fn init(rect: Rect, label: []const u8) Button {
        return .{
            .rect = rect,
            .label = label,
        };
    }

    pub fn handle_event(self: *Button, ev: *const Event) bool {
        switch (ev.kind) {
            MOUSE_MOVE => {
                const inside = self.rect.contains(ev.arg0, ev.arg1);
                if (inside) {
                    if (self.state == .idle) self.state = .hover;
                } else {
                    self.state = .idle;
                }
                return false;
            },
            MOUSE_DOWN => {
                const inside = self.rect.contains(ev.arg0, ev.arg1);
                if (inside) {
                    self.state = .pressed;
                } else {
                    self.state = .idle;
                }
                return false;
            },
            MOUSE_UP => {
                const was_pressed = (self.state == .pressed);
                const inside = self.rect.contains(ev.arg0, ev.arg1);
                self.state = if (inside) .hover else .idle;
                return was_pressed and inside;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const Button, win_id: u32) void {
        const ws = self.state.to_widget_state();
        // M37 DQ4: legacy frozen COLOR_* resolve live so every app follows
        // the desktop theme with no per-app button churn.
        const bg = if (self.is_active)
            theme_accent()
        else if (self.bg_color) |c|
            live_color(c)
        else
            widget_bg(ws);

        const border = if (self.is_active)
            theme_text_primary()
        else
            widget_border(ws);

        // Default text follows the surface it sits on: text-over-accent on
        // accent fills, theme text otherwise. An explicitly pinned color
        // (anything but the legacy white default) always wins.
        const on_accent_bg = self.is_active or
            (if (self.bg_color) |c| live_color(c) == theme_accent() else false);
        const text_col = if (self.text_color != COLOR_TEXT_PRIMARY)
            self.text_color
        else if (self.state == .disabled)
            widget_text(ws)
        else if (on_accent_bg)
            theme_on_accent()
        else
            widget_text(ws);

        draw_rect(win_id, self.rect, bg);
        draw_rect_outline(win_id, self.rect, border_w, border);
        draw_text_centered(win_id, self.label, self.rect, text_col);
    }
};

// ---------------------------------------------------------------------------
// Component: Label
// ---------------------------------------------------------------------------

pub const Label = struct {
    rect: Rect,
    text: []const u8,
    color: u32 = 0xffffff,
    align_center: bool = false,

    pub fn init(rect: Rect, text: []const u8) Label {
        return .{
            .rect = rect,
            .text = text,
        };
    }

    pub fn draw(self: *const Label, win_id: u32) void {
        // M37 DQ4: the legacy white default resolves live (dark identical).
        const col = if (self.color == COLOR_TEXT_PRIMARY) theme_text_primary() else self.color;
        if (self.align_center) {
            draw_text_centered(win_id, self.text, self.rect, col);
        } else {
            draw_text(win_id, self.text, self.rect.x, self.rect.y + (self.rect.h - 8) / 2, col);
        }
    }
};
