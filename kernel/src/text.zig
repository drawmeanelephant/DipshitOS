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
const font_unicode = @import("font_unicode.zig");
const virtio_gpu = @import("virtio_gpu.zig");

// ---------------------------------------------------------------------------
// Geometry + colors (fixed constants; the claim-time record lives in
// docs/archive/m6-text-prompt.md and the hardware contract)
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

/// Tab-stop interval in columns (M20-U10). 8 is the terminal default;
/// `set_tab_width` admits 4 (editor style). A TAB advances the cursor to
/// the next multiple of this width, filling the skipped cells with
/// spaces so selection/copy see real characters.
pub var tab_width: usize = 8;

/// Set the tab-stop interval (clamped to 1..=8; M20-U10's 8/4 options).
pub fn set_tab_width(n: usize) void {
    tab_width = if (n == 0) 1 else @min(n, 8);
}

// ---------------------------------------------------------------------------
// Text state (fixed BSS — the one-and-only real instance)
// ---------------------------------------------------------------------------

/// One ring cell. M20 widened the ring from raw ASCII bytes to u16 so a
/// cell can name any codepoint the renderer knows:
///
///   0x0000–0x7FFF  literal codepoint (ASCII fast path inside this)
///   0x8000–0xFFFE  reserved for M20's dynamic encodings (combining
///                  clusters, emoji — wired up by their cards)
///   0xFFFF         the right half of a wide (2-cell) character
pub const Cell = u16;

/// The scrollback ring of text lines. A line is `cols` cells.
var ring: [ring_lines][cols]Cell = undefined;

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

/// CSI (`ESC [ <params> <final>`) decode state for the byte stream the
/// line editor and monitor write here: 0 = normal, 1 = ESC, 2 = ESC [.
/// Ctrl-L and `clear` emit `ESC [ 2 J` + `ESC [ H`; without this the
/// escape bytes were STORED and drawn as the glyphs `[2J[H` instead of
/// clearing the screen (the serial console never saw it — its terminal
/// consumes them).
var esc_state: u8 = 0;
var esc_param: u8 = 0;

/// A B8G8R8X8 canvas the renderer writes into (injectable for tests).
pub const Canvas = struct {
    base: [*]u8,
    width: usize,
    height: usize,
    stride: usize, // bytes per row (width × 4 for the framebuffer)
};

// ---------------------------------------------------------------------------
// Character width (M20-U4 — wcwidth, comptime-evaluable)
// ---------------------------------------------------------------------------

/// The terminal width of a codepoint in cells: 0 (invisible/combining),
/// 1 (narrow), or 2 (wide). Bounded to the ranges this OS can actually
/// encounter: Latin-1 + Latin Extended-A render narrow; CJK ideographs,
/// fullwidth forms and the emoji blocks are wide even though only a
/// subset paints real glyphs (the rest fall back — U11); combining
/// diacritics, variation selectors and the zero-width joiners occupy no
/// cell at all. Unlisted codepoints default to 1. Works at comptime so
/// font tables can be generated against it.
pub fn char_width(cp: u21) u8 {
    return switch (cp) {
        // Combining diacritical marks (overlay the previous cell).
        0x0300...0x036F => 0,
        // Zero-width characters: ZWSP, ZWNJ, ZWJ, LRM, RLM.
        0x200B...0x200F => 0,
        // Word joiner.
        0x2060 => 0,
        // Variation selectors.
        0xFE00...0xFE0F => 0,
        // CJK ideographs (no glyph tables yet — still 2 cells wide).
        0x4E00...0x9FFF => 2,
        // Halfwidth/known-narrow punctuation inside the fullwidth block.
        0xFF01...0xFF60 => 2,
        // Emoji blocks (U+1F300–U+1F9FF): Miscellaneous Symbols and
        // Pictographs, Emoticons, Supplemental Symbols and Pictographs.
        0x1F300...0x1F9FF => 2,
        else => 1,
    };
}

/// Whether `cp` is a combining mark that overlays the previous base
/// character (the width-0 set that MODIFIES rather than vanishes).
pub fn is_combining(cp: u21) bool {
    return cp >= 0x0300 and cp <= 0x036F;
}

