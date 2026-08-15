//! Milestone six card G2 (claim 3194) — framebuffer text rendering.
//!
//! Renders text into G1's virtio-gpu framebuffer (B8G8R8X8_UNORM —
//! memory bytes B, G, R, X, claim-6053 observed) using a built-in 8×8
//! monochrome bitmap font (`font8x8.zig`, public domain — Daniel
//! Hepper's font8x8, based on IBM public-domain VGA fonts). The raster
//! is pure logic over an injectable canvas (the fat.zig / virtio_net.zig
//! host-testable pattern): putc/puts with a cursor, line wrap at the
//! region's width, a BOUNDED scrollback ring (fixed BSS — the visible
//! window scrolls one line when full), and `clear`.
//!
//! The text region is the whole framebuffer (1280×720 → 160 cols × 90
//! rows at 8×8 cells). Honest bounds: G2 renders text into G1's
//! framebuffer through G1's transfer/flush path; the console's line
//! editor + command registry stay on serial until card G3 (Road Pops).
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const font = @import("font8x8.zig");
const virtio_gpu = @import("virtio_gpu.zig");

// ---------------------------------------------------------------------------
// Geometry + colors (fixed constants; the claim-time record lives in
// docs/m6-text-prompt.md and the hardware contract)
// ---------------------------------------------------------------------------

/// 8×8 cells over the 1280×720 framebuffer.
pub const cell_w: usize = 8;
pub const cell_h: usize = 8;
pub const cols: usize = virtio_gpu.fb_width / cell_w; // 160
pub const rows: usize = virtio_gpu.fb_height / cell_h; // 90

/// The bounded scrollback ring: `ring_lines` lines × `cols` chars of
/// fixed BSS. The visible window is the LAST `rows` lines of the ring;
/// when the ring is full the oldest line is dropped (the console's
/// scroll-up behavior). Claim-time constant: 4× the visible rows.
pub const ring_lines: usize = 128;

/// Text colors (0xRRGGBB). The foreground is the G1-family green, the
/// background the G1 boot fill (dark slate) — both already observed
/// through the color-managed host pipeline.
pub const fg_rgb: u32 = 0x00ff00;
pub const bg_rgb: u32 = 0x101418;

// ---------------------------------------------------------------------------
// Text state (fixed BSS — the one-and-only real instance)
// ---------------------------------------------------------------------------

/// The scrollback ring of text lines. A line is `cols` chars; a char is
/// the ASCII byte (0x20–0x7e printable, anything else renders as blank).
var ring: [ring_lines][cols]u8 = undefined;

/// Chars used per line (0..cols) — the cursor/report bookkeeping.
var line_fill: [ring_lines]u16 = undefined;

/// Ring bookkeeping: `ring_head` = the index where the NEXT line is
/// written, `ring_count` = valid lines (0..ring_lines). The OLDEST line
/// is at `ring_head - ring_count` (mod ring_lines) once full.
var ring_head: usize = 0;
var ring_count: usize = 0;

/// The cursor: line position within the ring (always the last line) +
/// column.
var cur_line: usize = 0; // = ring_head - 1 mod ring_lines
var cur_col: usize = 0;

/// Whether the text layer has been initialized (the ring reset).
var initialized: bool = false;

/// A B8G8R8X8 canvas the renderer writes into (injectable for tests).
pub const Canvas = struct {
    base: [*]u8,
    width: usize,
    height: usize,
    stride: usize, // bytes per row (width × 4 for the framebuffer)
};

// ---------------------------------------------------------------------------
// State operations (pure — host-testable)
// ---------------------------------------------------------------------------

/// Reset the ring + cursor (the boot-time call and `text clear`).
pub fn init() void {
    var i: usize = 0;
    while (i < ring_lines) : (i += 1) {
        @memset(&ring[i], 0x20);
        line_fill[i] = 0;
    }
    ring_head = 0;
    ring_count = 0;
    cur_line = 0;
    cur_col = 0;
    initialized = true;
}

