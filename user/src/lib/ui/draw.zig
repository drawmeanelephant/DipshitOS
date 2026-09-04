//! VirelaiOS UI Drawing Primitives, Typography & Raster Surface Engine (M39 UI1).
const std = @import("std");
pub const abi = @import("abi.zig");
pub const theme = @import("theme.zig");

pub const font8x8 = @import("../font8x8.zig");
pub const font_ttf = @import("../font_ttf.zig");
pub const TrueTypeFace = font_ttf.TrueTypeFace;
pub const image = @import("../image.zig");
pub const Image = image.Image;

// Local aliases from abi:
const MAP_ANONYMOUS = abi.MAP_ANONYMOUS;
const MAP_POPULATE = abi.MAP_POPULATE;
const MAP_PRIVATE = abi.MAP_PRIVATE;
const MODE_READ = abi.MODE_READ;
const PROT_READ = abi.PROT_READ;
const PROT_WRITE = abi.PROT_WRITE;
const file_close = abi.file_close;
const file_open = abi.file_open;
const file_read = abi.file_read;
const mmap = abi.mmap;
const sys_win_fill_batch_num = abi.sys_win_fill_batch_num;
const syscall2 = abi.syscall2;
const win_present = abi.win_present;
const write_console = abi.write_console;

// Local aliases from theme:
const border_w = theme.border_w;
const focus_w = theme.focus_w;
const frame_border = theme.frame_border;
const theme_accent = theme.theme_accent;
const theme_border = theme.theme_border;

// ---------------------------------------------------------------------------
// M32 WMS9 (issue #629): batched fills on the surface seam.
//
// Instead of one syscall per glyph pixel, drawing primitives accumulate fill
// rects in a static `FillBatcher` and flush them through slot 46
// `sys_win_fill_batch` (one SVC per up-to-32 rects). Zero heap allocation:
// the batch lives in static BSS. Output is pixel-identical to per-pixel
// fills; only the syscall count collapses.
// ---------------------------------------------------------------------------

/// One packed rect in a slot-46 batch: 24 bytes, matching the kernel's
/// handle_win_fill_batch layout {id: u8, _pad: [3]u8, x, y, w, h: u32, rgb: u32}.
pub const FILL_RECT_SIZE: usize = 24;
pub const FILL_BATCH_MAX: usize = 32;

/// Accumulates fill rects and flushes them through slot 46 in chunks of 32.
/// Zero heap allocation: the buffer lives in static BSS. Batches are keyed
/// per window id — flushing automatically whenever the window id changes,
/// so callers never need to think about it.
pub const FillBatcher = struct {
    buf: [FILL_BATCH_MAX * FILL_RECT_SIZE]u8 align(8) = undefined,
    len: usize = 0,
    cur_id: u32 = 0,

    pub fn reset(self: *FillBatcher) void {
        self.len = 0;
    }

    fn push(self: *FillBatcher, id: u32, x: u32, y: u32, w: u32, h: u32, rgb: u32) void {
        if (self.len >= FILL_BATCH_MAX * FILL_RECT_SIZE) {
            self.flush();
        }
        const off = self.len;
        self.buf[off] = @intCast(id & 0xff);
        self.buf[off + 1] = 0;
        self.buf[off + 2] = 0;
        self.buf[off + 3] = 0;
        std.mem.writeInt(u32, self.buf[off + 4 ..][0..4], x, .little);
        std.mem.writeInt(u32, self.buf[off + 8 ..][0..4], y, .little);
        std.mem.writeInt(u32, self.buf[off + 12 ..][0..4], w, .little);
        std.mem.writeInt(u32, self.buf[off + 16 ..][0..4], h, .little);
        std.mem.writeInt(u32, self.buf[off + 20 ..][0..4], rgb, .little);
        self.len += FILL_RECT_SIZE;
    }

    /// Send all buffered rects through slot 46 in one SVC per 32 rects.
    pub fn flush(self: *FillBatcher) void {
        if (self.len == 0) return;
        _ = syscall2(sys_win_fill_batch_num, @intFromPtr(&self.buf), self.len);
        self.reset();
    }
};

