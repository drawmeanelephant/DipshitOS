//! M73g (#1633) — VT conformance corpus: pinned sequence → grid goldens.
//!
//! Byte vector in, visible grid out, compared byte-equal. This file is a
//! class-A TEST ROOT (registered in build.zig's kernel test list) — no spec
//! boots it, no parser code lives here.
//!
//! THE CONTRACT for parser cards (written by M73g so every later card knows
//! where its rows go):
//!
//!   - A row pins TODAY'S parser. Behaviour unchanged → rows must be
//!     untouched (a regression turns the corpus red in host-seconds).
//!   - A card that deliberately changes behaviour changes its rows in the
//!     SAME PR. Existing hooks:
//!       * the SGR row "unknown/extended SGR params are ignored" is what
//!         M73h (256-colour/truecolour) rewrites when `38;5`/`38;2` gain
//!         meaning, and it appends underline/italic/reverse rows beside it;
//!       * M73i (mouse modes) appends mode rows to the modes group next to
//!         the pinned `?2004h` private-mode row;
//!       * UTF-8 decode rows (M73a-1's policy) live in the decode group —
//!         that card landed before this corpus existed, so its behaviour is
//!         pinned here now.
//!   - A row that DISAGREES with the code is wrong — or you found a bug.
//!     The bug goes in a comment or an issue, never a silent "fix" inside
//!     an unrelated parser card (M73g's non-goal; see the ESC group for a
//!     pinned divergence).
//!
//! Placement: its own file so terminal.zig (~2,600 lines) gains no test
//! bulk; ADR 0020 D1's `Screen` is pure (fixed arrays, no allocation), so
//! the corpus drives it from outside through the pub feed/grid surface
//! (`feed`, `line`, `cellAt`, `styleAt`, `cursorLine`/`cursorCol`).

const std = @import("std");
const t = @import("terminal.zig");

/// A pinned rendition expectation: every field is always checked
/// (`fg`/`bg` null = the presentation default, `bold` the bit 10 state).
const Rendition = struct {
    fg: ?u8 = null,
    bg: ?u8 = null,
    bold: bool = false,
};

/// A style spot-check at a cell; `default_exact` additionally asserts the
/// cell style is byte-identical to `default_cell_style`.
const StyleSpot = struct {
    row: usize,
    col: usize,
    fg: ?u8 = null,
    bg: ?u8 = null,
    bold: bool = false,
    default_exact: bool = false,
};

/// A rune-cell spot-check (presentation truth — `line()` projects
/// non-ASCII runes to 0x00, so rune expectations live here).
const CellSpot = struct {
    row: usize,
    col: usize,
    base: u21,
    mark: u21 = 0,
    cont: u1 = 0,
};

const Case = struct {
    name: []const u8,
    input: []const u8,
    /// Expected ASCII projection of lines 0..lines.len (`Screen.line`).
    lines: []const []const u8 = &.{},
    /// Exact cursor position {row, col} after the feed.
    cursor: ?[2]usize = null,
    /// Expected `lineCount()` (lines in use).
    used: ?usize = null,
    /// Expected DECTCEM visibility.
    visible: ?bool = null,
    /// Expected alternate-screen-active flag.
    alt: ?bool = null,
    /// Expected current SGR rendition.
    rendition: ?Rendition = null,
    cells: []const CellSpot = &.{},
    styles: []const StyleSpot = &.{},
};

fn run(c: Case) !void {
    var s: t.Screen = .{};
    s.feed(c.input);
    for (c.lines, 0..) |want, i| try std.testing.expectEqualStrings(want, s.line(i));
    if (c.used) |u| try std.testing.expectEqual(u, s.lineCount());
    if (c.cursor) |rc| {
        try std.testing.expectEqual(rc[0], s.cursorLine());
        try std.testing.expectEqual(rc[1], s.cursorCol());
    }
    if (c.visible) |v| try std.testing.expectEqual(v, s.cursor_visible);
    if (c.alt) |a| try std.testing.expectEqual(a, s.alt_active);
    if (c.rendition) |r| {
        try std.testing.expectEqual(r.fg, t.styleForeground(s.style));
        try std.testing.expectEqual(r.bg, t.styleBackground(s.style));
        try std.testing.expectEqual(r.bold, t.styleBold(s.style));
    }
    for (c.cells) |x| {
        const cell = s.cellAt(x.row, x.col);
        try std.testing.expectEqual(x.base, cell.base);
        try std.testing.expectEqual(x.mark, cell.mark);
        try std.testing.expectEqual(x.cont, cell.cont);
    }
    for (c.styles) |x| {
        const st = s.styleAt(x.row, x.col);
        try std.testing.expectEqual(x.fg, t.styleForeground(st));
        try std.testing.expectEqual(x.bg, t.styleBackground(st));
        try std.testing.expectEqual(x.bold, t.styleBold(st));
        if (x.default_exact) try std.testing.expectEqual(t.default_cell_style, st);
    }
}