/// Whether `cp` is an ignorable zero-width codepoint (ZWJ/ZWNJ/ZWSP/
/// selectors): it neither takes a cell nor modifies its neighbor.
pub fn is_zero_width_ignorable(cp: u21) bool {
    return switch (cp) {
        0x200B...0x200F, 0xFE00...0xFE0F, 0x2060 => true,
        else => false,
    };
}

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
    esc_state = 0;
    esc_param = 0;
    u8_need = 0;
    u8_acc = 0;
    missing_glyph_count = 0;
    last_missing_cp = 0;
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
/// eight card U2). `ESC [ 2 J` clears the layer and `ESC [ H` homes the
/// cursor; any other CSI sequence is swallowed whole rather than drawn.
/// Every other byte renders into the current line (printable chars draw
/// the glyph, control bytes draw as blank), wrapping to a new line at the
/// region's width.
pub fn putc(c: u8) void {
    if (!initialized) init();
    switch (esc_state) {
        0 => {},
        else => esc_state = 0,
        1 => {
            esc_state = 0;
            if (c == 0x5b) { // '['
                esc_state = 2;
                esc_param = 0;
                return;
            }
            // A lone ESC introduces nothing we render: drop the ESC and
            // handle this byte as ordinary text (falls through below).
        },
        2 => {
            if (c >= 0x30 and c <= 0x39) { // parameter digits
                const scaled = @mulWithOverflow(esc_param, 10);
                const added = @addWithOverflow(scaled[0], c - 0x30);
                esc_param = if (scaled[1] == 1 or added[1] == 1) 255 else added[0];
                return;
            }
            if (c >= 0x3a and c <= 0x3f) return; // ';' and friends
            esc_state = 0;
            if (c == 0x4a and esc_param == 2) init(); // ESC [ 2 J: erase all
            if (c == 0x48) cur_col = 0; // ESC [ H: home the cursor
            return;
        },
    }
    if (c == 0x1b) {
        esc_state = 1;
        u8_need = 0; // an ESC also aborts any pending UTF-8 sequence
        return;
    }
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
    if (c == '\t') {
        // M20-U10: advance to the next tab stop, materializing the
        // skipped cells as spaces. A tab never wraps to the next line —
        // it stops at the region edge like a real terminal.
        const slot = cursor_slot();
        const stop = ((cur_col / tab_width) + 1) * tab_width;
        while (cur_col < @min(stop, cols)) : (cur_col += 1) {
            ring[slot][cur_col] = 0x20;
        }
        line_fill[slot] = @intCast(cur_col);
        return;
    }
    // M20-U2: everything else decodes as (possibly multi-byte) UTF-8 and
    // lands through the codepoint path.
    if (utf8_step(c)) |cp| {
        putc_unicode(cp);
        if (u8_retry) {
            u8_retry = false;
            if (utf8_step(u8_retry_byte)) |cp2| putc_unicode(cp2);
        }
    }
}

// ---------------------------------------------------------------------------
// Codepoint path (M20-U2): UTF-8 decode + cell encoding
// ---------------------------------------------------------------------------

/// Incremental UTF-8 decode state (max 4-byte sequences; bounded BSS).
var u8_need: u8 = 0;
var u8_acc: u21 = 0;

/// When a non-continuation byte interrupts a pending sequence, that
/// byte still deserves normal processing after the U+FFFD is reported.
var u8_retry: bool = false;
var u8_retry_byte: u8 = 0;

/// Feed one byte; returns a complete codepoint when the sequence ends,
/// null while more continuations are expected, or U+FFFD for broken
/// input (stray continuation byte / invalid lead / bad continuation).
fn utf8_step(b: u8) ?u21 {
    if (u8_need > 0) {
        if ((b & 0xC0) != 0x80) {
            u8_need = 0;
            u8_acc = 0;
            // The interrupting byte is re-fed once the caller has taken
            // the replacement codepoint (putc drives the retry below).
            if (b < 0x80 or (b >= 0xC2 and b <= 0xF4)) {
                u8_retry = true;
                u8_retry_byte = b;
            }
            return 0xFFFD; // broken sequence
        }
        u8_need -= 1;
        const next: u21 = (@as(u21, u8_acc) << 6) | (b & 0x3F);
        if (u8_need == 0) {
            u8_acc = 0;
            return next;
        }
        u8_acc = next;
        return null;
    }
    if (b < 0x80) return b;
    if (b >= 0xC2 and b <= 0xDF) {
        u8_need = 1;
        u8_acc = b & 0x1F;
        return null;
    }
    if (b >= 0xE0 and b <= 0xEF) {
        u8_need = 2;
        u8_acc = b & 0x0F;
        return null;
    }
    if (b >= 0xF0 and b <= 0xF4) {
        u8_need = 3;
        u8_acc = b & 0x07;
        return null;
    }
    return 0xFFFD; // stray continuation or invalid lead
}