/// The toolkit-wide fill batcher (static BSS, zero heap allocation).
pub var fill_batcher = FillBatcher{};

/// Queue a fill rect into the batcher. Flushes automatically on window-id
/// change or when the 32-rect batch is full, so ordering across windows is
/// preserved and callers never need to flush manually.
pub fn win_fill_batched(id: u32, x: u32, y: u32, w: u32, h: u32, rgb: u32) void {
    if (fill_batcher.len > 0 and fill_batcher.cur_id != id) {
        fill_batcher.flush();
    }
    fill_batcher.cur_id = id;
    fill_batcher.push(id, x, y, w, h, rgb);
}

/// Flush any pending batched fills (call before win_present / frame end).
pub fn flush_fills() void {
    fill_batcher.flush();
}

// ---------------------------------------------------------------------------
// Geometry Primitives
// ---------------------------------------------------------------------------

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn make(x: u32, y: u32, w: u32, h: u32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn contains(self: Rect, px: u32, py: u32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }

    pub fn inset(self: Rect, dx: u32, dy: u32) Rect {
        const double_dx = dx * 2;
        const double_dy = dy * 2;
        return .{
            .x = self.x + dx,
            .y = self.y + dy,
            .w = if (self.w > double_dx) self.w - double_dx else 0,
            .h = if (self.h > double_dy) self.h - double_dy else 0,
        };
    }
};

// ---------------------------------------------------------------------------
// Drawing Primitives
// ---------------------------------------------------------------------------

pub fn draw_rect(win_id: u32, rect: Rect, rgb: u32) void {
    if (rect.w == 0 or rect.h == 0) return;
    win_fill_batched(win_id, rect.x, rect.y, rect.w, rect.h, rgb);
}

pub fn draw_rect_outline(win_id: u32, rect: Rect, thickness: u32, rgb: u32) void {
    if (rect.w == 0 or rect.h == 0 or thickness == 0) return;
    // Top
    win_fill_batched(win_id, rect.x, rect.y, rect.w, thickness, rgb);
    // Bottom
    if (rect.h > thickness) {
        win_fill_batched(win_id, rect.x, rect.y + rect.h - thickness, rect.w, thickness, rgb);
    }
    // Left
    win_fill_batched(win_id, rect.x, rect.y, thickness, rect.h, rgb);
    // Right
    if (rect.w > thickness) {
        win_fill_batched(win_id, rect.x + rect.w - thickness, rect.y, thickness, rect.h, rgb);
    }
}

// ---------------------------------------------------------------------------
// Typography & Font Engine (Inter for UI, Fira Code for Monospace)
// ---------------------------------------------------------------------------

pub var active_ui_font: ?*const TrueTypeFace = null;
pub var active_mono_font: ?*const TrueTypeFace = null;
pub var active_ui_cache: TrueTypeFace.GlyphCache = .{};
pub var active_mono_cache: TrueTypeFace.GlyphCache = .{};
var static_inter_face: TrueTypeFace = undefined;
var static_fira_face: TrueTypeFace = undefined;

pub var fonts_initialized: bool = false;

