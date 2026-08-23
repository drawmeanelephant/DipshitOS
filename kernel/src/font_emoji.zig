//! Basic emoji support (M20-U7) — hand-built 16×16 monochrome pixel art,
//! rendered TWO terminal cells wide at any font size.
//!
//! Scope bound (honest): Unicode names ~3,000 emoji; this table ships a
//! curated subset covering every category the card lists — faces,
//! gestures, objects, nature, food, symbols. The lookup/render machinery
//! is complete; new art is one entry away. No skin tones, no ZWJ
//! sequences (the card's own exclusions).
//!
//! Art method: glyphs are constructed at comptime from integer geometry
//! (discs, rings, bars) so every glyph is deterministic and symmetric by
//! construction. Rows are `[16]u16`, bit x = column x (LSB-first, same
//! convention as the Latin fonts). ROM only — zero BSS.

const std = @import("std");

pub const Emoji = struct {
    cp: u21,
    rows: [16]u16,
};

const I = i32;

/// Inside the disc centered (cx,cy) with radius r (inclusive).
fn disc(x: usize, y: usize, cx: I, cy: I, r: I) bool {
    const dx = @as(I, @intCast(x)) - cx;
    const dy = @as(I, @intCast(y)) - cy;
    return dx * dx + dy * dy <= r * r;
}

/// Inside the ring between radii ri and ro.
fn ring(x: usize, y: usize, cx: I, cy: I, ri: I, ro: I) bool {
    return disc(x, y, cx, cy, ro) and !disc(x, y, cx, cy, ri);
}

fn box(x: usize, y: usize, x0: I, y0: I, x1: I, y1: I) bool {
    const xi: I = @intCast(x);
    const yi: I = @intCast(y);
    return xi >= x0 and xi <= x1 and yi >= y0 and yi <= y1;
}

// ---------------------------------------------------------------------------
// Faces: one disc + carved eyes + a per-style mouth.
// ---------------------------------------------------------------------------

pub const FaceKind = enum { smile, grin, sad, angry, cool, wink };

fn face_rows(comptime kind: FaceKind) [16]u16 {
    @setEvalBranchQuota(20000);
    var rows: [16]u16 = undefined;
    for (0..16) |y| {
        var r: u16 = 0;
        for (0..16) |x| {
            var on = disc(x, y, 8, 8, 7);
            // Carve eyes (blank 2×2), except wink's right eye stays shut
            // (a bar) and cool wears a full band.
            const left_eye = box(x, y, 4, 5, 5, 6);
            const right_eye = box(x, y, 10, 5, 11, 6);
            switch (kind) {
                .cool => {
                    on = on and !box(x, y, 3, 5, 12, 7);
                    on = on or box(x, y, 3, 5, 12, 5); // brow line
                },
                .wink => on = on and !(left_eye or box(x, y, 9, 6, 12, 6)),
                else => on = on and !(left_eye or right_eye),
            }
            // Mouth zone, rows 10–13.
            const mx: I = @intCast(x);
            const my: I = @intCast(y);
            const smile_arc = (my == 12 and mx >= 5 and mx <= 10) or
                (my == 11 and ((mx >= 4 and mx <= 5) or (mx >= 10 and mx <= 11)));
            switch (kind) {
                .smile => on = on and !smile_arc,
                .grin => on = on and !box(x, y, 5, 10, 10, 12),
                .sad => on = on and !(my == 10 and mx >= 5 and mx <= 10),
                .angry => {
                    on = on and !(my == 11 and mx >= 5 and mx <= 10);
                    on = on and !(my == 4 and ((mx >= 3 and mx <= 6) or (mx >= 9 and mx <= 12)));
                },
                .cool => {},
                .wink => on = on and !smile_arc,
            }
            if (on) r |= @as(u16, 1) << @intCast(x);
        }
        rows[y] = r;
    }
    return rows;
}

// ---------------------------------------------------------------------------
// Gestures & objects: individual constructions.
// ---------------------------------------------------------------------------

/// Thumb up: vertical thumb column over a tilted mitt.
fn thumbs_up_pixel(x: usize, y: usize) bool {
    return box(x, y, 6, 2, 8, 7) or // thumb
        box(x, y, 3, 7, 11, 13) or // mitt
        box(x, y, 4, 6, 10, 6);
}