/// Start a NEW line at the ring head (advancing/dropping the oldest when
/// full) and move the cursor to it. Returns the ring slot of the new
/// line.
fn new_line() usize {
    const slot = ring_head;
    @memset(&ring[slot], 0x20);
    line_fill[slot] = 0;
    ring_head = (ring_head + 1) % ring_lines;
    if (ring_count < ring_lines) ring_count += 1;
    cur_line = slot;
    cur_col = 0;
    return slot;
}

/// The ring slot of the cursor's line (the last valid line).
fn cursor_slot() usize {
    if (!initialized or ring_count == 0) return new_line();
    return cur_line;
}

/// Emit one character. `\n` starts a new line; `\r` returns the cursor to
/// column 0 of the current line; `\b` moves the cursor left one column (a
/// no-op at column 0) so the line editor's erase/redraw byte stream renders
/// on the framebuffer exactly as it does on a serial terminal (milestone
/// eight card U2). Every other byte renders into the current line
/// (printable chars draw the glyph, control bytes draw as blank), wrapping
/// to a new line at the region's width.
pub fn putc(c: u8) void {
    if (!initialized) init();
    if (c == '\n') {
        _ = new_line();
        return;
    }
    if (c == '\r') {
        cur_col = 0;
        return;
    }
    if (c == 0x08) { // backspace
        if (cur_col > 0) cur_col -= 1;
        return;
    }
    var slot = cursor_slot();
    if (cur_col >= cols) {
        slot = new_line();
    }
    ring[slot][cur_col] = c;
    cur_col += 1;
    if (cur_col > line_fill[slot]) line_fill[slot] = @intCast(cur_col);
    if (cur_col >= cols) _ = new_line();
}

/// Emit a string.
pub fn puts(s: []const u8) void {
    for (s) |c| putc(c);
}

/// Clear the text layer (ring + cursor).
pub fn clear() void {
    init();
}

/// The cursor's VISIBLE row: the last ring line, positioned in the
/// window of `rows` visible lines.
pub fn cursor_row() usize {
    if (ring_count == 0) return 0;
    if (ring_count >= rows) return rows - 1;
    return ring_count - 1;
}

/// The cursor's column within its line.
pub fn cursor_col() usize {
    return cur_col;
}

/// Valid lines in the scrollback ring (0..ring_lines).
pub fn line_count() usize {
    return ring_count;
}

// ---------------------------------------------------------------------------
// Rendering (pure — writes B,G,R,X into the canvas)
// ---------------------------------------------------------------------------

fn put_pixel(canvas: Canvas, x: usize, y: usize, rgb: u32) void {
    const off = y * canvas.stride + x * 4;
    canvas.base[off] = @truncate(rgb & 0xff); // B
    canvas.base[off + 1] = @truncate((rgb >> 8) & 0xff); // G
    canvas.base[off + 2] = @truncate((rgb >> 16) & 0xff); // R
    canvas.base[off + 3] = 0xff; // X — opaque (the claim-6053 lesson)
}

