//! ProgressBar UI widget (GH #220, Arc1, M41 TS2).
const std = @import("std");
pub const abi = @import("../abi.zig");
pub const theme = @import("../theme.zig");
pub const draw = @import("../draw.zig");

// ABI types & constants
const Event = abi.Event;
const EVENT_TIMER = abi.EVENT_TIMER;

// Theme tokens & styling
const theme_accent = theme.theme_accent;
const theme_border = theme.theme_border;
const theme_surface = theme.theme_surface;
const theme_text_primary = theme.theme_text_primary;

// Draw operations
const Rect = draw.Rect;
const draw_char = draw.draw_char;
const draw_rect = draw.draw_rect;
const draw_rect_outline = draw.draw_rect_outline;

// ---------------------------------------------------------------------------
// Component: ProgressBar — determinate + indeterminate (GH #220, Arc1)
// ---------------------------------------------------------------------------

pub const ProgressBar = struct {
    rect: Rect,
    value: f32 = 0.0,
    label: []const u8 = "",
    indeterminate: bool = false,
    offset: i32 = 0,
    dir: i32 = 1,

    pub const indeterminate_width: u32 = 20;
    pub const indeterminate_step: i32 = 4;

    pub fn init(rect: Rect) ProgressBar {
        return .{ .rect = rect };
    }

    pub fn initWithValue(rect: Rect, value: f32) ProgressBar {
        var pb = ProgressBar.init(rect);
        pb.set_value(value);
        return pb;
    }

    pub fn set_value(self: *ProgressBar, v: f32) void {
        if (std.math.isNan(v) or std.math.isInf(v)) {
            self.value = if (v > 0 and std.math.isInf(v)) 1.0 else 0.0;
            if (std.math.isNan(v)) self.value = 0.0;
            return;
        }
        if (v < 0.0) {
            self.value = 0.0;
        } else if (v > 1.0) {
            self.value = 1.0;
        } else {
            self.value = v;
        }
    }

    pub fn set_label(self: *ProgressBar, text: []const u8) void {
        self.label = text;
    }

    pub fn set_indeterminate(self: *ProgressBar, enabled: bool) void {
        self.indeterminate = enabled;
        if (enabled) {
            self.offset = 0;
            self.dir = 1;
        }
    }

    pub fn inner_rect(self: *const ProgressBar) Rect {
        if (self.rect.w <= 2 or self.rect.h <= 2) return Rect.make(self.rect.x, self.rect.y, 0, 0);
        return Rect.make(self.rect.x + 1, self.rect.y + 1, self.rect.w - 2, self.rect.h - 2);
    }

    pub fn fill_width(self: *const ProgressBar) u32 {
        const inner = self.inner_rect();
        if (inner.w == 0) return 0;
        const clamped = if (self.value < 0.0) @as(f32, 0.0) else if (self.value > 1.0) @as(f32, 1.0) else self.value;
        const fw: f32 = @as(f32, @floatFromInt(inner.w)) * clamped;
        return @as(u32, @intFromFloat(@floor(fw)));
    }

    /// Max offset for the sliding block inside inner rect (inner_w - block_w).
    pub fn max_offset(self: *const ProgressBar) i32 {
        const inner = self.inner_rect();
        if (inner.w <= indeterminate_width) return 0;
        return @as(i32, @intCast(inner.w - indeterminate_width));
    }

    /// Advance indeterminate animation by one TIMER tick. Returns true if moved.
    pub fn tick(self: *ProgressBar) bool {
        if (!self.indeterminate) return false;
        const max = self.max_offset();
        if (max == 0) return false;
        self.offset += self.dir * indeterminate_step;
        if (self.offset >= max) {
            self.offset = max;
            self.dir = -1;
        } else if (self.offset <= 0) {
            self.offset = 0;
            self.dir = 1;
        }
        return true;
    }

    pub fn handle_event(self: *ProgressBar, ev: *const Event) bool {
        if (!self.indeterminate) return false;
        if (ev.kind != EVENT_TIMER) return false;
        return self.tick();
    }

    /// Test helper: is the i-th label character centered over the fill/block?
    pub fn is_label_char_over_fill(self: *const ProgressBar, char_idx: usize) bool {
        if (self.label.len == 0 or char_idx >= self.label.len) return false;
        const inner = self.inner_rect();
        const text_w = @as(u32, @intCast(self.label.len)) * 8;
        const label_x = if (self.rect.w > text_w) self.rect.x + (self.rect.w - text_w) / 2 else self.rect.x;
        const char_x = label_x + @as(u32, @intCast(char_idx)) * 8;
        const char_center = char_x + 4;
        if (self.indeterminate) {
            const block_x = @as(i32, @intCast(inner.x)) + self.offset;
            const block_x_u: u32 = if (block_x < 0) 0 else @as(u32, @intCast(block_x));
            return char_center >= block_x_u and char_center < block_x_u + indeterminate_width;
        } else {
            const fw = self.fill_width();
            if (fw == 0) return false;
            const fill_end = inner.x + fw;
            return char_center < fill_end;
        }
    }

    pub fn draw(self: *const ProgressBar, win_id: u32) void {
        // Background + border
        draw_rect(win_id, self.rect, theme_surface());
        draw_rect_outline(win_id, self.rect, 1, theme_border());
        const inner = self.inner_rect();
        if (inner.w == 0 or inner.h == 0) return;

        if (self.indeterminate) {
            const block_x_i: i32 = @as(i32, @intCast(inner.x)) + self.offset;
            const block_x: u32 = if (block_x_i < 0) inner.x else @as(u32, @intCast(block_x_i));
            // Clamp block inside inner
            const clamped_x = @min(block_x, inner.x + inner.w - indeterminate_width);
            const block_rect = Rect.make(clamped_x, inner.y, indeterminate_width, inner.h);
            draw_rect(win_id, block_rect, theme_accent());
        } else {
            const fw = self.fill_width();
            if (fw > 0) {
                const fill_rect = Rect.make(inner.x, inner.y, fw, inner.h);
                draw_rect(win_id, fill_rect, theme_accent());
            }
        }

        // Centered label with contrast inversion per character.
        if (self.label.len > 0) {
            const text_w = @as(u32, @intCast(self.label.len)) * 8;
            const text_h: u32 = 8;
            const lx = if (self.rect.w > text_w) self.rect.x + (self.rect.w - text_w) / 2 else self.rect.x;
            const ly = if (self.rect.h > text_h) self.rect.y + (self.rect.h - text_h) / 2 else self.rect.y;
            var i: usize = 0;
            while (i < self.label.len) : (i += 1) {
                const ch = self.label[i];
                const char_x = lx + @as(u32, @intCast(i)) * 8;
                const over_fill = self.is_label_char_over_fill(i);
                // Over fill/block: white for high contrast on accent; over bg: theme text primary.
                const fg: u32 = if (over_fill) 0xffffff else theme_text_primary();
                draw_char(win_id, ch, char_x, ly, fg);
            }
        }
    }
};
