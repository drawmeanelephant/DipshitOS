//! VirelaiOS Shared Font Library (LIBFONT.SO, Milestone 30 Dynamic Linking).
//!
//! Freestanding shared library implementing glyph lookup, string metrics,
//! and 8x8 bitmap font rendering for userland applications.

const std = @import("std");
pub const font8x8 = @import("lib/font8x8.zig");

pub export fn font_glyph_8x8(char: u8, out_glyph: [*]u8) void {
    if (char < 0x20 or char > 0x7e) {
        @memset(out_glyph[0..8], 0);
        return;
    }
    const g = font8x8.glyphs[char - 0x20];
    @memcpy(out_glyph[0..8], &g);
}

pub export fn font_measure_8x8(str: [*:0]const u8) u32 {
    const s = std.mem.sliceTo(str, 0);
    return @intCast(s.len * 8);
}

pub export fn font_char_width() u32 {
    return 8;
}

pub export fn font_char_height() u32 {
    return 8;
}