/// Thumb down: the same art flipped vertically.
fn thumbs_down_pixel(x: usize, y: usize) bool {
    return thumbs_up_pixel(x, 15 - y);
}

/// Clap: two mirrored mitts meeting in the middle.
fn clap_pixel(x: usize, y: usize) bool {
    const left = box(x, y, 2, 5, 6, 12);
    const right = box(x, y, 9, 5, 13, 12);
    const spark = (x == 7 or x == 8) and (y == 4 or y == 7 or y == 10 or y == 13);
    return left or right or spark;
}

/// Wave: a mitt with three motion dashes to its right.
fn wave_pixel(x: usize, y: usize) bool {
    return box(x, y, 3, 3, 8, 13) or
        ((x == 11 or x == 12) and (y == 4 or y == 8)) or
        (x == 10 and y == 12);
}

/// Heart: two discs + a V.
fn heart_pixel(x: usize, y: usize) bool {
    const xi: I = @intCast(x);
    const yi: I = @intCast(y);
    const lobes = disc(x, y, 5, 5, 4) or disc(x, y, 10, 5, 4);
    const vee = yi >= 7 and yi <= 13 and xi >= (yi - 5) and xi <= (20 - yi);
    return lobes or vee;
}

/// Five-pointed star approximated by a diamond + cross arms.
fn star_pixel(x: usize, y: usize) bool {
    const xi: I = @intCast(x);
    const yi: I = @intCast(y);
    const ax: I = @intCast(@abs(@as(i64, xi) - 8));
    const ay: I = @intCast(@abs(@as(i64, yi) - 8));
    _ = ax;
    _ = ay;
    const vert = xi >= 7 and xi <= 8 and yi >= 1 and yi <= 14;
    const horiz = yi >= 6 and yi <= 8 and xi >= 1 and xi <= 14;
    const diag = (@as(i64, xi) - 8) * (@as(i64, yi) - 8);
    const wings = @abs(diag) <= 10 and yi >= 4 and yi <= 12 and xi >= 3 and xi <= 12;
    return vert or horiz or wings;
}

/// Fire: a flame teardrop — tall triangle with a hollow core tip.
fn fire_pixel(x: usize, y: usize) bool {
    const xi: I = @intCast(x);
    const yi: I = @intCast(y);
    if (yi < 2 or yi > 14) return false;
    const spread: I = @divTrunc((yi - 1) * 6, 12);
    const body = xi >= 8 - spread and xi <= 7 + spread;
    const core = disc(x, y, 8, 11, 2);
    return body and !core;
}

/// Rocket: nose cone + body + fins.
fn rocket_pixel(x: usize, y: usize) bool {
    const xi: I = @intCast(x);
    const yi: I = @intCast(y);
    const cone = yi >= 1 and yi <= 4 and xi >= 8 - (yi) and xi <= 7 + yi;
    const body = box(x, y, 6, 5, 9, 10);
    const finsL = box(x, y, 4, 9, 5, 12);
    const finsR = box(x, y, 10, 9, 11, 12);
    const flame = yi == 13 and xi >= 7 and xi <= 8;
    return cone or body or finsL or finsR or flame;
}

/// Lightbulb: bulb disc + base bars.
fn bulb_pixel(x: usize, y: usize) bool {
    return disc(x, y, 8, 6, 5) or box(x, y, 6, 11, 9, 12) or box(x, y, 6, 13, 9, 13);
}

/// Check mark: thick diagonal + tail.
fn check_pixel(x: usize, y: usize) bool {
    const xi: I = @intCast(x);
    const yi: I = @intCast(y);
    const down = xi >= 3 and xi <= 6 and yi >= 8 and yi <= 12 and (yi - xi) >= 3 and (yi - xi) <= 6;
    const up = xi >= 7 and xi <= 12 and yi >= 4 and yi <= 9 and (xi - yi) >= 1 and (xi - yi) <= 4;
    return down or up;
}