/// Render the visible window (the LAST `rows` lines of the ring) into
/// the canvas: background fill + foreground glyphs. The cursor line's
/// underline is not drawn (G2 has no cursor blink — honest bound).
pub fn render(canvas: Canvas) void {
    if (!initialized) init();
    var y: usize = 0;
    while (y < canvas.height) : (y += 1) {
        var x: usize = 0;
        while (x < canvas.width) : (x += 1) {
            put_pixel(canvas, x, y, bg_rgb);
        }
    }
    if (ring_count == 0) return;
    // Card U4/U5 close-out fix: the render is bounded by the CANVAS, not
    // just the module geometry — the tiny-canvas host tests (16x16) and
    // any undersized destination stay in bounds (a latent out-of-bounds
    // write the 16x16 test exercised into adjacent globals for its whole
    // life; new BSS neighbors turned it into a bus error).
    const visible: usize = @min(@min(ring_count, rows), canvas.height / cell_h);
    // The visible window: the last `visible` lines of the ring. The
    // cursor line is the last one; its slot is cur_line.
    var r: usize = 0;
    while (r < visible) : (r += 1) {
        // Ring slot of the (ring_count - visible + r)-th valid line.
        const first_valid = if (ring_count >= ring_lines)
            ring_head
        else
            0;
        const slot = (first_valid + ring_count - visible + r) % ring_lines;
        const row_pix = r * cell_h;
        const cols_fit = @min(cols, canvas.width / cell_w);
        var col: usize = 0;
        while (col < cols_fit) : (col += 1) {
            const c = ring[slot][col];
            if (c < 0x20 or c > 0x7e) continue;
            const glyph = font.glyphs[c - 0x20];
            const col_pix = col * cell_w;
            var gy: usize = 0;
            while (gy < cell_h) : (gy += 1) {
                const row_bits = glyph[gy];
                var gx: usize = 0;
                while (gx < cell_w) : (gx += 1) {
                    if (font.row_pixel(row_bits, gx)) {
                        put_pixel(canvas, col_pix + gx, row_pix + gy, fg_rgb);
                    }
                }
            }
        }
    }
}

/// Render + push to the screen through G1's path (transfer + flush).
/// The caller owns the gpu (guarded by gpu_ready). Returns the CmdResult
/// of the flush (the transfer result is dropped on a flush failure).
pub fn present() virtio_gpu.CmdResult {
    if (!virtio_gpu.gpu_ready) return .not_ready;
    render(.{
        .base = @ptrCast(&virtio_gpu.gpu_fb),
        .width = virtio_gpu.fb_width,
        .height = virtio_gpu.fb_height,
        .stride = virtio_gpu.fb_width * 4,
    });
    if (virtio_gpu.gpu_transfer() != .ok) return .timeout;
    return virtio_gpu.gpu_flush();
}

// ---------------------------------------------------------------------------
// Host tests — the class A raster proof (golden glyphs + behavior)
// ---------------------------------------------------------------------------

const W = 16;
const H = 16;
var test_buf: [W * H * 4]u8 = undefined;

fn testCanvas() Canvas {
    @memset(&test_buf, 0);
    return .{ .base = &test_buf, .width = W, .height = H, .stride = W * 4 };
}

fn pixel(c: Canvas, x: usize, y: usize) [3]u8 {
    const off = y * c.stride + x * 4;
    return .{ c.base[off], c.base[off + 1], c.base[off + 2] }; // B,G,R
}

fn rgbBytes(rgb: u32) [3]u8 {
    return .{ @truncate(rgb & 0xff), @truncate((rgb >> 8) & 0xff), @truncate((rgb >> 16) & 0xff) };
}

test "text: asymmetric C raster is LSB-first in B8G8R8X8" {
    init();
    clear();
    puts("C");
    const canvas = testCanvas();
    render(canvas);
    // Independent human-facing golden for C:
    //   ..####..
    //   .##..##.
    //   ##......  <- source row 0x03, bit 0 is LEFT
    //   ##......
    //   ##......
    //   .##..##.
    //   ..####..
    //   ........
    // The old symmetric '!' golden could not detect horizontal reversal.
    const fg = rgbBytes(fg_rgb);
    const bg = rgbBytes(bg_rgb);
    try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 2, 0));
    try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 5, 0));
    try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 0, 2));
    try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 1, 2));
    try std.testing.expectEqualSlices(u8, &bg, &pixel(canvas, 6, 2));
    try std.testing.expectEqualSlices(u8, &bg, &pixel(canvas, 7, 2));
    // The alpha byte is opaque (the claim-6053 lesson).
    try std.testing.expectEqual(@as(u8, 0xff), test_buf[(2 * W) * 4 + 3]);
}