pub fn init_fonts() bool {
    if (fonts_initialized) return active_ui_font != null;
    fonts_initialized = true;

    // Probe /host/INTER.TTF
    const fd_inter = file_open("/host/INTER.TTF", MODE_READ);
    if (fd_inter >= 0) {
        const handle: u32 = @intCast(fd_inter);
        defer file_close(handle);

        const max_bytes: u64 = 1024 * 1024;
        const va = mmap(0, max_bytes, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE | MAP_POPULATE);
        if (va > 0) {
            const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(va)));
            var total_read: usize = 0;
            while (total_read < max_bytes) {
                const chunk = file_read(handle, ptr[total_read..max_bytes]);
                if (chunk <= 0) break;
                total_read += @intCast(chunk);
            }
            if (total_read > 1024) {
                if (TrueTypeFace.init(ptr[0..total_read])) |face| {
                    static_inter_face = face;
                    active_ui_font = &static_inter_face;
                } else |_| {}
            }
        }
    }

    // Probe /host/FIRACODE.TTF
    const fd_fira = file_open("/host/FIRACODE.TTF", MODE_READ);
    if (fd_fira >= 0) {
        const handle: u32 = @intCast(fd_fira);
        defer file_close(handle);

        const max_bytes: u64 = 1024 * 1024;
        const va = mmap(0, max_bytes, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE | MAP_POPULATE);
        if (va > 0) {
            const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(va)));
            var total_read: usize = 0;
            while (total_read < max_bytes) {
                const chunk = file_read(handle, ptr[total_read..max_bytes]);
                if (chunk <= 0) break;
                total_read += @intCast(chunk);
            }
            if (total_read > 1024) {
                if (TrueTypeFace.init(ptr[0..total_read])) |face| {
                    static_fira_face = face;
                    active_mono_font = &static_fira_face;
                } else |_| {}
            }
        }
    }

    if (active_ui_font != null) {
        write_console("typography: Inter TrueType font loaded\n");
    }
    if (active_mono_font != null) {
        write_console("typography: Fira Code TrueType font loaded\n");
    }

    return active_ui_font != null;
}

pub fn draw_alpha_mask(win_id: u32, x: i32, y: i32, w: usize, h: usize, alpha: []const u8, fg_rgb: u32) void {
    if (win_get_backing(win_id)) |backing| {
        TrueTypeFace.blend_glyph_bgra(
            backing.pixels[0 .. @as(usize, @intCast(backing.width)) * @as(usize, @intCast(backing.height))],
            backing.width,
            backing.width,
            backing.height,
            x,
            y,
            w,
            h,
            alpha,
            fg_rgb,
        );
        return;
    }

    for (0..h) |row| {
        const dy = y + @as(i32, @intCast(row));
        if (dy < 0) continue;
        const udy: u32 = @intCast(dy);

        var col: usize = 0;
        while (col < w) {
            const a = alpha[row * w + col];
            if (a < 96) {
                col += 1;
                continue;
            }
            const start_col = col;
            while (col < w and alpha[row * w + col] >= 96) : (col += 1) {}
            const dx = x + @as(i32, @intCast(start_col));
            if (dx >= 0) {
                const udx: u32 = @intCast(dx);
                const span_len: u32 = @intCast(col - start_col);
                win_fill_batched(win_id, udx, udy, span_len, 1, fg_rgb);
            }
        }
    }
}

pub fn measure_text(text: []const u8) u32 {
    if (active_ui_font) |face| {
        var w: u32 = 0;
        for (text) |ch| {
            if (active_ui_cache.get_or_render(face, ch, 14)) |entry| {
                w += entry.advance_width;
            } else {
                w += 8;
            }
        }
        return w;
    }
    return @as(u32, @intCast(text.len)) * 8;
}

pub fn measure_text_mono(text: []const u8) u32 {
    if (active_mono_font) |face| {
        var w: u32 = 0;
        for (text) |ch| {
            if (active_mono_cache.get_or_render(face, ch, 13)) |entry| {
                w += entry.advance_width;
            } else {
                w += 8;
            }
        }
        return w;
    }
    return @as(u32, @intCast(text.len)) * 8;
}

pub fn draw_char(win_id: u32, ch: u8, x: u32, y: u32, fg_rgb: u32) void {
    if (active_ui_font) |face| {
        if (active_ui_cache.get_or_render(face, ch, 14)) |entry| {
            const alpha = active_ui_cache.glyph_alpha(entry);
            const gx = @as(i32, @intCast(x)) + entry.bearing_x;
            const gy = @as(i32, @intCast(y)) + (10 - entry.bearing_y);
            draw_alpha_mask(win_id, gx, gy, entry.width, entry.height, alpha, fg_rgb);
            return;
        }
    }

    if (ch < 0x20 or ch > 0x7e) return;
    const glyph = font8x8.glyphs[ch - 0x20];
    var row_idx: usize = 0;
    while (row_idx < 8) : (row_idx += 1) {
        const row_byte = glyph[row_idx];
        var col_idx: usize = 0;
        while (col_idx < 8) {
            if (!font8x8.row_pixel(row_byte, col_idx)) {
                col_idx += 1;
                continue;
            }
            const start_col = col_idx;
            while (col_idx < 8 and font8x8.row_pixel(row_byte, col_idx)) : (col_idx += 1) {}
            win_fill_batched(win_id, x + @as(u32, @intCast(start_col)), y + @as(u32, @intCast(row_idx)), @as(u32, @intCast(col_idx - start_col)), 1, fg_rgb);
        }
    }
}

