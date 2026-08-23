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
        o[0],        o[1] | 0x20, o[2] | 0x10, o[3] | 0x08,
        o[4] | 0x04, o[5] | 0x02, o[6] | 0x01, o[7],
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
    if (cp >= 0x100 and cp <= 0x17F) return &ext_a[cp - 0x100];
    return null;
}

/// The overlay bitmap for a combining diacritical mark (U+0300–U+036F
/// subset we support), or null when the mark has no art (the caller
/// ignores unknown marks per M20-U11's missing-combining rule).
pub fn combining_overlay(cp: u21) ?[8]u8 {
    const acc: ?Accent = switch (cp) {
        0x0300 => .grave,
        0x0301 => .acute,
        0x0302 => .circumflex,
        0x0303 => .tilde,
        0x0304 => .macron,
        0x0306 => .breve,
        0x0307 => .dot_above,
        0x0308 => .diaeresis,
        0x030A => .ring,
        0x030B => .double_acute,
        0x030C => .caron,
        0x0327 => .cedilla,
        0x0328 => .ogonek,
        else => null,
    };
    const a = acc orelse return null;
    return a.mask();
}

test "font_unicode: combining overlays exist for the common marks" {
    try std.testing.expect(combining_overlay(0x0301) != null); // acute
    try std.testing.expect(combining_overlay(0x0308) != null); // diaeresis
    try std.testing.expect(combining_overlay(0x0327) != null); // cedilla (below)
    try std.testing.expect(combining_overlay(0x0360) == null); // unarted double mark
}

// ---------------------------------------------------------------------------
// Latin Extended-A (M20-U3): U+0100–U+017F, same generation scheme —
// compose(base, accent) where possible, hand-authored for strokes,
// ligatures and specials.
// ---------------------------------------------------------------------------

const eth_stroke_upper: [8]u8 = .{ 0x0f, 0x1b, 0x33, 0x3f, 0x33, 0x1b, 0x0f, 0x00 };
const d_stroke_lower: [8]u8 = blk: {
    var g = ascii_glyph('d');
    g[2] |= 0x47;
    break :blk g;
};
const h_stroke_upper: [8]u8 = blk: {
    var g = ascii_glyph('H');
    g[4] |= 0x7f;
    break :blk g;
};
const h_stroke_lower: [8]u8 = blk: {
    var g = ascii_glyph('h');
    g[4] |= 0x7f;
    break :blk g;
};
const dotless_i: [8]u8 = blk: {
    var g = ascii_glyph('i');
    g[0] = 0;
    break :blk g;
};
const ij_upper: [8]u8 = .{ 0x77, 0x22, 0x22, 0x22, 0x22, 0x17, 0x18, 0x00 };
const ij_lower: [8]u8 = .{ 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x1f, 0x0c };
/// Kra: a k pushed down to x-height (no ascender).
const kra: [8]u8 = blk: {
    const k = ascii_glyph('k');
    break :blk .{ 0x00, 0x00, k[0], k[1], k[4], k[5], k[6], k[7] };
};
const l_middot_upper: [8]u8 = blk: {
    var g = ascii_glyph('L');
    g[3] |= 0x40;
    break :blk g;
};
const l_middot_lower: [8]u8 = blk: {
    var g = ascii_glyph('l');
    g[3] |= 0x60;
    break :blk g;
};
const l_slash_upper: [8]u8 = blk: {
    var g = ascii_glyph('L');
    g[2] |= 0x20;
    g[3] |= 0x18;
    g[4] |= 0x04;
    break :blk g;
};
const l_slash_lower: [8]u8 = blk: {
    var g = ascii_glyph('l');
    g[2] |= 0x20;
    g[3] |= 0x18;
    g[5] |= 0x02;
    break :blk g;
};
const apostrophe_n: [8]u8 = blk: {
    var g = ascii_glyph('n');
    g[0] |= 0x01;
    g[1] |= 0x01;
    break :blk g;
};
const eng_upper: [8]u8 = blk: {
    var g = ascii_glyph('N');
    g[6] |= 0x1c;
    break :blk g;
};
const eng_lower: [8]u8 = blk: {
    var g = ascii_glyph('n');
    g[6] |= 0x08;
    break :blk .{ g[0], g[1], g[2], g[3], g[4], g[5], g[6], 0x11 };
};
const oe_upper: [8]u8 = blk: {
    const o = ascii_glyph('O');
    const e_half = [_]u8{ 0x70, 0x10, 0x30, 0x10, 0x10, 0x70, 0x70, 0x00 };
    break :blk .{
        o[0],             o[1] | e_half[1], o[2] | e_half[2], o[3] | e_half[3],
        o[4] | e_half[4], o[5] | e_half[5], o[6] | e_half[6], o[7],
    };
};
const oe_lower: [8]u8 = blk: {
    const o = ascii_glyph('o');
    const e = ascii_glyph('e');
    break :blk .{
        o[0] | e[0], o[1] | e[1], o[2] | e[2], o[3] | e[3],
        o[4] | e[4], o[5] | e[5], o[6] | e[6], o[7] | e[7],
    };
};
const t_stroke_upper: [8]u8 = blk: {
    var g = ascii_glyph('T');
    g[3] |= 0x7f;
    break :blk g;
};
const t_stroke_lower: [8]u8 = blk: {
    var g = ascii_glyph('t');
    g[3] |= 0x63;
    break :blk g;
};
/// Long s: an f without the crossbar.
const long_s: [8]u8 = blk: {
    var g = ascii_glyph('f');
    g[3] = 0x06;
    break :blk g;
};