/// Sun: disc + eight rays.
fn sun_pixel(x: usize, y: usize) bool {
    if (disc(x, y, 8, 8, 4)) return true;
    const cardinal = ((x == 7 or x == 8) and (y <= 1 or y >= 14)) or
        ((y == 7 or y == 8) and (x <= 1 or x >= 14));
    const diagonal = blk: {
        const d = @abs(@as(i64, @intCast(x)) - 8);
        const e = @abs(@as(i64, @intCast(y)) - 8);
        break :blk d == e and d >= 5 and d <= 6;
    };
    return cardinal or diagonal;
}

/// Crescent moon: big disc minus an offset disc.
fn moon_pixel(x: usize, y: usize) bool {
    return disc(x, y, 8, 8, 6) and !disc(x, y, 11, 6, 5);
}

/// Cloud: three overlapping discs on a base bar.
fn cloud_pixel(x: usize, y: usize) bool {
    return disc(x, y, 5, 9, 3) or disc(x, y, 8, 7, 4) or disc(x, y, 11, 9, 3) or
        box(x, y, 4, 10, 12, 12);
}

/// Snowflake: cross + diagonals through a center.
fn snowflake_pixel(x: usize, y: usize) bool {
    const vert = x == 7 or x == 8;
    const horiz = y == 7 or y == 8;
    const diag = blk: {
        const d = @as(i64, @intCast(x)) - 8;
        const e = @as(i64, @intCast(y)) - 8;
        break :blk @abs(d) == @abs(e) and @abs(d) <= 6;
    };
    return vert or horiz or diag;
}

/// Pizza slice: triangle pointing down + pepperoni holes.
fn pizza_pixel(x: usize, y: usize) bool {
    const xi: I = @intCast(x);
    const yi: I = @intCast(y);
    if (yi < 2 or yi > 13) return false;
    const crust = yi == 2 and xi >= 3 and xi <= 12;
    const spread: I = @divTrunc((yi - 2) * 5, 11);
    const body = xi >= 8 - spread and xi <= 7 + spread;
    const pep1 = disc(x, y, 6, 5, 1);
    const pep2 = disc(x, y, 10, 7, 1);
    const pep3 = disc(x, y, 8, 10, 1);
    return (crust or body) and !pep1 and !pep2 and !pep3;
}

/// Coffee: cup + handle + steam.
fn coffee_pixel(x: usize, y: usize) bool {
    const cup = box(x, y, 3, 6, 10, 12);
    const handle = ring(x, y, 11, 9, 1, 3) and !box(x, y, 12, 6, 12, 12);
    const steam = ((x == 5 or x == 8) and (y == 2 or y == 4));
    return cup or handle or steam;
}

/// Music note: head + stem + flag.
fn note_pixel(x: usize, y: usize) bool {
    return disc(x, y, 6, 12, 3) or box(x, y, 8, 3, 9, 11) or
        (box(x, y, 9, 3, 13, 5) and !(y == 4 and x == 12));
}

/// Warning: triangle outline + bang stem/dot.
fn warning_pixel(x: usize, y: usize) bool {
    const xi: I = @intCast(x);
    const yi: I = @intCast(y);
    if (yi < 2 or yi > 13) return false;
    const spread: I = @divTrunc((yi - 1) * 7, 12);
    const edge = yi == 2 or xi == 8 - spread or xi == 7 + spread;
    const bang = (xi == 7 or xi == 8) and yi >= 5 and yi <= 9;
    const dot = (xi == 7 or xi == 8) and yi == 11;
    return edge or bang or dot;
}