/// Run a group, naming the failing case (the grid diff itself comes from
/// the expect* location line).
fn runAll(cases: []const Case) !void {
    for (cases) |c| {
        run(c) catch |err| {
            std.debug.print("\ncorpus case failed: {s} (input {any})\n", .{ c.name, c.input });
            return err;
        };
    }
}

// Repeated inputs (comptime) so the tables stay readable.
const a80: [80]u8 = [_]u8{'a'} ** 80;
const a79: [79]u8 = [_]u8{'a'} ** 79;

// ---------------------------------------------------------------------------
// Group A — ASCII control and line discipline.
// ---------------------------------------------------------------------------

const control_cases = [_]Case{
    .{
        .name = "fresh grid is empty, cursor home, cursor visible",
        .input = "",
        .lines = &.{""},
        .cursor = .{ 0, 0 },
        .used = 1,
        .visible = true,
        .rendition = .{},
    },
    .{
        .name = "CR returns to column 0 (no erase)",
        .input = "abc\rX",
        .lines = &.{"Xbc"},
        .cursor = .{ 0, 1 },
    },
    .{
        .name = "LF moves down and resets the column",
        .input = "ab\ncd",
        .lines = &.{ "ab", "cd" },
        .cursor = .{ 1, 2 },
        .used = 2,
    },
    .{
        // 127 LFs walk the cursor to the last row; the 128th scrolls the
        // grid up and drops the oldest row ("TOP") off the top.
        .name = "scroll at the bottom drops the oldest row",
        .input = "TOP" ++ ("\n" ** 128) ++ "Z",
        .lines = &.{""},
        .cursor = .{ 127, 1 },
        .used = 128,
        .cells = &.{.{ .row = 127, .col = 0, .base = 'Z' }},
    },
    .{
        .name = "BS steps back and the next write overwrites",
        .input = "abcd\x08X",
        .lines = &.{"abcX"},
        .cursor = .{ 0, 4 },
    },
    .{
        .name = "BS at column 0 is a no-op",
        .input = "\x08A",
        .lines = &.{"A"},
        .cursor = .{ 0, 1 },
    },
    .{
        .name = "TAB advances to the next 8-column stop (gap = spaces)",
        .input = "ab\tZ",
        .lines = &.{"ab      Z"},
        .cursor = .{ 0, 9 },
    },
    .{
        .name = "TAB at the right margin clamps to the last column",
        .input = &a79 ++ "\tZ",
        .lines = &.{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaZ"},
        .cursor = .{ 0, 80 },
    },
    .{
        .name = "bell, NUL and DEL paint nothing",
        .input = "A\x07B\x00C\x7fD",
        .lines = &.{"ABCD"},
        .cursor = .{ 0, 4 },
    },
};

test "terminal corpus: ASCII control and line discipline" {
    try runAll(&control_cases);
}

// ---------------------------------------------------------------------------
// Group B — wrap at the right margin (80 columns default).
// ---------------------------------------------------------------------------

const wrap_cases = [_]Case{
    .{
        .name = "exactly cols characters leave a PENDING wrap (col == cols)",
        .input = &a80,
        .lines = &.{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        .cursor = .{ 0, 80 },
        .used = 1,
    },
    .{
        .name = "the next printable lands on a fresh row",
        .input = &a80 ++ "XY",
        .lines = &.{ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "XY" },
        .cursor = .{ 1, 2 },
        .used = 2,
    },
    .{
        // 79 columns + a double-width rune: wrapping happens BEFORE the
        // split, so the pair starts row 1 whole.
        .name = "a wide pair never splits across the margin",
        .input = &a79 ++ "\xe4\xbd\xa0",
        .lines = &.{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        .cursor = .{ 1, 2 },
        .used = 2,
        .cells = &.{
            .{ .row = 1, .col = 0, .base = 0x4F60 },
            .{ .row = 1, .col = 1, .base = ' ', .cont = 1 },
        },
    },
};

test "terminal corpus: wrap at the right margin" {
    try runAll(&wrap_cases);
}

// ---------------------------------------------------------------------------
// Group C — CSI cursor positioning and erase (H/f/J/K).
// ---------------------------------------------------------------------------

const csi_cases = [_]Case{
    .{
        .name = "CUP with both params moves 1-based and grows `used`",
        .input = "\x1b[10;20H",
        .cursor = .{ 9, 19 },
        .used = 10,
    },
    .{
        .name = "CUP with no params homes the cursor",
        .input = "\x1b[H",
        .cursor = .{ 0, 0 },
        .used = 1,
    },
    .{
        .name = "HVP (f) behaves exactly like CUP (H)",
        .input = "\x1b[4;6f",
        .cursor = .{ 3, 5 },
        .used = 4,
    },
    .{
        .name = "out-of-range CUP clamps to the grid (127, 79)",
        .input = "\x1b[999;999H",
        .cursor = .{ 127, 79 },
        .used = 128,
    },
    .{
        // A zero (or missing) param falls back to 1 — rows/cols are 1-based.
        .name = "zero and missing CUP params default to 1",
        .input = "\x1b[;10H",
        .cursor = .{ 0, 9 },
        .used = 1,
    },
    .{
        .name = "ED 2 clears the grid, homes the cursor, used = 1",
        .input = "HELLO\x1b[2J",
        .lines = &.{""},
        .cursor = .{ 0, 0 },
        .used = 1,
    },
    .{
        // ED 0: cursor-to-end of the current row, then every row below.
        .name = "ED 0 erases from the cursor down",
        .input = "AB\r\nCD\x1b[1;2H\x1b[J",
        .lines = &.{ "A", "" },
        .cursor = .{ 0, 1 },
        .used = 2,
    },
    .{
        // ED 1: every row above, then start-of-row through the cursor
        // (cursor INCLUSIVE). Row 1's lens is untouched by design — the
        // line() length stays 2 and the cleared cells project as spaces.
        .name = "ED 1 erases from the top through the cursor",
        .input = "AB\r\nCD\x1b[2;2H\x1b[1J",
        .lines = &.{ "", "  " },
        .cursor = .{ 1, 1 },
        .used = 2,
    },
    .{
        .name = "EL 0 erases from the cursor to the right margin",
        .input = "ABCDEFG\x1b[1;4H\x1b[K",
        .lines = &.{"ABC"},
        .cursor = .{ 0, 3 },
    },
    .{
        .name = "EL 1 erases start-of-row through the cursor",
        .input = "ABCD\x1b[1;3H\x1b[1K",
        .lines = &.{"   D"},
        .cursor = .{ 0, 2 },
    },
    .{
        .name = "EL 2 erases the whole row (length drops to 0)",
        .input = "ABC\x1b[2K",
        .lines = &.{""},
        .cursor = .{ 0, 3 },
    },
};

test "terminal corpus: CSI cursor positioning and erase" {
    try runAll(&csi_cases);
}

// ---------------------------------------------------------------------------
// Group D — SGR renditions. The M72b 16-colour contract is frozen: any row
// here changing means the freeze broke.
// ---------------------------------------------------------------------------

const sgr_cases = [_]Case{
    .{
        .name = "SGR fg/bg set, SGR 0 resets the whole rendition",
        .input = "\x1b[31;42mA\x1b[0mB",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .styles = &.{
            .{ .row = 0, .col = 0, .fg = 1, .bg = 2 },
            .{ .row = 0, .col = 1 },
        },
        .rendition = .{},
    },
    .{
        .name = "SGR 1 sets bold, SGR 22 clears it",
        .input = "\x1b[1mA\x1b[22mB",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .styles = &.{
            .{ .row = 0, .col = 0, .bold = true },
            .{ .row = 0, .col = 1 },
        },
        .rendition = .{},
    },
    .{
        .name = "bright fg 90-97 / bright bg 100-107 map to indices 8-15",
        .input = "\x1b[91;104mX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
        .styles = &.{.{ .row = 0, .col = 0, .fg = 9, .bg = 12 }},
    },
    .{
        .name = "SGR 39/49 restore the default colours",
        .input = "\x1b[32;43mA\x1b[39;49mB",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .styles = &.{
            .{ .row = 0, .col = 0, .fg = 2, .bg = 3 },
            .{ .row = 0, .col = 1 },
        },
    },
    .{
        // Deliverable pin: "SGR reset -> default_cell_style", byte-exact.
        .name = "SGR reset yields default_cell_style exactly",
        .input = "\x1b[1;34;45mA\x1b[mB",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .styles = &.{
            .{ .row = 0, .col = 0, .fg = 4, .bg = 5, .bold = true },
            .{ .row = 0, .col = 1, .default_exact = true },
        },
        .rendition = .{},
    },
    .{
        // TODAY'S parser: params without an arm (4=underline, 5/6 flicker,
        // 7=reverse, 38/48 colour selectors, 99) are consumed and leave the
        // rendition alone. M73h REWRITES this row when 38;5/38;2 gain
        // meaning and appends underline/italic/reverse rows beside it.
        .name = "unknown and extended SGR params are ignored (M73h hook)",
        .input = "\x1b[4;38;5;99mA",
        .lines = &.{"A"},
        .cursor = .{ 0, 1 },
        .styles = &.{.{ .row = 0, .col = 0, .default_exact = true }},
        .rendition = .{},
    },
};

test "terminal corpus: SGR renditions (16-colour frozen)" {
    try runAll(&sgr_cases);
}

// ---------------------------------------------------------------------------
// Group E — modes: the alternate screen (DECSET 47/1049) and DECTCEM (?25).
// Private modes without an arm are consumed, never painted.
// ---------------------------------------------------------------------------

const mode_cases = [_]Case{
    .{
        // Enter clears the swapped-in grid; exit swaps the primary back
        // UNCHANGED, cursor position included — "MORE" continues after
        // "MAIN", proving col 4 was preserved across the round trip.
        .name = "alternate round trip preserves the primary grid and cursor",
        .input = "MAIN\x1b[?1049hALT\x1b[?1049lMORE",
        .lines = &.{"MAINMORE"},
        .cursor = .{ 0, 8 },
        .used = 1,
        .alt = false,
    },
    .{
        // DECRST swapped the primary back into storage; the next DECSET
        // swaps again and CLEARS the active grid (the field doc's
        // contract): stale alternate content does not survive an exit.
        // The primary "MAIN" now sits in the inactive storage, invisible
        // until the next exit.
        .name = "re-entering starts a fresh cleared alternate grid",
        .input = "MAIN\x1b[?1049hALT\x1b[?1049l\x1b[?1049h",
        .lines = &.{""},
        .cursor = .{ 0, 0 },
        .used = 1,
        .alt = true,
    },
    .{
        // alt_active == enabled is a no-op: a second ?1049h must NOT
        // re-clear the active alternate grid.
        .name = "a second enter of the same mode does not re-clear",
        .input = "\x1b[?1049hB\x1b[?1049hC",
        .lines = &.{"BC"},
        .cursor = .{ 0, 2 },
        .alt = true,
    },
    .{
        .name = "DECSET 47 aliases 1049 and exits mix freely",
        .input = "\x1b[?47hX\x1b[?1049lY",
        .lines = &.{"Y"},
        .cursor = .{ 0, 1 },
        .alt = false,
    },
    .{
        .name = "DECTCEM hide (?25l) drops the painted cursor",
        .input = "\x1b[?25l",
        .cursor = .{ 0, 0 },
        .visible = false,
    },
    .{
        .name = "DECTCEM show (?25h) restores it",
        .input = "\x1b[?25lA\x1b[?25h",
        .lines = &.{"A"},
        .visible = true,
    },
    .{
        // cursor_visible is a terminal-mode bit: it is NOT part of the
        // alternate-screen swap, so hiding before the trip stays hidden.
        .name = "cursor visibility survives an alternate round trip",
        .input = "X\x1b[?25l\x1b[?1049h\x1b[?1049l",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
        .visible = false,
        .alt = false,
    },
    .{
        // A private mode with no arm is consumed and paints nothing.
        // ?2004 (bracketed paste) has terminal-object state since M73e but
        // is grid-invisible here; M73i appends its mouse-mode rows beside
        // this one.
        .name = "unknown private mode is consumed, state untouched (M73i hook)",
        .input = "\x1b[?2004hA",
        .lines = &.{"A"},
        .cursor = .{ 0, 1 },
        .visible = true,
        .alt = false,
        .rendition = .{},
    },
};

test "terminal corpus: modes — alternate screen and DECTCEM" {
    try runAll(&mode_cases);
}

// ---------------------------------------------------------------------------
// Group F — ESC and CSI policy pins.
// ---------------------------------------------------------------------------

const esc_cases = [_]Case{
    .{
        .name = "ESC followed by a non-[ byte consumes exactly that byte",
        .input = "\x1bXabc",
        .lines = &.{"abc"},
        .cursor = .{ 0, 3 },
    },
    .{
        // OBSERVED divergence pinned on purpose: only '[' enters CSI, so
        // an xterm-style charset designator (ESC ( B) has its '(' consumed
        // and its final byte PAINTED as text. xterm consumes the whole
        // sequence. A fix must flip this row deliberately — M73g's
        // non-goal is silently changing it.
        .name = "ESC ( B paints its final byte (xterm divergence, pinned)",
        .input = "\x1b(B",
        .lines = &.{"B"},
        .cursor = .{ 0, 1 },
    },
    .{
        .name = "an unknown CSI final is consumed, never printed",
        .input = "\x1b[3ZX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
    },
    .{
        .name = "CSI intermediates (0x20-0x3F) are skipped, then the final decides",
        .input = "\x1b[!pX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
    },
};

test "terminal corpus: ESC and CSI policy pins" {
    try runAll(&esc_cases);
}

// ---------------------------------------------------------------------------
// Group G — UTF-8 decode (M73a-1 #1625 policy). `line()` projects every
// non-ASCII rune to one 0x00 byte, so rune expectations use cell spots.
// ---------------------------------------------------------------------------

const utf8_cases = [_]Case{
    .{
        .name = "2-byte rune decodes; ASCII projection shows 0x00",
        .input = "\xc3\xa9",
        .lines = &.{"\x00"},
        .cursor = .{ 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0, .base = 0xE9 }},
    },
    .{
        .name = "3-byte rune is double-width: base + continuation cell",
        .input = "\xe4\xbd\xa0",
        .lines = &.{"\x00\x00"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0x4F60 },
            .{ .row = 0, .col = 1, .base = ' ', .cont = 1 },
        },
    },
    .{
        .name = "4-byte (astral) rune decodes and occupies a wide pair",
        .input = "\xf0\x9f\x98\x80",
        .lines = &.{"\x00\x00"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0x1F600 },
            .{ .row = 0, .col = 1, .base = ' ', .cont = 1 },
        },
    },
    .{
        .name = "a stray continuation byte is one U+FFFD, then text resumes",
        .input = "\x80A",
        .lines = &.{"\x00A"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0xFFFD },
            .{ .row = 0, .col = 1, .base = 'A' },
        },
    },
    .{
        .name = "an invalid lead (F5-FF) is one U+FFFD",
        .input = "\xf5A",
        .lines = &.{"\x00A"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0xFFFD },
            .{ .row = 0, .col = 1, .base = 'A' },
        },
    },
    .{
        // Truncated tail: one U+FFFD for the half-sequence, then the
        // offending byte is processed fresh (a printable stays printable).
        .name = "a truncated tail is one U+FFFD, the next byte reprocesses",
        .input = "\xc3A",
        .lines = &.{"\x00A"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0xFFFD },
            .{ .row = 0, .col = 1, .base = 'A' },
        },
    },
    .{
        .name = "an overlong 3-byte sequence is one U+FFFD for the sequence",
        .input = "\xe0\x80\xaf",
        .lines = &.{"\x00"},
        .cursor = .{ 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0, .base = 0xFFFD }},
    },
    .{
        .name = "a surrogate code point is one U+FFFD for the sequence",
        .input = "\xed\xa0\x80",
        .lines = &.{"\x00"},
        .cursor = .{ 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0, .base = 0xFFFD }},
    },
    .{
        // C0/C1 bytes (C0..C1) fail the LEAD check, so each byte is its
        // own U+FFFD — different from valid leads, which fail at the end
        // of the sequence and produce ONE replacement (rows above).
        .name = "C0 lead bytes each become one U+FFFD (lead-level rule)",
        .input = "\xc0\xaf",
        .lines = &.{"\x00\x00"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0xFFFD },
            .{ .row = 0, .col = 1, .base = 0xFFFD },
        },
    },
    .{
        .name = "a combining rune overlays the base behind the cursor",
        .input = "e\xcc\x81",
        .lines = &.{"e"},
        .cursor = .{ 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0, .base = 'e', .mark = 0x301 }},
    },
    .{
        .name = "an orphan combining rune (no base) pins to U+FFFD",
        .input = "\xcc\x81",
        .lines = &.{"\x00"},
        .cursor = .{ 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0, .base = 0xFFFD }},
    },
    .{
        .name = "an ignorable zero-width rune is dropped cursor-neutral",
        .input = "\xe2\x80\x8dU", // ZWJ + U
        .lines = &.{"U"},
        .cursor = .{ 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0, .base = 'U' }},
    },
    .{
        // Overwriting one half of a wide pair repairs the orphan first:
        // the base becomes an erased (space) cell instead of a torn pair.
        .name = "overwriting a continuation cell repairs its base",
        .input = "\xe4\xbd\xa0\x1b[1;2Hx",
        .lines = &.{" x"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = ' ' },
            .{ .row = 0, .col = 1, .base = 'x' },
        },
    },
};

test "terminal corpus: UTF-8 decode (M73a-1 policy)" {
    try runAll(&utf8_cases);
}