pub fn draw_char_mono(win_id: u32, ch: u8, x: u32, y: u32, fg_rgb: u32) void {
    if (active_mono_font) |face| {
        if (active_mono_cache.get_or_render(face, ch, 13)) |entry| {
            const alpha = active_mono_cache.glyph_alpha(entry);
            const gx = @as(i32, @intCast(x)) + entry.bearing_x;
            const gy = @as(i32, @intCast(y)) + (10 - entry.bearing_y);
            draw_alpha_mask(win_id, gx, gy, entry.width, entry.height, alpha, fg_rgb);
            return;
        }
    }
    draw_char(win_id, ch, x, y, fg_rgb);
}

pub fn draw_text(win_id: u32, text: []const u8, x: u32, y: u32, fg_rgb: u32) void {
    var cur_x = x;
    if (active_ui_font) |face| {
        for (text) |ch| {
            if (active_ui_cache.get_or_render(face, ch, 14)) |entry| {
                const alpha = active_ui_cache.glyph_alpha(entry);
                const gx = @as(i32, @intCast(cur_x)) + entry.bearing_x;
                const gy = @as(i32, @intCast(y)) + (10 - entry.bearing_y);
                draw_alpha_mask(win_id, gx, gy, entry.width, entry.height, alpha, fg_rgb);
                cur_x += entry.advance_width;
            } else {
                draw_char(win_id, ch, cur_x, y, fg_rgb);
                cur_x += 8;
            }
        }
        return;
    }

    for (text) |ch| {
        draw_char(win_id, ch, cur_x, y, fg_rgb);
        cur_x += 8;
    }
}

pub fn draw_text_mono(win_id: u32, text: []const u8, x: u32, y: u32, fg_rgb: u32) void {
    var cur_x = x;
    if (active_mono_font) |face| {
        for (text) |ch| {
            if (active_mono_cache.get_or_render(face, ch, 13)) |entry| {
                const alpha = active_mono_cache.glyph_alpha(entry);
                const gx = @as(i32, @intCast(cur_x)) + entry.bearing_x;
                const gy = @as(i32, @intCast(y)) + (10 - entry.bearing_y);
                draw_alpha_mask(win_id, gx, gy, entry.width, entry.height, alpha, fg_rgb);
                cur_x += entry.advance_width;
            } else {
                draw_char(win_id, ch, cur_x, y, fg_rgb);
                cur_x += 8;
            }
        }
        return;
    }

    for (text) |ch| {
        draw_char(win_id, ch, cur_x, y, fg_rgb);
        cur_x += 8;
    }
}

pub fn draw_text_centered(win_id: u32, text: []const u8, rect: Rect, fg_rgb: u32) void {
    const text_w = measure_text(text);
    const text_h: u32 = if (active_ui_font != null) 12 else 8;
    const x = if (rect.w > text_w) rect.x + (rect.w - text_w) / 2 else rect.x;
    const y = if (rect.h > text_h) rect.y + (rect.h - text_h) / 2 else rect.y;
    draw_text(win_id, text, x, y, fg_rgb);
}

// ---------------------------------------------------------------------------
// Step 6 (Issue #206): 8×16 font helpers for titles and headings.
// Uses the kernel's 2×-stretched glyph table via a runtime pixel walk.
// ---------------------------------------------------------------------------