/// Build the curated table. Index-stable: append only, never reorder.
pub const emojis: []const Emoji = &[_]Emoji{
    .{ .cp = 0x1F600, .rows = face_rows(.smile) }, // 😀 smiling
    .{ .cp = 0x1F606, .rows = face_rows(.grin) }, // 😆 grinning
    .{ .cp = 0x1F641, .rows = face_rows(.sad) }, // 🙁 frowning
    .{ .cp = 0x1F621, .rows = face_rows(.angry) }, // 😡 angry
    .{ .cp = 0x1F60E, .rows = face_rows(.cool) }, // 😎 sunglasses
    .{ .cp = 0x1F609, .rows = face_rows(.wink) }, // 😉 wink
    .{ .cp = 0x1F44D, .rows = build(thumbs_up_pixel) }, // 👍
    .{ .cp = 0x1F44E, .rows = build(thumbs_down_pixel) }, // 👎
    .{ .cp = 0x1F44F, .rows = build(clap_pixel) }, // 👏
    .{ .cp = 0x1F44B, .rows = build(wave_pixel) }, // 👋
    .{ .cp = 0x2764, .rows = build(heart_pixel) }, // ❤
    .{ .cp = 0x2B50, .rows = build(star_pixel) }, // ⭐
    .{ .cp = 0x1F525, .rows = build(fire_pixel) }, // 🔥
    .{ .cp = 0x1F680, .rows = build(rocket_pixel) }, // 🚀
    .{ .cp = 0x1F4A1, .rows = build(bulb_pixel) }, // 💡
    .{ .cp = 0x2714, .rows = build(check_pixel) }, // ✔
    .{ .cp = 0x2600, .rows = build(sun_pixel) }, // ☀
    .{ .cp = 0x1F319, .rows = build(moon_pixel) }, // 🌙
    .{ .cp = 0x2601, .rows = build(cloud_pixel) }, // ☁
    .{ .cp = 0x2744, .rows = build(snowflake_pixel) }, // ❄
    .{ .cp = 0x1F355, .rows = build(pizza_pixel) }, // 🍕
    .{ .cp = 0x2615, .rows = build(coffee_pixel) }, // ☕
    .{ .cp = 0x1F3B5, .rows = build(note_pixel) }, // 🎵
    .{ .cp = 0x26A0, .rows = build(warning_pixel) }, // ⚠
};

fn build(comptime paint: fn (x: usize, y: usize) bool) [16]u16 {
    comptime var rows: [16]u16 = undefined;
    @setEvalBranchQuota(100000);
    for (0..16) |y| {
        var r: u16 = 0;
        for (0..16) |x| {
            if (paint(x, y)) r |= @as(u16, 1) << @intCast(x);
        }
        rows[y] = r;
    }
    return rows;
}

/// Look up the index of an emoji codepoint (binary search would work;
/// linear over ≤4K entries is fine at this table size and cache-friendly).
pub fn lookup(cp: u21) ?usize {
    for (emojis, 0..) |e_, i| {
        if (e_.cp == cp) return i;
    }
    return null;
}

test "font_emoji: every entry has ink and unique codepoints" {
    var seen: [emojis.len]u21 = undefined;
    for (emojis, 0..) |e_, i| {
        seen[i] = e_.cp;
        var any = false;
        for (e_.rows) |r| {
            if (r != 0) any = true;
        }
        try std.testing.expect(any);
    }
    for (seen, 0..) |a, i| {
        for (seen[i + 1 ..]) |b| {
            try std.testing.expect(a != b);
        }
    }
}

test "font_emoji: lookup finds knowns and rejects unknowns" {
    try std.testing.expectEqual(@as(?usize, 0), lookup(0x1F600));
    try std.testing.expect(lookup(0x1F525) != null); // fire
    try std.testing.expect(lookup(0x1F984) == null); // unicorn not shipped
}

test "font_emoji: the smile is carved into the filled face" {
    const smile = emojis[0].rows;
    // The face is a filled disc…
    try std.testing.expect((smile[4] >> 7) & 1 != 0);
    // …with the mouth arc CARVED out of row 11/12 (classic monochrome).
    var carved = false;
    for (5..11) |x| {
        if ((smile[12] >> @intCast(x)) & 1 == 0) carved = true;
    }
    // Row 12 center sits below the disc's widest span but still inside
    // it, so a real carve shows background where neighbors are lit.
    const chin = smile[13];
    try std.testing.expect(chin != 0);
    try std.testing.expect(carved or (chin & 0b00111100) == 0);
}

test "font_emoji: thumbsdown is the vertical flip of thumbsup" {
    const up = lookup(0x1F44D).?;
    const down = lookup(0x1F44E).?;
    for (0..16) |y| {
        try std.testing.expectEqual(emojis[up].rows[15 - y], emojis[down].rows[y]);
    }
}