/// Reserved cell opcodes (see `Cell`). The 0x8000+ dynamic space is
/// wired up by later M20 cards; unknown opcodes render blank.
pub const cell_wide_cont: Cell = 0xFFFF;

/// The unified glyph lookup for a literal codepoint (M20-U11 shape):
/// ASCII from font8x8, ≥0xA0 from the Unicode tables, null when there is
/// no glyph (caller renders the replacement character).
pub fn glyph_for(cp: u21) ?*const [8]u8 {
    if (cp < 0x80) {
        if (cp < 0x20 or cp > 0x7e) return null;
        return &font.glyphs[cp - 0x20];
    }
    return font_unicode.glyph(cp);
}

/// Emit one CODEPOINT into the current line. Control handling mirrors
/// putc's byte path; width-1 codepoints take one cell, width-2 take two
/// (base + continuation). Width-0 combining/ignorable codepoints are
/// dropped here until the U5/U6 cluster machinery wires them up.
pub fn putc_unicode(cp: u21) void {
    switch (cp) {
        '\n' => {
            _ = new_line();
            return;
        },
        '\r' => {
            cur_col = 0;
            return;
        },
        0x08 => {
            if (cur_col > 0) cur_col -= 1;
            return;
        },
        else => {},
    }
    // Unknown C0 controls and DEL draw as blanks (the historical byte
    // behavior) — never as visible fallback glyphs.
    if (cp < 0x20 or cp == 0x7F) {
        const slot = cursor_slot();
        if (cur_col >= cols) _ = new_line();
        ring[slot][cur_col] = 0x20;
        cur_col += 1;
        if (cur_col > line_fill[slot]) line_fill[slot] = @intCast(cur_col);
        if (cur_col >= cols) _ = new_line();
        return;
    }
    const w = char_width(cp);
    if (w == 0) return; // combining/zero-width: handled with clusters (U5/U6)
    var slot = cursor_slot();
    if (w == 2 and cur_col + 1 >= cols) slot = new_line(); // room for both halves
    if (cur_col >= cols) slot = new_line();
    if (glyph_for(cp) != null and cp <= 0xFF) {
        ring[slot][cur_col] = @intCast(cp); // literal encoding (ASCII + Latin tables)
    } else {
        ring[slot][cur_col] = cell_fffd; // M20-U11 fallback art
        note_missing(cp);
    }
    cur_col += 1;
    if (w == 2 and cur_col < cols) {
        ring[slot][cur_col] = cell_wide_cont;
        cur_col += 1;
    }
    if (cur_col > line_fill[slot]) line_fill[slot] = @intCast(cur_col);
    if (cur_col >= cols) _ = new_line();
}

/// Decode one ring cell into the glyph rows it paints (null paints
/// nothing: wide continuations, reserved opcodes, blanks).
fn cell_glyph(cell: Cell) ?*const [8]u8 {
    if (cell == cell_wide_cont) return null;
    if (cell == cell_fffd) return &font_unicode.fffd_glyph;
    if (cell >= 0x20 and cell <= 0x7e) return &font.glyphs[cell - 0x20];
    if (cell >= 0xA0 and cell <= 0xFF) return &font_unicode.latin1[cell - 0xA0];
    return null;
}

/// The replacement-character cell (U+FFFD art from font_unicode).
/// Lives in the reserved 0x8000+ dynamic opcode space so it can never
/// collide with a literal codepoint.
pub const cell_fffd: Cell = 0x8000;

// ---------------------------------------------------------------------------
// Missing-glyph diagnostics (M20-U11)
// ---------------------------------------------------------------------------

