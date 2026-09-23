//! M73l (issue #1661) deliverable 1 — the glyph-atlas codegen and its
//! drift tripwire.
//!
//! Why codegen instead of a comptime kernel bake (observed 2026-09-22):
//! the kernel package root is kernel/src, so from inside it both
//! `@import("../../user/src/lib/font_ttf.zig")` and
//! `@embedFile("../../image/fonts/…")` fail with *import of file outside
//! module path* — the engine and the font bytes are unreachable at
//! kernel comptime without build.zig surgery on every root that imports
//! text.zig. This tool sits in user/src/lib (the engine's own package),
//! reads the TTF at run time, renders printable ASCII at pixel size 13
//! through the single engine, and writes kernel/src/font_atlas_data.zig:
//! a small checked-in byte-vector fixture the kernel imports from its
//! own directory with zero build wiring.
//!
//! Regenerate (repo root):  zig run user/src/lib/font_atlas_gen.zig
//! Tripwire   (repo root):  zig test user/src/lib/font_atlas_gen.zig
//!   — re-renders and byte-compares the checked-in file, so any engine
//!     or font change reddens the gate until the fixture is deliberately
//!     regenerated and the diff reviewed.

const std = @import("std");
const ttf = @import("font_ttf.zig");

pub const ttf_path = "image/fonts/FiraCode-Regular.ttf";
pub const out_path = "kernel/src/font_atlas_data.zig";

/// Design cell for pixel size 13 — measured, not guessed: FiraCode
/// Regular has upem 1950 and M=W=x advance 1200 units, so
/// measure_string(13, "M") == 8 px exactly, and hhea ascender/descender
/// round to 12+4 = 16 px tall. `render` re-derives all three from the
/// face and errors if the face ever moves.
pub const px_size: u32 = 13;
pub const cell_w: u32 = 8;
pub const cell_h: u32 = 16;
pub const first_cp: u32 = 0x20;
pub const last_cp: u32 = 0x7E;
pub const glyph_count: usize = last_cp - first_cp + 1; // 95
pub const row_bytes: usize = cell_w / 2; // 4-bit AA: two pixels per byte
pub const glyph_bytes: usize = cell_h * row_bytes; // 64
pub const atlas_bytes: usize = glyph_count * glyph_bytes; // 6080

pub const Atlas = struct {
    adv: u32,
    ascent: u32, // baseline rows from the cell top
    descent: u32, // cell_h - ascent
    /// [95][64]u8, row-major: glyph (cp-0x20), row y, byte y*4 + x/2,
    /// high nibble = even x, low nibble = odd x, level 0..15 = alpha/17.
    cells: [glyph_count][glyph_bytes]u8,
};

/// Render every printable ASCII glyph through the engine and compose it
/// into its cell: pen x = 0 at the cell's left edge, baseline `ascent`
/// rows down, engine 8-bit alpha downsampled to 4 bits (16 levels — the
/// classic greyscale-font precision, and it halves the fixture).
pub fn render(face: *const ttf.TrueTypeFace) !Atlas {
    const upem: f64 = @floatFromInt(face.units_per_em);
    const adv: u32 = @intCast(face.measure_string(px_size, "M"));
    const asc_f: f64 = @as(f64, @floatFromInt(face.ascender)) * @as(f64, @floatFromInt(px_size)) / upem;
    const desc_f: f64 = @as(f64, @floatFromInt(face.descender)) * @as(f64, @floatFromInt(px_size)) / upem;
    const ascent: u32 = @intFromFloat(@round(asc_f));
    const descent: u32 = @intFromFloat(@round(-desc_f)); // descender is negative

    var atlas: Atlas = .{ .adv = adv, .ascent = ascent, .descent = descent, .cells = .{.{0} ** glyph_bytes} ** glyph_count };
    if (adv != cell_w) return error.MetricsDrift;
    if (ascent + descent != cell_h) return error.MetricsDrift;

    var cache: ttf.TrueTypeFace.GlyphCache = .{};
    for (first_cp..last_cp + 1) |cp_usize| {
        const cp: u32 = @intCast(cp_usize);
        const gi = cp - first_cp;
        const g = cache.get_or_render(face, cp, px_size) orelse return error.RenderFailed;
        if (g.width == 0 or g.height == 0) continue; // space: cell stays zero
        const a = cache.glyph_alpha(g);
        // Pen starts at the cell's left edge; the baseline sits `ascent`
        // rows down, and bearing_y counts up from the baseline.
        const dx: i32 = g.bearing_x;
        const dy: i32 = @as(i32, @intCast(ascent)) - g.bearing_y;
        var gy: u32 = 0;
        while (gy < g.height) : (gy += 1) {
            const cy = dy + @as(i32, @intCast(gy));
            if (cy < 0 or cy >= cell_h) continue;
            var gx: u32 = 0;
            while (gx < g.width) : (gx += 1) {
                const cx = dx + @as(i32, @intCast(gx));
                if (cx < 0 or cx >= cell_w) continue;
                const lvl = a[@as(usize, @intCast(gy)) * g.width + @as(usize, @intCast(gx))] >> 4;
                if (lvl == 0) continue;
                const bi = @as(usize, @intCast(cy)) * row_bytes + @as(usize, @intCast(cx)) / 2;
                if (@rem(cx, 2) == 0) {
                    atlas.cells[gi][bi] |= lvl << 4;
                } else {
                    atlas.cells[gi][bi] |= lvl;
                }
            }
        }
    }
    return atlas;
}

