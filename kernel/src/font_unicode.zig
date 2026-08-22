//! Unicode bitmap fonts — Latin-1 Supplement first (M20-U2), generated at
//! comptime from the ASCII source table plus hand-authored symbols.
//!
//! Every glyph is 8×8 monochrome, LSB-first (pixel `x` is `(row >> x) & 1`,
//! the same convention as `font8x8.row_pixel`). Accented letters are
//! composed at comptime: base-letter glyph OR the accent mask. Symbols
//! without an ASCII base are hand-authored here and pinned by goldens.
//! This is ROM, not BSS — comptime arrays cost nothing at boot.

const std = @import("std");
const font = @import("font8x8.zig");

/// The U+FFFD REPLACEMENT CHARACTER: a diamond with a question mark
/// inside (the missing-glyph fallback, M20-U11).
pub const fffd_glyph: [8]u8 = .{
    0x7e, 0xbd, 0xdb, 0xe7, 0xe7, 0xdb, 0xbd, 0x7e,
};

/// U+25CC DOTTED CIRCLE — the conventional base for a combining mark
/// that arrives with no preceding character (M20-U6).
pub const dotted_circle: [8]u8 = .{
    0x00, 0x2a, 0x91, 0x45, 0xa1, 0x54, 0x00, 0x00,
};

/// Accent overlay masks ([8]u8 rows, LSB-first). Only the top three rows
/// (or the bottom two for below-baselines) carry pixels, so the OR keeps
/// the base letter legible at 8×8 fidelity.
pub const Accent = enum {
    acute,
    grave,
    circumflex,
    diaeresis,
    tilde,
    ring,
    macron,
    cedilla,
    caron,
    breve,
    dot_above,
    ogonek,
    double_acute,

    pub fn mask(a: Accent) [8]u8 {
        return switch (a) {
            .acute => .{ 0x10, 0x08, 0x04, 0, 0, 0, 0, 0 },
            .grave => .{ 0x08, 0x10, 0x20, 0, 0, 0, 0, 0 },
            .circumflex => .{ 0x10, 0x28, 0, 0, 0, 0, 0, 0 },
            .diaeresis => .{ 0, 0x24, 0, 0, 0, 0, 0, 0 },
            .tilde => .{ 0x18, 0x24, 0, 0, 0, 0, 0, 0 },
            .ring => .{ 0x18, 0x24, 0x18, 0, 0, 0, 0, 0 },
            .macron => .{ 0, 0x3c, 0, 0, 0, 0, 0, 0 },
            .cedilla => .{ 0, 0, 0, 0, 0, 0x10, 0x08, 0x08 },
            .caron => .{ 0x28, 0x10, 0, 0, 0, 0, 0, 0 },
            .breve => .{ 0x14, 0x08, 0, 0, 0, 0, 0, 0 },
            .dot_above => .{ 0, 0x10, 0, 0, 0, 0, 0, 0 },
            .ogonek => .{ 0, 0, 0, 0, 0, 0, 0x18, 0x04 },
            .double_acute => .{ 0x14, 0x28, 0, 0, 0, 0, 0, 0 },
        };
    }
};

/// Vertically flip a glyph (¡ and ¿ reuse ! and ? upside-down).
fn flip_v(g: [8]u8) [8]u8 {
    var out: [8]u8 = undefined;
    for (0..8) |i| out[i] = g[7 - i];
    return out;
}

fn ascii_glyph(ch: u8) [8]u8 {
    return font.glyphs[ch - 0x20];
}

/// Compose a base ASCII letter with an accent mask.
fn compose(base_ch: u8, acc: Accent) [8]u8 {
    const g = ascii_glyph(base_ch);
    const m = acc.mask();
    var out: [8]u8 = undefined;
    for (0..8) |i| out[i] = g[i] | m[i];
    return out;
}

// Hand-authored symbol glyphs (no ASCII base to compose from).