/// Dev setting (mirror of the SETTINGS.TXT `debug_font` key): when true,
/// every fallback-to-replacement records + reports the codepoint.
pub var debug_font: bool = false;

/// Serial log hook wired by main.zig at boot ("text: no glyph for
/// U+XXXX"). Null in host tests — counting alone is observable there.
pub var missing_glyph_log: ?*const fn (cp: u21) void = null;

/// Fallback statistics since init() (reset by clear/init).
pub var missing_glyph_count: usize = 0;
pub var last_missing_cp: u21 = 0;

fn note_missing(cp: u21) void {
    if (!debug_font) return;
    missing_glyph_count += 1;
    last_missing_cp = cp;
    if (missing_glyph_log) |log_fn| log_fn(cp);
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
            // M20-U2: cells decode through one path. The continuation
            // half of a wide character paints nothing (its base cell
            // already drew); unknown opcodes stay blank.
            const g = cell_glyph(ring[slot][col]) orelse continue;
            const col_pix = col * cell_w;
            var gy: usize = 0;
            while (gy < cell_h) : (gy += 1) {
                const row_bits = g[gy];
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

/// Test helper: assert `text` occupies the cells starting at (slot,col).
fn expectCells(slot: usize, col: usize, text: []const u8) !void {
    for (text, 0..) |ch, i| {
        try std.testing.expectEqual(@as(Cell, ch), ring[slot][col + i]);
    }
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
    try expectCells(cursor_slot(), 0, "byelo");
    // Backspace moves left without writing; the next char overwrites.
    putc(0x08);
    putc(0x08);
    try std.testing.expectEqual(@as(usize, 1), cur_col);
    putc('x');
    try expectCells(cursor_slot(), 0, "bxelo");
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

test "text: Ctrl-L's erase-in-display clears the layer instead of drawing '[2J'" {
    init();
    puts("junk on the screen");
    try std.testing.expect(ring_count >= 1);
    // The exact byte stream lineedit/monitor emit for Ctrl-L and `clear`.
    puts("\x1b[2J\x1b[H");
    try std.testing.expectEqual(@as(usize, 0), ring_count);
    try std.testing.expectEqual(@as(usize, 0), cur_col);
    // Storing the escape bytes would have drawn the glyphs '[2J[H' — the
    // ring must hold no such text afterwards.
    puts("ok");
    try std.testing.expectEqual(@as(Cell, 'o'), ring[cur_line][0]);
    try std.testing.expectEqual(@as(Cell, 'k'), ring[cur_line][1]);
    try std.testing.expectEqual(@as(usize, 2), cur_col);
    // An unhandled CSI sequence is swallowed whole, not rendered.
    puts("\x1b[1;31m!");
    try std.testing.expectEqual(@as(Cell, '!'), ring[cur_line][2]);
    try std.testing.expectEqual(@as(usize, 3), cur_col);
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

test "text: tab advances to the next multiple of the stop and fills spaces (U10)" {
    init();
    clear();
    puts("ab\tc");
    // 'a','b' at cols 0-1; tab jumps to col 8; 'c' lands at col 8 and
    // leaves the cursor at col 9.
    try std.testing.expectEqual(@as(usize, 9), cur_col);
    try expectCells(cur_line, 0, "ab");
    // The skipped cells hold real spaces (selection/copy see characters).
    try expectCells(cur_line, 2, "      ");
    try expectCells(cur_line, 8, "c");
}

test "text: tab stops land on successive multiples (U10)" {
    init();
    clear();
    puts("\t\t\t");
    try std.testing.expectEqual(@as(usize, 24), cur_col);
    // Mid-line: from col 5 the next multiple-of-8 stop is col 8.
    clear();
    puts("12345\tX");
    try std.testing.expectEqual(@as(Cell, 'X'), ring[cur_line][8]);
}

test "text: tab width is configurable (4-stop editor style) and clamped (U10)" {
    init();
    clear();
    set_tab_width(4);
    puts("\tx");
    try std.testing.expectEqual(@as(Cell, 'x'), ring[cur_line][4]);
    set_tab_width(0); // degenerate request clamps to 1, never divides by zero
    puts("\t");
    try std.testing.expectEqual(@as(usize, 6), cur_col);
    set_tab_width(100); // clamped to the 8 max
    try std.testing.expectEqual(@as(usize, 8), tab_width);
    set_tab_width(8);
}

test "text: tab near the region edge clamps without wrapping (U10)" {
    init();
    clear();
    puts("a"); // materialize a current line (cursor_slot would reset col 0 otherwise)
    cur_col = cols - 3;
    putc('\t');
    // Stop would be past the edge: the cursor parks at the region edge,
    // no new line is started.
    try std.testing.expectEqual(cols, cur_col);
    try std.testing.expectEqual(@as(usize, 1), ring_count);
}

test "text: monospace guarantee — narrow and wide glyphs occupy exactly one cell (U10)" {
    init();
    clear();
    puts("iW");
    const canvas = testCanvas();
    render(canvas);
    const fg = rgbBytes(fg_rgb);
    const bg = rgbBytes(bg_rgb);
    // Cell 0 ('i'): some foreground strictly inside x 0..7 …
    var any_fg_cell0 = false;
    var x: usize = 0;
    while (x < 8) : (x += 1) {
        if (std.mem.eql(u8, &fg, &pixel(canvas, x, 2))) any_fg_cell0 = true;
    }
    try std.testing.expect(any_fg_cell0);
    // … and NO cell-0 glyph pixels leak into cell 1's columns: pixel
    // column 7 belongs to 'i', column 8 to 'W' — the boundary is clean.
    _ = bg;
    // Cell 1 starts exactly at x=8: 'W' row bits must appear there, and
    // both cells rastered fully within their own 8px span (the render
    // loop draws exactly cell_w columns per cell — this pins it).
    var w_any = false;
    x = 8;
    while (x < 16) : (x += 1) {
        if (std.mem.eql(u8, &fg, &pixel(canvas, x, 0))) w_any = true;
    }
    try std.testing.expect(w_any);
}

test "text: char_width categories (U4)" {
    // Narrow: ASCII and the Latin ranges we render.
    try std.testing.expectEqual(@as(u8, 1), char_width('A'));
    try std.testing.expectEqual(@as(u8, 1), char_width(0x7E));
    try std.testing.expectEqual(@as(u8, 1), char_width(0xE9)); // é
    try std.testing.expectEqual(@as(u8, 1), char_width(0x160)); // Š
    // Wide: CJK ideographs, fullwidth forms, emoji.
    try std.testing.expectEqual(@as(u8, 2), char_width(0x4E2D)); // 中
    try std.testing.expectEqual(@as(u8, 2), char_width(0xFF21)); // Ａ fullwidth
    try std.testing.expectEqual(@as(u8, 2), char_width(0x1F525)); // fire
    // Zero: combining marks, joiners, variation selectors.
    try std.testing.expectEqual(@as(u8, 0), char_width(0x0301)); // combining acute
    try std.testing.expectEqual(@as(u8, 0), char_width(0x200D)); // ZWJ
    try std.testing.expectEqual(@as(u8, 0), char_width(0xFE0F)); // VS-16
    try std.testing.expect(is_combining(0x0332));
    try std.testing.expect(!is_combining('e'));
    try std.testing.expect(is_zero_width_ignorable(0x200B));
    try std.testing.expect(is_zero_width_ignorable(0xFE00));
    try std.testing.expect(!is_zero_width_ignorable(0x0301)); // combining is not ignorable
}

test "text: char_width is comptime-evaluable" {
    const w: u8 = comptime char_width(0x4E2D);
    _ = w;
}

test "text: UTF-8 é decodes and stores the Latin-1 literal cell (U2)" {
    init();
    clear();
    puts("caf\xc3\xa9"); // café
    try expectCells(cur_line, 0, "caf");
    try std.testing.expectEqual(@as(Cell, 0xE9), ring[cur_line][3]);
    try std.testing.expectEqual(@as(usize, 4), cur_col);
}

test "text: rendered é paints the accent-composed glyph, not blank (U2)" {
    init();
    clear();
    puts("\xc3\xa9");
    const canvas = testCanvas();
    render(canvas);
    const fg = rgbBytes(fg_rgb);
    const ee = font_unicode.latin1[0xE9 - 0xA0];
    // Every set bit of the composed glyph must appear on screen.
    var gy: usize = 0;
    while (gy < 8) : (gy += 1) {
        var gx: usize = 0;
        while (gx < 8) : (gx += 1) {
            if (font.row_pixel(ee[gy], gx)) {
                try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, gx, gy));
            }
        }
    }
    // And it is NOT identical to plain 'e' (the overlay is really drawn).
    const e_plain = font.glyphs['e' - 0x20];
    var differs = false;
    for (0..8) |i| {
        if (ee[i] != e_plain[i]) differs = true;
    }
    try std.testing.expect(differs);
}

test "text: a width-2 codepoint takes exactly two cells (U2/U4)" {
    init();
    clear();
    puts("a");
    putc_unicode(0x4E2D); // 中 — no glyph yet, but layout must hold
    putc_unicode('b');
    try expectCells(cur_line, 0, "a");
    try std.testing.expectEqual(cell_fffd, ring[cur_line][1]);
    try std.testing.expectEqual(cell_wide_cont, ring[cur_line][2]);
    try std.testing.expectEqual(@as(Cell, 'b'), ring[cur_line][3]);
    try std.testing.expectEqual(@as(usize, 4), cur_col);
}

test "text: broken UTF-8 becomes U+FFFD, not garbage cells (U2)" {
    init();
    clear();
    // Stray continuation byte.
    putc(0xA9);
    try std.testing.expectEqual(cell_fffd, ring[cur_line][0]);
    clear();
    // Truncated sequence at end of string: C3 alone never emits, so no
    // cell is written until the next byte arrives (which breaks it).
    puts("ok\xc3");
    try expectCells(cur_line, 0, "ok");
    try std.testing.expectEqual(@as(usize, 2), cur_col);
    putc('!'); // breaks the pending sequence: U+FFFD, THEN the byte itself
    try std.testing.expectEqual(cell_fffd, ring[cur_line][2]);
    try std.testing.expectEqual(@as(Cell, '!'), ring[cur_line][3]);
    try std.testing.expectEqual(@as(usize, 4), cur_col);
}

test "text: DEL and unknown control bytes stay invisible blanks (U2)" {
    init();
    clear();
    putc(0x7F);
    putc(0x01);
    try std.testing.expectEqual(@as(usize, 2), cur_col);
    const canvas = testCanvas();
    render(canvas); // must not crash painting them; cells are spaces
    try std.testing.expectEqual(@as(Cell, 0x20), ring[cur_line][0]);
}

test "text: missing glyph falls back to the replacement character (U11)" {
    init();
    clear();
    // U+FFFF is a guaranteed non-character: no table will ever hold it.
    putc_unicode(0xFFFF);
    try std.testing.expectEqual(cell_fffd, ring[cur_line][0]);
    const canvas = testCanvas();
    render(canvas);
    // The FFFD art (diamond) really paints — top row has foreground.
    const fg = rgbBytes(fg_rgb);
    var any_fg = false;
    for (0..8) |gx| {
        if (std.mem.eql(u8, &fg, &pixel(canvas, gx, 0))) any_fg = true;
    }
    try std.testing.expect(any_fg);
}

test "text: debug_font counts and reports misses through the hook (U11)" {
    init();
    clear();
    debug_font = false;
    putc_unicode(0x2603); // no glyph — but quiet when debug off
    try std.testing.expectEqual(@as(usize, 0), missing_glyph_count);
    debug_font = true;
    defer debug_font = false;
    missing_glyph_log = null;
    putc_unicode(0x2603);
    putc_unicode(0x10FFFF);
    try std.testing.expectEqual(@as(usize, 2), missing_glyph_count);
    try std.testing.expectEqual(@as(u21, 0x10FFFF), last_missing_cp);
    // A wired hook gets called (observable via a module-level flag).
    const S = struct {
        var called: bool = false;
        fn hook(cp: u21) void {
            called = true;
            std.testing.expectEqual(@as(u21, 0x2603), cp) catch {};
        }
    };
    missing_glyph_log = &S.hook;
    putc_unicode(0x2603);
    try std.testing.expect(S.called);
    missing_glyph_log = null;
}