/// The complete text of kernel/src/font_atlas_data.zig — one
/// allocPrint plus a hand-encoded hex blob (string literals are the one
/// thing `zig fmt` never reflows, so the fixture is fmt-stable by
/// construction).
pub fn generateSource(alloc: std.mem.Allocator, face: *const ttf.TrueTypeFace) ![]u8 {
    const atlas = try render(face);
    const hex = try alloc.alloc(u8, atlas_bytes * 4);
    const digits = "0123456789abcdef";
    var i: usize = 0;
    for (atlas.cells) |cell| {
        for (cell) |b| {
            hex[i] = '\\';
            hex[i + 1] = 'x';
            hex[i + 2] = digits[b >> 4];
            hex[i + 3] = digits[b & 0xF];
            i += 4;
        }
    }
    // allocPrint copies the bytes into the result string.
    defer alloc.free(hex);
    return std.fmt.allocPrint(alloc,
        \\//! GENERATED FILE — do not edit. Regenerate:
        \\//!   zig run user/src/lib/font_atlas_gen.zig   (repo root)
        \\//! Tripwire (byte-compares this file against a fresh render):
        \\//!   zig test user/src/lib/font_atlas_gen.zig   (repo root)
        \\//!
        \\//! M73l (#1661): FiraCode-Regular at pixel size {d} through
        \\//! user/src/lib/font_ttf.zig — printable ASCII 0x20..0x7E, cell
        \\//! {d}x{d}, 4-bit alpha (level v = alpha v*17), baseline {d} rows
        \\//! from the cell top ({d} ascender + {d} descender).
        \\//! Layout: glyph (cp-32) starts at blob[(cp-32)*{d}]; row y is
        \\//! blob[off + y*{d} .. off + (y+1)*{d}]; high nibble = even x,
        \\//! low nibble = odd x.
        \\
        \\pub const px_size: u32 = {d};
        \\pub const cell_w: u32 = {d};
        \\pub const cell_h: u32 = {d};
        \\pub const adv: u32 = {d};
        \\pub const ascent: u32 = {d};
        \\pub const descent: u32 = {d};
        \\pub const first_cp: u32 = {d};
        \\pub const last_cp: u32 = {d};
        \\pub const glyph_count: usize = {d};
        \\pub const glyph_bytes: usize = {d};
        \\pub const atlas_bytes: usize = {d};
        \\pub const blob: *const [{d}:0]u8 =
        \\    "{s}";
        \\
    , .{
        // header: pixel size, cell, baseline, descender split, layout
        px_size,
        cell_w,
        cell_h,
        atlas.ascent,
        atlas.ascent,
        atlas.descent,
        glyph_bytes,
        row_bytes,
        row_bytes,
        // const block
        px_size,
        cell_w,
        cell_h,
        atlas.adv,
        atlas.ascent,
        atlas.descent,
        first_cp,
        last_cp,
        glyph_count,
        glyph_bytes,
        atlas_bytes,
        atlas_bytes,
        hex,
    });
}

fn loadFira(alloc: std.mem.Allocator) ![]u8 {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    return std.Io.Dir.cwd().readFileAlloc(io, ttf_path, alloc, std.Io.Limit.limited(2 * 1024 * 1024));
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const fira = try loadFira(alloc);
    var face = try ttf.TrueTypeFace.init(fira);
    const src = try generateSource(alloc, &face);
    var io_impl = std.Io.Threaded.init_single_threaded;
    try std.Io.Dir.cwd().writeFile(io_impl.io(), .{ .sub_path = out_path, .data = src });
    std.debug.print("font_atlas_gen: wrote {s} ({d} bytes)\n", .{ out_path, src.len });
}

test "checked-in atlas is exactly a fresh engine render" {
    const alloc = std.testing.allocator;
    const fira = try loadFira(alloc);
    defer alloc.free(fira);
    var face = try ttf.TrueTypeFace.init(fira);
    const fresh = try generateSource(alloc, &face);
    defer alloc.free(fresh);

    var io_impl = std.Io.Threaded.init_single_threaded;
    const checked = try std.Io.Dir.cwd().readFileAlloc(io_impl.io(), out_path, alloc, std.Io.Limit.limited(512 * 1024));
    defer alloc.free(checked);
    // The tripwire: an engine or font change reddens here until the
    // fixture is regenerated on purpose and the diff reviewed.
    try std.testing.expectEqualStrings(fresh, checked);
}

test "cell metrics pin at pixel size 13" {
    const alloc = std.testing.allocator;
    const fira = try loadFira(alloc);
    defer alloc.free(fira);
    var face = try ttf.TrueTypeFace.init(fira);
    const atlas = try render(&face);

    // The three numbers every /8 geometry site in the kernel becomes.
    try std.testing.expectEqual(@as(u32, 8), atlas.adv);
    try std.testing.expectEqual(@as(u32, 12), atlas.ascent);
    try std.testing.expectEqual(@as(u32, 4), atlas.descent);
    try std.testing.expectEqual(cell_h, atlas.ascent + atlas.descent);

    // Space is the empty cell.
    var space_ink: u32 = 0;
    for (atlas.cells[0]) |b| space_ink += b;
    try std.testing.expectEqual(@as(u32, 0), space_ink);

    // The engine actually inked the rest: a conservative floor over
    // 94 glyphs x 128 nibbles (typical coverage lands well above it).
    var total: u64 = 0;
    for (atlas.cells[1..]) |cell| {
        for (cell) |b| total += b;
    }
    try std.testing.expect(total > 0x1000);
}