const exclam_inv = flip_v(ascii_glyph('!'));
const question_inv = flip_v(ascii_glyph('?'));
const cent: [8]u8 = .{ 0x00, 0x18, 0x1e, 0x3b, 0x1b, 0x3b, 0x1e, 0x18 };
const pound: [8]u8 = .{ 0x06, 0x09, 0x1e, 0x0c, 0x1e, 0x33, 0x7e, 0x00 };
const currency: [8]u8 = .{ 0x00, 0x24, 0x18, 0x18, 0x24, 0x00, 0x00, 0x00 };
/// Yen: the Y glyph plus double crossbars through the stem.
const yen: [8]u8 = blk: {
    var g = ascii_glyph('Y');
    g[4] |= 0x3e;
    g[5] |= 0x3e;
    break :blk g;
};
const broken_bar: [8]u8 = ascii_glyph('|');
const section: [8]u8 = .{ 0x06, 0x09, 0x06, 0x09, 0x06, 0x09, 0x06, 0x00 };
const diaeresis_alone: [8]u8 = .{ 0x00, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
const copyright: [8]u8 = .{ 0x1c, 0x22, 0x4d, 0x45, 0x45, 0x4d, 0x22, 0x1c };
const ordfeminine: [8]u8 = .{ 0x38, 0x48, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00 };
const guillemet_left: [8]u8 = .{ 0x00, 0x12, 0x24, 0x48, 0x24, 0x12, 0x00, 0x00 };
const not_sign: [8]u8 = .{ 0x00, 0x00, 0x7c, 0x40, 0x40, 0x00, 0x00, 0x00 };
const registered: [8]u8 = .{ 0x1c, 0x22, 0x5d, 0x55, 0x55, 0x4d, 0x22, 0x1c };
const macron_alone: [8]u8 = .{ 0x00, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
const degree: [8]u8 = .{ 0x00, 0x18, 0x24, 0x18, 0x00, 0x00, 0x00, 0x00 };
const plusminus: [8]u8 = .{ 0x0c, 0x0c, 0x3f, 0x0c, 0x0c, 0x00, 0x3f, 0x00 };
const sup2: [8]u8 = .{ 0x1c, 0x36, 0x0c, 0x18, 0x3c, 0x00, 0x00, 0x00 };
const sup3: [8]u8 = .{ 0x1c, 0x36, 0x0c, 0x36, 0x1c, 0x00, 0x00, 0x00 };
const acute_alone: [8]u8 = .{ 0x00, 0x20, 0x10, 0x08, 0x00, 0x00, 0x00, 0x00 };
const micro: [8]u8 = .{ 0x00, 0x00, 0x33, 0x33, 0x33, 0x3b, 0x6f, 0x01 };
const pilcrow: [8]u8 = .{ 0x3c, 0x66, 0x66, 0x3c, 0x18, 0x18, 0x18, 0x00 };
const middot: [8]u8 = .{ 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00 };
const cedilla_alone: [8]u8 = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x08, 0x10 };
const sup1: [8]u8 = .{ 0x18, 0x38, 0x18, 0x18, 0x3c, 0x00, 0x00, 0x00 };
const ordmasculine: [8]u8 = .{ 0x18, 0x24, 0x24, 0x18, 0x00, 0x00, 0x00, 0x00 };
const guillemet_right: [8]u8 = .{ 0x00, 0x48, 0x24, 0x12, 0x24, 0x48, 0x00, 0x00 };
const quarter: [8]u8 = .{ 0x02, 0x12, 0x12, 0x6f, 0xa0, 0x20, 0xe0, 0x00 };
const half: [8]u8 = .{ 0x02, 0x12, 0x12, 0x3f, 0x60, 0x60, 0xe0, 0x00 };
const threequarters: [8]u8 = .{ 0x60, 0x50, 0x70, 0x60, 0xa0, 0x20, 0xe0, 0x00 };

// Hand-authored letters with no clean base+accent decomposition.
const ae_upper: [8]u8 = .{ 0x00, 0x76, 0x19, 0x3f, 0x19, 0x19, 0x76, 0x00 };
const ae_lower: [8]u8 = .{ 0x00, 0x00, 0x76, 0x19, 0x3f, 0x19, 0x19, 0x76 };
const o_slash_upper: [8]u8 = blk: {
    const o = ascii_glyph('O');
    break :blk .{
        o[0],           o[1] | 0x20, o[2] | 0x10, o[3] | 0x08,
        o[4] | 0x04,    o[5] | 0x02, o[6] | 0x01, o[7],
    };
};
const o_slash_lower: [8]u8 = blk: {
    const o = ascii_glyph('o');
    break :blk .{
        o[0],        o[1],        o[2] | 0x20, o[3] | 0x10,
        o[4] | 0x08, o[5] | 0x04, o[6],        o[7],
    };
};
const eth_upper: [8]u8 = .{ 0x0f, 0x1b, 0x33, 0x3f, 0x33, 0x1b, 0x0f, 0x00 };
const eth_lower: [8]u8 = .{ 0x3b, 0x30, 0x30, 0x3e, 0x33, 0x33, 0x6e, 0x00 };
/// Thorn: full-height stem with a closed bowl (Þ).
const thorn_upper: [8]u8 = .{ 0x02, 0x3e, 0x26, 0x26, 0x3e, 0x02, 0x02, 0x02 };
const thorn_lower: [8]u8 = thorn_upper;
const sharp_s: [8]u8 = .{ 0x1c, 0x22, 0x3c, 0x22, 0x22, 0x3c, 0x00, 0x00 };
const multiply: [8]u8 = .{ 0x00, 0x41, 0x22, 0x14, 0x22, 0x41, 0x00, 0x00 };
const divide: [8]u8 = .{ 0x00, 0x18, 0x00, 0x3c, 0x00, 0x18, 0x00, 0x00 };

/// One entry of the Latin-1 generation table: codepoint → glyph spec.
const Entry = union(enum) {
    hand: [8]u8,
    comp: struct { base: u8, acc: Accent },
};

fn e_hand(g: [8]u8) Entry {
    return .{ .hand = g };
}
fn e_comp(base: u8, acc: Accent) Entry {
    return .{ .comp = .{ .base = base, .acc = acc } };
}

/// U+00A0–U+00FF in order (96 entries). Index = codepoint − 0xA0.
const latin1_spec = [_]Entry{
    e_hand(.{ 0, 0, 0, 0, 0, 0, 0, 0 }), // A0 NBSP renders blank
    e_hand(exclam_inv), // A1 ¡
    e_hand(cent), // A2 ¢
    e_hand(pound), // A3 £
    e_hand(currency), // A4 ¤
    e_hand(yen), // A5 ¥
    e_hand(broken_bar), // A6 ¦
    e_hand(section), // A7 §
    e_hand(diaeresis_alone), // A8 ¨
    e_hand(copyright), // A9 ©
    e_hand(ordfeminine), // AA ª
    e_hand(guillemet_left), // AB «
    e_hand(not_sign), // AC ¬
    e_hand(ascii_glyph('-')), // AD soft hyphen renders as a plain hyphen
    e_hand(registered), // AE ®
    e_hand(macron_alone), // AF ¯
    e_hand(degree), // B0 °
    e_hand(plusminus), // B1 ±
    e_hand(sup2), // B2 ²
    e_hand(sup3), // B3 ³
    e_hand(acute_alone), // B4 ´
    e_hand(micro), // B5 µ
    e_hand(pilcrow), // B6 ¶
    e_hand(middot), // B7 ·
    e_hand(cedilla_alone), // B8 ¸
    e_hand(sup1), // B9 ¹
    e_hand(ordmasculine), // BA º
    e_hand(guillemet_right), // BB »
    e_hand(quarter), // BC ¼
    e_hand(half), // BD ½
    e_hand(threequarters), // BE ¾
    e_hand(question_inv), // BF ¿
    e_comp('A', .grave), // C0 À
    e_comp('A', .acute), // C1 Á
    e_comp('A', .circumflex), // C2 Â
    e_comp('A', .tilde), // C3 Ã
    e_comp('A', .diaeresis), // C4 Ä
    e_comp('A', .ring), // C5 Å
    e_hand(ae_upper), // C6 Æ
    e_comp('C', .cedilla), // C7 Ç
    e_comp('E', .grave), // C8 È
    e_comp('E', .acute), // C9 É
    e_comp('E', .circumflex), // CA Ê
    e_comp('E', .diaeresis), // CB Ë
    e_comp('I', .grave), // CC Ì
    e_comp('I', .acute), // CD Í
    e_comp('I', .circumflex), // CE Î
    e_comp('I', .diaeresis), // CF Ï
    e_hand(eth_upper), // D0 Ð
    e_comp('N', .tilde), // D1 Ñ
    e_comp('O', .grave), // D2 Ò
    e_comp('O', .acute), // D3 Ó
    e_comp('O', .circumflex), // D4 Ô
    e_comp('O', .tilde), // D5 Õ
    e_comp('O', .diaeresis), // D6 Ö
    e_hand(multiply), // D7 ×
    e_hand(o_slash_upper), // D8 Ø
    e_comp('U', .grave), // D9 Ù
    e_comp('U', .acute), // DA Ú
    e_comp('U', .circumflex), // DB Û
    e_comp('U', .diaeresis), // DC Ü
    e_comp('Y', .acute), // DD Ý
    e_hand(thorn_upper), // DE Þ
    e_hand(sharp_s), // DF ß
    e_comp('a', .grave), // E0 à
    e_comp('a', .acute), // E1 á
    e_comp('a', .circumflex), // E2 â
    e_comp('a', .tilde), // E3 ã
    e_comp('a', .diaeresis), // E4 ä
    e_comp('a', .ring), // E5 å
    e_hand(ae_lower), // E6 æ
    e_comp('c', .cedilla), // E7 ç
    e_comp('e', .grave), // E8 è
    e_comp('e', .acute), // E9 é
    e_comp('e', .circumflex), // EA ê
    e_comp('e', .diaeresis), // EB ë
    e_comp('i', .grave), // EC ì
    e_comp('i', .acute), // ED í
    e_comp('i', .circumflex), // EE î
    e_comp('i', .diaeresis), // EF ï
    e_hand(eth_lower), // F0 ð
    e_comp('n', .tilde), // F1 ñ
    e_comp('o', .grave), // F2 ò
    e_comp('o', .acute), // F3 ó
    e_comp('o', .circumflex), // F4 ô
    e_comp('o', .tilde), // F5 õ
    e_comp('o', .diaeresis), // F6 ö
    e_hand(divide), // F7 ÷
    e_hand(o_slash_lower), // F8 ø
    e_comp('u', .grave), // F9 ù
    e_comp('u', .acute), // FA ú
    e_comp('u', .circumflex), // FB û
    e_comp('u', .diaeresis), // FC ü
    e_comp('y', .acute), // FD ý
    e_hand(thorn_lower), // FE þ
    e_comp('y', .diaeresis), // FF ÿ
};

/// The rendered Latin-1 table: index = codepoint − 0xA0.
pub const latin1: [96][8]u8 = blk: {
    var out: [96][8]u8 = undefined;
    for (latin1_spec, 0..) |entry, i| {
        out[i] = switch (entry) {
            .hand => |g| g,
            .comp => |c| compose(c.base, c.acc),
        };
    }
    break :blk out;
};

/// Look up a glyph for codepoints ≥ 0xA0. Returns null when there is no
/// table entry (caller applies the M20-U11 fallback).
pub fn glyph(cp: u21) ?*const [8]u8 {
    if (cp >= 0xA0 and cp <= 0xFF) return &latin1[cp - 0xA0];
    return null;
}

test "font_unicode: é composes e with an acute overlay in the top rows" {
    const e = font.glyphs['e' - 0x20];
    const ee = latin1[0xE9 - 0xA0];
    // Body identical to 'e' …
    for (3..8) |i| try std.testing.expectEqual(e[i], ee[i]);
    // … plus the acute stroke somewhere in the top rows.
    var overlay = false;
    for (0..3) |i| {
        if ((ee[i] & ~e[i]) != 0) overlay = true;
    }
    try std.testing.expect(overlay);
}

test "font_unicode: ¡ and ¿ are vertical flips of ! and ?" {
    const bang = font.glyphs['!' - 0x20];
    const inv = latin1[0xA1 - 0xA0];
    for (0..8) |i| try std.testing.expectEqual(bang[7 - i], inv[i]);
    const q = font.glyphs['?' - 0x20];
    const qi = latin1[0xBF - 0xA0];
    for (0..8) |i| try std.testing.expectEqual(q[7 - i], qi[i]);
}

test "font_unicode: NBSP is blank, lookup rejects untabled ranges" {
    for (latin1[0xA0 - 0xA0]) |row| try std.testing.expectEqual(@as(u8, 0), row);
    try std.testing.expect(glyph(0xE9) != null);
    try std.testing.expect(glyph(0x7F) == null);
    try std.testing.expect(glyph(0x180) == null); // Ext-A lands with U3
}

test "font_unicode: FFFD is the diamond-with-question-mark silhouette" {
    // Diamond outline present on the outer rows, widest in the middle.
    try std.testing.expectEqual(@as(u8, 0x7e), fffd_glyph[0]);
    try std.testing.expectEqual(@as(u8, 0x7e), fffd_glyph[7]);
    try std.testing.expectEqual(@as(u8, 0xe7), fffd_glyph[3]);
    try std.testing.expect(fffd_glyph[2] != 0);
}