const EntryA = Entry;

/// U+0100–U+017F in order (128 entries). Index = codepoint − 0x100.
const ext_a_spec = [_]EntryA{
    e_comp('A', .macron), // 100 Ā
    e_comp('a', .macron), // 101 ā
    e_comp('A', .breve), // 102 Ă
    e_comp('a', .breve), // 103 ă
    e_comp('A', .ogonek), // 104 Ą
    e_comp('a', .ogonek), // 105 ą
    e_comp('C', .acute), // 106 Ć
    e_comp('c', .acute), // 107 ć
    e_comp('C', .circumflex), // 108 Ĉ
    e_comp('c', .circumflex), // 109 ĉ
    e_comp('C', .dot_above), // 10A Ċ
    e_comp('c', .dot_above), // 10B ċ
    e_comp('C', .caron), // 10C Č
    e_comp('c', .caron), // 10D č
    e_comp('D', .caron), // 10E Ď
    e_comp('d', .caron), // 10F ď
    e_hand(eth_stroke_upper), // 110 Đ
    e_hand(d_stroke_lower), // 111 đ
    e_comp('E', .macron), // 112 Ē
    e_comp('e', .macron), // 113 ē
    e_comp('E', .breve), // 114 Ĕ
    e_comp('e', .breve), // 115 ĕ
    e_comp('E', .dot_above), // 116 Ė
    e_comp('e', .dot_above), // 117 ė
    e_comp('E', .ogonek), // 118 Ę
    e_comp('e', .ogonek), // 119 ę
    e_comp('E', .caron), // 11A Ě
    e_comp('e', .caron), // 11B ě
    e_comp('G', .circumflex), // 11C Ĝ
    e_comp('g', .circumflex), // 11D ĝ
    e_comp('G', .breve), // 11E Ğ
    e_comp('g', .breve), // 11F ğ
    e_comp('G', .dot_above), // 120 Ġ
    e_comp('g', .dot_above), // 121 ġ
    e_comp('G', .cedilla), // 122 Ģ
    e_comp('g', .cedilla), // 123 ģ
    e_comp('H', .circumflex), // 124 Ĥ
    e_comp('h', .circumflex), // 125 ĥ
    e_hand(h_stroke_upper), // 126 Ħ
    e_hand(h_stroke_lower), // 127 ħ
    e_comp('I', .tilde), // 128 Ĩ
    e_comp('i', .tilde), // 129 ĩ
    e_comp('I', .macron), // 12A Ī
    e_comp('i', .macron), // 12B ī
    e_comp('I', .breve), // 12C Ĭ
    e_comp('i', .breve), // 12D ĭ
    e_comp('I', .ogonek), // 12E Į
    e_comp('i', .ogonek), // 12F į
    e_comp('I', .dot_above), // 130 İ
    e_hand(dotless_i), // 131 ı
    e_hand(ij_upper), // 132 Ĳ
    e_hand(ij_lower), // 133 ĳ
    e_comp('J', .circumflex), // 134 Ĵ
    e_comp('j', .circumflex), // 135 ĵ
    e_comp('K', .cedilla), // 136 Ķ
    e_comp('k', .cedilla), // 137 ķ
    e_hand(kra), // 138 ĸ
    e_comp('L', .acute), // 139 Ĺ
    e_comp('l', .acute), // 13A ĺ
    e_comp('L', .cedilla), // 13B Ļ
    e_comp('l', .cedilla), // 13C ļ
    e_comp('L', .caron), // 13D Ľ
    e_comp('l', .caron), // 13E ľ
    e_hand(l_middot_upper), // 13F Ŀ
    e_hand(l_middot_lower), // 140 ŀ
    e_hand(l_slash_upper), // 141 Ł
    e_hand(l_slash_lower), // 142 ł
    e_comp('N', .acute), // 143 Ń
    e_comp('n', .acute), // 144 ń
    e_comp('N', .cedilla), // 145 Ņ
    e_comp('n', .cedilla), // 146 ņ
    e_comp('N', .caron), // 147 Ň
    e_comp('n', .caron), // 148 ň
    e_hand(apostrophe_n), // 149 ŉ
    e_hand(eng_upper), // 14A Ŋ
    e_hand(eng_lower), // 14B ŋ
    e_comp('O', .macron), // 14C Ō
    e_comp('o', .macron), // 14D ō
    e_comp('O', .breve), // 14E Ŏ
    e_comp('o', .breve), // 14F ŏ
    e_comp('O', .double_acute), // 150 Ő
    e_comp('o', .double_acute), // 151 ő
    e_hand(oe_upper), // 152 Œ
    e_hand(oe_lower), // 153 œ
    e_comp('R', .acute), // 154 Ŕ
    e_comp('r', .acute), // 155 ŕ
    e_comp('R', .cedilla), // 156 Ŗ
    e_comp('r', .cedilla), // 157 ŗ
    e_comp('R', .caron), // 158 Ř
    e_comp('r', .caron), // 159 ř
    e_comp('S', .acute), // 15A Ś
    e_comp('s', .acute), // 15B ś
    e_comp('S', .circumflex), // 15C Ŝ
    e_comp('s', .circumflex), // 15D ŝ
    e_comp('S', .cedilla), // 15E Ş
    e_comp('s', .cedilla), // 15F ş
    e_comp('S', .caron), // 160 Š
    e_comp('s', .caron), // 161 š
    e_comp('T', .cedilla), // 162 Ţ
    e_comp('t', .cedilla), // 163 ţ
    e_comp('T', .caron), // 164 Ť
    e_comp('t', .caron), // 165 ť
    e_hand(t_stroke_upper), // 166 Ŧ
    e_hand(t_stroke_lower), // 167 ŧ
    e_comp('U', .tilde), // 168 Ũ
    e_comp('u', .tilde), // 169 ũ
    e_comp('U', .macron), // 16A Ū
    e_comp('u', .macron), // 16B ū
    e_comp('U', .breve), // 16C Ŭ
    e_comp('u', .breve), // 16D ŭ
    e_comp('U', .ring), // 16E Ů
    e_comp('u', .ring), // 16F ů
    e_comp('U', .double_acute), // 170 Ű
    e_comp('u', .double_acute), // 171 ű
    e_comp('U', .ogonek), // 172 Ų
    e_comp('u', .ogonek), // 173 ų
    e_comp('W', .circumflex), // 174 Ŵ
    e_comp('w', .circumflex), // 175 ŵ
    e_comp('Y', .circumflex), // 176 Ŷ
    e_comp('y', .circumflex), // 177 ŷ
    e_comp('Y', .diaeresis), // 178 Ÿ
    e_comp('Z', .acute), // 179 Ź
    e_comp('z', .acute), // 17A ź
    e_comp('Z', .dot_above), // 17B Ż
    e_comp('z', .dot_above), // 17C ż
    e_comp('Z', .caron), // 17D Ž
    e_comp('z', .caron), // 17E ž
    e_hand(long_s), // 17F ſ
};

