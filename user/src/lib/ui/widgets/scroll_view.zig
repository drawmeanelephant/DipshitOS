//! ScrollView and HScrollBar UI widgets (GH #218, #222, Arc1, M41 TS2).
const std = @import("std");
pub const abi = @import("../abi.zig");
pub const theme = @import("../theme.zig");
pub const draw = @import("../draw.zig");

// ABI types & constants
const Event = abi.Event;
const MOUSE_DOWN = abi.MOUSE_DOWN;
const MOUSE_MOVE = abi.MOUSE_MOVE;
const MOUSE_UP = abi.MOUSE_UP;
const KEY_DOWN = abi.KEY_DOWN;
const MOD_SHIFT = abi.MOD_SHIFT;
const win_fill = abi.win_fill;

// Theme tokens & styling
const theme_accent = theme.theme_accent;
const theme_border = theme.theme_border;

// Draw operations
const Rect = draw.Rect;
const draw_rect = draw.draw_rect;

pub const MOUSE_SCROLL: u16 = 12;

// ---------------------------------------------------------------------------
// Component: ScrollView — vertical scroll container (GH #218, Arc1)
// ---------------------------------------------------------------------------

pub const ScrollView = struct {
    rect: Rect,
    content_h: u32,
    offset: u32 = 0,
    dragging: bool = false,
    drag_start_y: u32 = 0,
    drag_start_offset: u32 = 0,

    const scrollbar_w: u32 = 6;
    const thumb_min_h: u32 = 16;

    pub fn init(rect: Rect, content_h: u32) ScrollView {
        var sv = ScrollView{ .rect = rect, .content_h = content_h };
        sv.clamp_offset();
        return sv;
    }

    pub fn set_content_height(self: *ScrollView, h: u32) void {
        self.content_h = h;
        self.clamp_offset();
    }

    pub fn max_offset(self: *const ScrollView) u32 {
        if (self.content_h <= self.rect.h) return 0;
        return self.content_h - self.rect.h;
    }

    fn clamp_offset(self: *ScrollView) void {
        const m = self.max_offset();
        if (self.offset > m) self.offset = m;
    }

    pub fn thumb_h(self: *const ScrollView) u32 {
        if (self.content_h <= self.rect.h) return self.rect.h;
        const visible = self.rect.h;
        const content = self.content_h;
        const proportional = visible * visible / content;
        return @max(thumb_min_h, proportional);
    }

    pub fn thumb_y(self: *const ScrollView) u32 {
        const m = self.max_offset();
        if (m == 0) return self.rect.y;
        const th = self.thumb_h();
        const track_h = self.rect.h - th;
        // offset * track_h / max_offset, rounded down
        return self.rect.y + (self.offset * track_h / m);
    }

    pub fn thumb_rect(self: *const ScrollView) Rect {
        if (self.content_h <= self.rect.h) return self.rect;
        const th = self.thumb_h();
        const ty = self.thumb_y();
        return Rect.make(self.rect.x + self.rect.w - scrollbar_w, ty, scrollbar_w, th);
    }

    fn track_contains(self: *const ScrollView, px: u32, py: u32) bool {
        const track = Rect.make(self.rect.x + self.rect.w - scrollbar_w, self.rect.y, scrollbar_w, self.rect.h);
        return track.contains(px, py);
    }

    pub fn scroll_by(self: *ScrollView, delta: i32) void {
        const m: i32 = @intCast(self.max_offset());
        var off: i32 = @intCast(self.offset);
        off += delta;
        if (off < 0) off = 0;
        if (off > m) off = m;
        self.offset = @intCast(off);
    }

    pub fn handle_event(self: *ScrollView, ev: *const Event) bool {
        if (self.content_h <= self.rect.h) return false;
        switch (ev.kind) {
            MOUSE_DOWN => {
                const px = ev.arg0;
                const py = ev.arg1;
                if (!self.rect.contains(px, py)) return false;
                const tr = self.thumb_rect();
                if (tr.contains(px, py)) {
                    self.dragging = true;
                    self.drag_start_y = py;
                    self.drag_start_offset = self.offset;
                    return true;
                }
                if (self.track_contains(px, py)) {
                    // Click on track outside thumb — page up/down
                    const ty = self.thumb_y();
                    if (py < ty) {
                        self.scroll_by(-@as(i32, @intCast(self.rect.h)));
                    } else {
                        self.scroll_by(@as(i32, @intCast(self.rect.h)));
                    }
                    return true;
                }
                return false;
            },
            MOUSE_MOVE => {
                if (!self.dragging) return false;
                const py: i32 = @intCast(ev.arg1);
                const start_y: i32 = @intCast(self.drag_start_y);
                const delta: i32 = py - start_y;
                const m = self.max_offset();
                if (m == 0) return false;
                const th = self.thumb_h();
                const track_h: i32 = @intCast(self.rect.h - th);
                if (track_h <= 0) return false;
                // Scale thumb drag to content offset: delta * max_offset / track_h
                const scaled = @divTrunc(delta * @as(i32, @intCast(m)), track_h);
                var new_off: i32 = @as(i32, @intCast(self.drag_start_offset)) + scaled;
                if (new_off < 0) new_off = 0;
                if (new_off > @as(i32, @intCast(m))) new_off = @intCast(m);
                self.offset = @intCast(new_off);
                return true;
            },
            MOUSE_UP => {
                if (self.dragging) {
                    self.dragging = false;
                    return true;
                }
                return false;
            },
            KEY_DOWN => {
                const keycode = ev.arg0;
                // PageUp 0x4b, PageDown 0x4e (from notepad.zig), also handle wheel if present
                if (keycode == 0x4b) { // PageUp
                    self.scroll_by(-@as(i32, @intCast(self.rect.h)));
                    return true;
                }
                if (keycode == 0x4e) { // PageDown
                    self.scroll_by(@as(i32, @intCast(self.rect.h)));
                    return true;
                }
                return false;
            },
            MOUSE_SCROLL => {
                // Arc4 #236: arg0 packed per ADR 0013 D2.
                // bits 0–13 = magnitude, bit 14 = horizontal, bit 15 = sign.
                const raw = ev.arg0;
                const horizontal = (raw & 0x4000) != 0;
                if (horizontal) return false; // vertical-only ScrollView
                const magnitude: i32 = @intCast(raw & 0x1fff);
                if (magnitude == 0) return false;
                const sign: i32 = if ((raw & 0x8000) != 0) 1 else -1;
                const step = sign * magnitude * 16;
                self.scroll_by(step);
                return true;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const ScrollView, win_id: u32) void {
        if (self.content_h <= self.rect.h) return;
        // Track
        const track_x = self.rect.x + self.rect.w - scrollbar_w;
        draw_rect(win_id, Rect.make(track_x, self.rect.y, scrollbar_w, self.rect.h), theme_border());
        // Thumb
        const tr = self.thumb_rect();
        // Thumb as accent, with 1px inset for rounded feel
        win_fill(win_id, tr.x, tr.y, tr.w, tr.h, theme_accent());
    }
};

// ---------------------------------------------------------------------------
// Component: HScrollBar — horizontal scroll track (GH #222, Arc1)
// ---------------------------------------------------------------------------

pub const HScrollBar = struct {
    rect: Rect,
    content_w: u32,
    viewport_w: u32,
    offset: u32 = 0,
    dragging: bool = false,
    drag_start_x: u32 = 0,
    drag_start_offset: u32 = 0,

    pub const track_h: u32 = 8;
    pub const thumb_min_w: u32 = 16;

    pub fn init(rect: Rect, content_w: u32, viewport_w: u32) HScrollBar {
        var hb = HScrollBar{ .rect = rect, .content_w = content_w, .viewport_w = viewport_w };
        hb.clamp_offset();
        return hb;
    }

    pub fn set_content_width(self: *HScrollBar, w: u32) void {
        self.content_w = w;
        self.clamp_offset();
    }

    pub fn set_viewport_width(self: *HScrollBar, w: u32) void {
        self.viewport_w = w;
        self.clamp_offset();
    }

    pub fn max_offset(self: *const HScrollBar) u32 {
        if (self.content_w <= self.viewport_w) return 0;
        return self.content_w - self.viewport_w;
    }

    fn clamp_offset(self: *HScrollBar) void {
        const m = self.max_offset();
        if (self.offset > m) self.offset = m;
    }

    pub fn thumb_w(self: *const HScrollBar) u32 {
        if (self.content_w <= self.viewport_w) return self.rect.w;
        const visible = self.viewport_w;
        const content = self.content_w;
        const proportional = self.rect.w * visible / content;
        return @max(thumb_min_w, proportional);
    }

    pub fn thumb_x(self: *const HScrollBar) u32 {
        const m = self.max_offset();
        if (m == 0) return self.rect.x;
        const tw = self.thumb_w();
        const track_w = self.rect.w - tw;
        return self.rect.x + (self.offset * track_w / m);
    }

    pub fn thumb_rect(self: *const HScrollBar) Rect {
        if (self.content_w <= self.viewport_w) return self.rect;
        const tw = self.thumb_w();
        const tx = self.thumb_x();
        return Rect.make(tx, self.rect.y, tw, self.rect.h);
    }

    fn track_contains(self: *const HScrollBar, px: u32, py: u32) bool {
        return self.rect.contains(px, py);
    }

    pub fn scroll_by(self: *HScrollBar, delta: i32) void {
        const m: i32 = @intCast(self.max_offset());
        var off: i32 = @intCast(self.offset);
        off += delta;
        if (off < 0) off = 0;
        if (off > m) off = m;
        self.offset = @intCast(off);
    }

    pub fn handle_event(self: *HScrollBar, ev: *const Event) bool {
        if (self.content_w <= self.viewport_w) return false;
        switch (ev.kind) {
            MOUSE_DOWN => {
                const px = ev.arg0;
                const py = ev.arg1;
                if (!self.rect.contains(px, py)) return false;
                const tr = self.thumb_rect();
                if (tr.contains(px, py)) {
                    self.dragging = true;
                    self.drag_start_x = px;
                    self.drag_start_offset = self.offset;
                    return true;
                }
                if (self.track_contains(px, py)) {
                    const tx = self.thumb_x();
                    if (px < tx) {
                        self.scroll_by(-@as(i32, @intCast(self.viewport_w)));
                    } else {
                        self.scroll_by(@as(i32, @intCast(self.viewport_w)));
                    }
                    return true;
                }
                return false;
            },
            MOUSE_MOVE => {
                if (!self.dragging) return false;
                const px: i32 = @intCast(ev.arg0);
                const start_x: i32 = @intCast(self.drag_start_x);
                const delta: i32 = px - start_x;
                const m = self.max_offset();
                if (m == 0) return false;
                const tw = self.thumb_w();
                const track_w: i32 = @intCast(self.rect.w - tw);
                if (track_w <= 0) return false;
                const scaled = @divTrunc(delta * @as(i32, @intCast(m)), track_w);
                var new_off: i32 = @as(i32, @intCast(self.drag_start_offset)) + scaled;
                if (new_off < 0) new_off = 0;
                if (new_off > @as(i32, @intCast(m))) new_off = @intCast(m);
                self.offset = @intCast(new_off);
                return true;
            },
            MOUSE_UP => {
                if (self.dragging) {
                    self.dragging = false;
                    return true;
                }
                return false;
            },
            KEY_DOWN => {
                const keycode = ev.arg0;
                // Left 0x50, Right 0x4f, Home 0x4a, End 0x4d
                if (keycode == 0x50) {
                    self.scroll_by(-16);
                    return true;
                }
                if (keycode == 0x4f) {
                    self.scroll_by(16);
                    return true;
                }
                if (keycode == 0x4a) {
                    self.offset = 0;
                    return true;
                }
                if (keycode == 0x4d) {
                    self.offset = self.max_offset();
                    return true;
                }
                return false;
            },
            MOUSE_SCROLL => {
                // Horizontal via Shift (MOD_SHIFT) or packed horizontal bit.
                const is_shift = (ev.flags & MOD_SHIFT) != 0;
                const packed_horizontal = (ev.arg0 & 0x4000) != 0 and (ev.arg0 & 0xffff0000) == 0;
                const is_horizontal = is_shift or packed_horizontal;
                if (!is_horizontal) return false;
                var delta: i32 = 0;
                // Arc4 #236: arg0 packed per ADR 0013 D2.
                // bits 0–13 = magnitude, bit 14 = horizontal, bit 15 = sign.
                // Shift+scroll overrides horizontal flag.
                const raw = ev.arg0;
                const magnitude: i32 = @intCast(raw & 0x1fff);
                if (magnitude == 0) return false;
                const horiz = is_shift or (raw & 0x4000) != 0;
                if (!horiz) return false; // HScrollBar only consumes horizontal
                const sign: i32 = if ((raw & 0x8000) != 0) 1 else -1;
                delta = sign * magnitude * 16;
                self.scroll_by(delta);
                return true;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const HScrollBar, win_id: u32) void {
        if (self.content_w <= self.viewport_w) return;
        // Track
        draw_rect(win_id, self.rect, theme_border());
        // Thumb
        const tr = self.thumb_rect();
        win_fill(win_id, tr.x, tr.y, tr.w, tr.h, theme_accent());
    }
};