pub fn draw_char_16(win_id: u32, ch: u8, x: u32, y: u32, fg_rgb: u32) void {
    if (ch < 0x20 or ch > 0x7e) return;
    // The 8×16 glyph is the 8×8 glyph with each row doubled.
    // We re-derive the stretch at render time to stay in sync with
    // font8x8.zig's glyphs_16 table (same data, user-side copy).
    const glyph = font8x8.glyphs[ch - 0x20];
    var row_idx: usize = 0;
    while (row_idx < 8) : (row_idx += 1) {
        const row_byte = glyph[row_idx];
        var col_idx: usize = 0;
        while (col_idx < 8) {
            if (!font8x8.row_pixel(row_byte, col_idx)) {
                col_idx += 1;
                continue;
            }
            const start_col = col_idx;
            while (col_idx < 8 and font8x8.row_pixel(row_byte, col_idx)) : (col_idx += 1) {}
            // One 2px-tall span per contiguous run (2× vertical stretch) —
            // replaces two 1×1 fills per pixel (WMS9, issue #629).
            win_fill_batched(win_id, x + @as(u32, @intCast(start_col)), y + @as(u32, @intCast(row_idx * 2)), @as(u32, @intCast(col_idx - start_col)), 2, fg_rgb);
        }
    }
}

pub fn draw_text_large(win_id: u32, text: []const u8, x: u32, y: u32, fg_rgb: u32) void {
    var cur_x = x;
    for (text) |ch| {
        draw_char_16(win_id, ch, cur_x, y, fg_rgb);
        cur_x += 8;
    }
}

pub fn draw_text_centered_large(win_id: u32, text: []const u8, rect: Rect, fg_rgb: u32) void {
    const text_w = @as(u32, @intCast(text.len)) * 8;
    const text_h: u32 = 16;
    const x = if (rect.w > text_w) rect.x + (rect.w - text_w) / 2 else rect.x;
    const y = if (rect.h > text_h) rect.y + (rect.h - text_h) / 2 else rect.y;
    draw_text_large(win_id, text, x, y, fg_rgb);
}

// ---------------------------------------------------------------------------
// Window Backing Buffer Support & Raster Blitting
// ---------------------------------------------------------------------------

pub const WindowBacking = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
};

const max_backing_windows: usize = 16;
var window_backings: [max_backing_windows]?WindowBacking = [_]?WindowBacking{null} ** max_backing_windows;

/// Associate a direct 32-bpp RGBA/RGBX backing buffer with a window ID.
pub fn win_set_backing(win_id: u32, pixels: [*]u32, width: u32, height: u32) void {
    if (win_id >= max_backing_windows) return;
    window_backings[win_id] = .{
        .pixels = pixels,
        .width = width,
        .height = height,
    };
}

/// Disassociate any registered backing buffer for a window ID.
pub fn win_clear_backing(win_id: u32) void {
    if (win_id >= max_backing_windows) return;
    window_backings[win_id] = null;
}

/// Retrieve the registered backing buffer for a window ID, if any.
pub fn win_get_backing(win_id: u32) ?WindowBacking {
    if (win_id >= max_backing_windows) return null;
    return window_backings[win_id];
}