/// The rendered Latin Extended-A table: index = codepoint − 0x100.
pub const ext_a: [128][8]u8 = blk: {
    @setEvalBranchQuota(20000);
    var out: [128][8]u8 = undefined;
    for (ext_a_spec, 0..) |entry, i| {
        out[i] = switch (entry) {
            .hand => |g| g,
            .comp => |c| compose(c.base, c.acc),
        };
    }
    break :blk out;
};

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
    try std.testing.expect(glyph(0x180) == null); // past both Latin tables
}

test "font_unicode: Ext-A covers the whole block with real art (M20-U3)" {
    // Š composes S + caron: body matches, top rows gain pixels.
    const s = font.glyphs['S' - 0x20];
    const scaron = ext_a[0x160 - 0x100];
    var overlay = false;
    for (0..3) |i| {
        if ((scaron[i] & ~s[i]) != 0) overlay = true;
    }
    try std.testing.expect(overlay);
    // Every entry is tabled and non-blank (no silent holes in the block).
    for (ext_a, 0..) |g, i| {
        const cp = 0x100 + i;
        if (cp >= 0x0132 and cp <= 0x0133) continue; // IJ has intentional ink
        var any = false;
        for (g) |row| {
            if (row != 0) any = true;
        }
        try std.testing.expect(any);
    }
    // The long s is NOT identical to f (crossbar removed).
    const f = font.glyphs['f' - 0x20];
    try std.testing.expect(!std.mem.eql(u8, &f, &ext_a[0x17F - 0x100]));
}

test "font_unicode: FFFD is the diamond-with-question-mark silhouette" {
    // Diamond outline present on the outer rows, widest in the middle.
    try std.testing.expectEqual(@as(u8, 0x7e), fffd_glyph[0]);
    try std.testing.expectEqual(@as(u8, 0x7e), fffd_glyph[7]);
    try std.testing.expectEqual(@as(u8, 0xe7), fffd_glyph[3]);
    try std.testing.expect(fffd_glyph[2] != 0);
}