test "text: the full 95-glyph table rasters LSB-first — every pixel matches the raw source bits (issue 125)" {
    // Render EVERY printable glyph into the test canvas and assert all 64
    // pixels against the RAW table byte read LSB-first inline — `(row >>
    // x) & 1`, NOT font.row_pixel. Deriving the expectation from the
    // helper under test would be self-consistent with a reversed helper
    // (the exact trap issue 125 documented in the old decoder); reading
    // the source bits directly pins the CONVENTION. 90 of 95 glyphs are
    // horizontally asymmetric, so a bit-order flip in the terminal raster
    // OR the row_pixel helper breaks 90/95 glyphs immediately.
    init();
    const fg = rgbBytes(fg_rgb);
    const bg = rgbBytes(bg_rgb);
    var i: usize = 0;
    while (i < font.glyphs.len) : (i += 1) {
        clear();
        const ch: u8 = @intCast(0x20 + i);
        const one = [1]u8{ch};
        puts(&one);
        const canvas = testCanvas();
        render(canvas);
        const glyph = font.glyphs[i];
        var gy: usize = 0;
        while (gy < 8) : (gy += 1) {
            var gx: usize = 0;
            while (gx < 8) : (gx += 1) {
                const row = glyph[gy];
                const bit_set = ((row >> @as(u3, @intCast(gx))) & 1) != 0;
                const want: [3]u8 = if (bit_set) fg else bg;
                try std.testing.expectEqualSlices(u8, &want, &pixel(canvas, gx, gy));
            }
        }
    }
}

test "text: line wrap starts a new line at the region width" {
    init();
    clear();
    var i: usize = 0;
    while (i < cols + 3) : (i += 1) puts("x");
    // cols+3 chars → cols fill the first line and wrap (new line), the
    // remaining 3 land on line 2 at col 3: ring holds 2 lines, cursor at
    // col 3 of the last line.
    try std.testing.expectEqual(@as(usize, 2), ring_count);
    try std.testing.expectEqual(@as(usize, 3), cur_col);
    try std.testing.expectEqual(@as(usize, 1), cursor_row());
}

test "text: backspace and carriage return move the cursor (U2)" {
    init();
    clear();
    puts("hello");
    try std.testing.expectEqual(@as(usize, 5), cur_col);
    putc('\r');
    try std.testing.expectEqual(@as(usize, 0), cur_col);
    puts("bye"); // overwrites h,e,l -> the line reads "byelo"
    try std.testing.expectEqual(@as(usize, 3), cur_col);
    try std.testing.expectEqualSlices(u8, "byelo", ring[cursor_slot()][0..5]);
    // Backspace moves left without writing; the next char overwrites.
    putc(0x08);
    putc(0x08);
    try std.testing.expectEqual(@as(usize, 1), cur_col);
    putc('x');
    try std.testing.expectEqualSlices(u8, "bxelo", ring[cursor_slot()][0..5]);
    // Backspace at column 0 is a no-op (never wraps negative).
    clear();
    putc(0x08);
    try std.testing.expectEqual(@as(usize, 0), cur_col);
}

test "text: the scrollback ring is bounded and drops the oldest line" {
    init();
    clear();
    var i: usize = 0;
    while (i < ring_lines + 1) : (i += 1) {
        puts("\n");
    }
    try std.testing.expectEqual(ring_lines, ring_count);
    // The first line's first char is gone from the visible window.
    try std.testing.expectEqual(@as(usize, rows - 1), cursor_row());
}

test "text: clear resets the ring and cursor" {
    init();
    puts("hello");
    try std.testing.expect(ring_count >= 1);
    clear();
    try std.testing.expectEqual(@as(usize, 0), ring_count);
    try std.testing.expectEqual(@as(usize, 0), cur_col);
    try std.testing.expectEqual(@as(usize, 0), cursor_row());
}

test "text: render never writes outside the canvas" {
    init();
    clear();
    // A full visible window of glyphs over a 16×16 canvas must leave the
    // canvas edges at the background (the window only fills rows it has).
    var i: usize = 0;
    while (i < rows) : (i += 1) puts("x\n");
    const canvas = testCanvas();
    render(canvas);
    try std.testing.expectEqualSlices(u8, &rgbBytes(bg_rgb), &pixel(canvas, 0, H - 1));
}