/// Standard Porter-Duff source-over alpha blending for 32-bpp 0xAARRGGBB pixels.
pub fn blend_source_over(dst: u32, src: u32) u32 {
    const src_a: u32 = (src >> 24) & 0xFF;
    if (src_a == 0) return dst;
    if (src_a == 255) return src;

    const inv_a: u32 = 255 - src_a;
    const src_r: u32 = (src >> 16) & 0xFF;
    const src_g: u32 = (src >> 8) & 0xFF;
    const src_b: u32 = src & 0xFF;

    const dst_a: u32 = (dst >> 24) & 0xFF;
    const dst_r: u32 = (dst >> 16) & 0xFF;
    const dst_g: u32 = (dst >> 8) & 0xFF;
    const dst_b: u32 = dst & 0xFF;

    const out_r = (src_r * src_a + dst_r * inv_a) / 255;
    const out_g = (src_g * src_a + dst_g * inv_a) / 255;
    const out_b = (src_b * src_a + dst_b * inv_a) / 255;
    const out_a = src_a + (dst_a * inv_a) / 255;

    return (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
}

/// Blit raster image pixels to a window backing surface.
/// If a backing buffer is registered via win_set_backing, blends pixels directly
/// with source-over alpha blending and boundary clipping.
/// Otherwise, falls back to win_fill_batched span emission.
pub fn draw_image(win_id: u32, x: u32, y: u32, img: image.Image) void {
    if (img.width == 0 or img.height == 0) return;
    if (win_get_backing(win_id)) |backing| {
        if (x >= backing.width or y >= backing.height) return;
        const max_w = @min(img.width, backing.width - x);
        const max_h = @min(img.height, backing.height - y);
        var sy: u32 = 0;
        while (sy < max_h) : (sy += 1) {
            const dst_row = (y + sy) * backing.width + x;
            var sx: u32 = 0;
            while (sx < max_w) : (sx += 1) {
                const px_ptr = img.pixel_at(sx, sy) orelse continue;
                const src_px = px_ptr.*;
                if (((src_px >> 24) & 0xFF) == 0) continue;
                const dst_idx = dst_row + sx;
                backing.pixels[dst_idx] = blend_source_over(backing.pixels[dst_idx], src_px);
            }
        }
        return;
    }

    var sy: u32 = 0;
    while (sy < img.height) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < img.width) {
            const px_ptr = img.pixel_at(sx, sy) orelse break;
            const px = px_ptr.*;
            const a = (px >> 24) & 0xFF;
            if (a == 0) {
                sx += 1;
                continue;
            }
            const rgb = px & 0x00FFFFFF;
            const start_x = sx;
            sx += 1;
            while (sx < img.width) {
                const next_ptr = img.pixel_at(sx, sy) orelse break;
                const next_px = next_ptr.*;
                if (((next_px >> 24) & 0xFF) == 0 or (next_px & 0x00FFFFFF) != rgb) break;
                sx += 1;
            }
            win_fill_batched(win_id, x + start_x, y + sy, sx - start_x, 1, rgb);
        }
    }
}

/// Draw a clipped raster image to a window, rendering only pixels that fall within clip.
/// Uses direct backing buffer alpha blending when registered, otherwise batched fills.
pub fn draw_image_clipped(win_id: u32, x: u32, y: u32, img: image.Image, clip: Rect) void {
    if (img.width == 0 or img.height == 0 or clip.w == 0 or clip.h == 0) return;
    if (win_get_backing(win_id)) |backing| {
        const clip_x0 = clip.x;
        const clip_y0 = clip.y;
        const clip_x1 = @min(clip.x + clip.w, backing.width);
        const clip_y1 = @min(clip.y + clip.h, backing.height);
        if (clip_x0 >= clip_x1 or clip_y0 >= clip_y1) return;

        var sy: u32 = 0;
        while (sy < img.height) : (sy += 1) {
            const py = y + sy;
            if (py < clip_y0 or py >= clip_y1) continue;
            var sx: u32 = 0;
            while (sx < img.width) : (sx += 1) {
                const px_pos = x + sx;
                if (px_pos < clip_x0 or px_pos >= clip_x1) continue;
                const px_ptr = img.pixel_at(sx, sy) orelse continue;
                const src_px = px_ptr.*;
                if (((src_px >> 24) & 0xFF) == 0) continue;
                const dst_idx = py * backing.width + px_pos;
                backing.pixels[dst_idx] = blend_source_over(backing.pixels[dst_idx], src_px);
            }
        }
        return;
    }

    var sy: u32 = 0;
    while (sy < img.height) : (sy += 1) {
        const py = y + sy;
        if (py < clip.y or py >= clip.y + clip.h) continue;

        var sx: u32 = 0;
        while (sx < img.width) {
            const px_ptr = img.pixel_at(sx, sy) orelse break;
            const px = px_ptr.*;
            const a = (px >> 24) & 0xFF;
            const cur_x = x + sx;
            if (a == 0 or cur_x < clip.x or cur_x >= clip.x + clip.w) {
                sx += 1;
                continue;
            }
            const rgb = px & 0x00FFFFFF;
            const start_x = sx;
            sx += 1;
            while (sx < img.width) {
                const next_x = x + sx;
                if (next_x >= clip.x + clip.w) break;
                const next_ptr = img.pixel_at(sx, sy) orelse break;
                const next_px = next_ptr.*;
                if (((next_px >> 24) & 0xFF) == 0 or (next_px & 0x00FFFFFF) != rgb) break;
                sx += 1;
            }
            win_fill_batched(win_id, x + start_x, py, sx - start_x, 1, rgb);
        }
    }
}

