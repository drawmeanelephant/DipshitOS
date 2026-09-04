//! TextInput UI widget (M39 UI1, M41 TS2).
const std = @import("std");
pub const abi = @import("../abi.zig");
pub const theme = @import("../theme.zig");
pub const draw = @import("../draw.zig");

// ABI types & constants
const Event = abi.Event;
const MOUSE_DOWN = abi.MOUSE_DOWN;
const KEY_DOWN = abi.KEY_DOWN;
const win_fill = abi.win_fill;

// Theme tokens & styling
const border_w = theme.border_w;
const caret_h = theme.caret_h;
const caret_w = theme.caret_w;
const pad_sm = theme.pad_sm;
const theme_accent = theme.theme_accent;
const theme_border = theme.theme_border;
const theme_caret = theme.theme_caret;
const theme_surface = theme.theme_surface;
const theme_text_primary = theme.theme_text_primary;

// Draw operations
const Rect = draw.Rect;
const draw_rect = draw.draw_rect;
const draw_rect_outline = draw.draw_rect_outline;
const draw_text = draw.draw_text;
const measure_text = draw.measure_text;

// ---------------------------------------------------------------------------
// Component: TextInput
// ---------------------------------------------------------------------------

pub const TextInput = struct {
    rect: Rect,
    buf: [128]u8 = [_]u8{0} ** 128,
    len: usize = 0,
    cursor: usize = 0,
    focused: bool = false,

    pub fn init(rect: Rect) TextInput {
        return .{ .rect = rect };
    }

    pub fn get_text(self: *const TextInput) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set_text(self: *TextInput, text: []const u8) void {
        const copy_len = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..copy_len], text[0..copy_len]);
        self.len = copy_len;
        self.cursor = copy_len;
    }

    pub fn clear(self: *TextInput) void {
        self.len = 0;
        self.cursor = 0;
    }

    pub fn handle_event(self: *TextInput, ev: *const Event) bool {
        switch (ev.kind) {
            MOUSE_DOWN => {
                const inside = self.rect.contains(ev.arg0, ev.arg1);
                const prev = self.focused;
                self.focused = inside;
                if (inside) {
                    const click_x = ev.arg0;
                    const text_x = self.rect.x + pad_sm;
                    if (click_x <= text_x) {
                        self.cursor = 0;
                    } else {
                        const rel_x = click_x - text_x;
                        const text = self.get_text();
                        var best_cursor: usize = 0;
                        var cur_w: u32 = 0;
                        while (best_cursor < text.len) {
                            const next_w = measure_text(text[0 .. best_cursor + 1]);
                            if (next_w > rel_x) {
                                if (rel_x - cur_w < next_w - rel_x) {
                                    break;
                                } else {
                                    best_cursor += 1;
                                    break;
                                }
                            }
                            cur_w = next_w;
                            best_cursor += 1;
                        }
                        self.cursor = best_cursor;
                    }
                }
                return prev != self.focused;
            },
            KEY_DOWN => {
                if (!self.focused) return false;
                const keycode = ev.arg0;
                const ascii_char = @as(u8, @truncate(ev.arg1));

                // Backspace (ASCII 0x08 or keycode 0x2a)
                if (ascii_char == 0x08 or keycode == 0x2a) {
                    if (self.cursor > 0 and self.len > 0) {
                        var i = self.cursor - 1;
                        while (i < self.len - 1) : (i += 1) {
                            self.buf[i] = self.buf[i + 1];
                        }
                        self.len -= 1;
                        self.cursor -= 1;
                        return true;
                    }
                    return false;
                }

                // Printable character insertion
                if (ascii_char >= 0x20 and ascii_char <= 0x7e) {
                    if (self.len < self.buf.len) {
                        var i = self.len;
                        while (i > self.cursor) : (i -= 1) {
                            self.buf[i] = self.buf[i - 1];
                        }
                        self.buf[self.cursor] = ascii_char;
                        self.len += 1;
                        self.cursor += 1;
                        return true;
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const TextInput, win_id: u32) void {
        draw_rect(win_id, self.rect, theme_surface());
        draw_rect_outline(win_id, self.rect, border_w, if (self.focused) theme_accent() else theme_border());

        const text_y = self.rect.y + (self.rect.h - 8) / 2;
        const text_x = self.rect.x + pad_sm;
        draw_text(win_id, self.get_text(), text_x, text_y, theme_text_primary());

        // M37 DQ4 / M38 TT2: caret bar from tokens (proportional metrics aware).
        if (self.focused) {
            const prefix = self.get_text()[0..self.cursor];
            const cursor_x = text_x + measure_text(prefix);
            if (cursor_x + caret_w <= self.rect.x + self.rect.w) {
                win_fill(win_id, cursor_x, text_y, caret_w, caret_h, theme_caret());
            }
        }
    }
};