/// Nearest-neighbor scaled image blitting into target destination rectangle.
/// Uses direct backing buffer alpha blending when registered, otherwise batched fills.
pub fn draw_image_scaled(win_id: u32, dest: Rect, img: image.Image) void {
    if (dest.w == 0 or dest.h == 0 or img.width == 0 or img.height == 0) return;
    if (win_get_backing(win_id)) |backing| {
        if (dest.x >= backing.width or dest.y >= backing.height) return;
        const max_w = @min(dest.w, backing.width - dest.x);
        const max_h = @min(dest.h, backing.height - dest.y);
        var dy: u32 = 0;
        while (dy < max_h) : (dy += 1) {
            const sy = (dy * img.height) / dest.h;
            const dst_row = (dest.y + dy) * backing.width + dest.x;
            var dx: u32 = 0;
            while (dx < max_w) : (dx += 1) {
                const sx = (dx * img.width) / dest.w;
                const px_ptr = img.pixel_at(sx, sy) orelse continue;
                const src_px = px_ptr.*;
                if (((src_px >> 24) & 0xFF) == 0) continue;
                const dst_idx = dst_row + dx;
                backing.pixels[dst_idx] = blend_source_over(backing.pixels[dst_idx], src_px);
            }
        }
        return;
    }

    var dy: u32 = 0;
    while (dy < dest.h) : (dy += 1) {
        const sy = (dy * img.height) / dest.h;
        var dx: u32 = 0;
        while (dx < dest.w) {
            const sx = (dx * img.width) / dest.w;
            const px_ptr = img.pixel_at(sx, sy) orelse break;
            const px = px_ptr.*;
            const a = (px >> 24) & 0xFF;
            if (a == 0) {
                dx += 1;
                continue;
            }
            const rgb = px & 0x00FFFFFF;
            const start_dx = dx;
            dx += 1;
            while (dx < dest.w) {
                const next_sx = (dx * img.width) / dest.w;
                const next_ptr = img.pixel_at(next_sx, sy) orelse break;
                const next_px = next_ptr.*;
                if (((next_px >> 24) & 0xFF) == 0 or (next_px & 0x00FFFFFF) != rgb) break;
                dx += 1;
            }
            win_fill_batched(win_id, dest.x + start_dx, dest.y + dy, dx - start_dx, 1, rgb);
        }
    }
}

/// Draw a 1px panel frame inside `rect` (in-app panels, dialogs, editors
/// — the compositor owns the OUTER window border). Uses token metrics.
pub fn draw_panel_frame(win_id: u32, rect: Rect, focused: bool) void {
    draw_rect_outline(win_id, rect, border_w, frame_border(focused));
}

/// Draw the focus outline OUTSIDE `rect` (focus_w band in accent).
/// Callers must leave focus_w px of clear space around the control.
pub fn draw_focus_outline(win_id: u32, rect: Rect) void {
    const outer = Rect.make(
        if (rect.x >= focus_w) rect.x - focus_w else 0,
        if (rect.y >= focus_w) rect.y - focus_w else 0,
        rect.w + focus_w * 2,
        rect.h + focus_w * 2,
    );
    draw_rect_outline(win_id, outer, focus_w, theme_accent());
    draw_rect_outline(win_id, rect, border_w, theme_border());
}
