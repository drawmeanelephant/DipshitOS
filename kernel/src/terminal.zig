//! VirelaiOS terminal (vt) seam (ADR 0020, issue #1072).
//!
//! A **terminal** is a bounded, hardware-free session buffer: an output ring
//! the owner process writes to, an input queue a front-end fills, and an
//! exclusive attach state naming the front-end (the raw serial console, a
//! TABWM window, a TCP/SSH session). It is the thing `GOSH.ELF`, `TERM.BIN`,
//! and remote sessions all sit on — see ADR 0020.
//!
//! Pure by construction: fixed arrays, no allocation, no hardware, no
//! syscalls. The device/front-end wiring lives outside this module (the
//! `/dev/tty` routing in `file_table.zig` is the next tranche).
//!
//! Overflow policy is explicit and counted:
//!   * output full -> drop the OLDEST byte (`out_dropped`), so output flows
//!     (serial/net). The window path never hits this: `writeWindow` streams
//!     write→grid in ring-sized chunks (#1630, M73f-1), so a TUI frame
//!     larger than the ring cannot drop;
//!   * input full  -> drop the NEWEST byte (`in_dropped`), so a key burst
//!     never evicts keys the owner has not read yet.

const std = @import("std");
const console = @import("console.zig");
const klog = @import("klog.zig");
// M49 SD5 (#1132): copy a terminal selection into the shared clipboard.
const clipboard = @import("clipboard.zig");
// SH7 (#1083, ADR 0020 Amendment B): the net front-end pumps bytes between
// a terminal and the kernel's single bounded TCP connection.
const tcp = @import("tcp.zig");
const virtio_net = @import("virtio_net.zig");
// M50 TS4 (#1138, ADR 0024 D6): the pump mints a fresh challenge from the
// kernel CSPRNG on every accept (ADR 0023 D7 keeps randomness kernel-side).
const csprng = @import("csprng.zig");
// M46 RC3 (#1111, ADR 0022): the net pump stamps the TCP RTO clock from the
// 1 Hz generic timer so the half-open accept timeout (#1105) advances while a
// net-bound shell waits for its first client.
const timer = @import("timer.zig");
// M73a-1 (#1625, ADR 0020 Amendment D): the grid stores decoded rune
// cells, so width/combining policy comes from the same `text` helpers the
// painter uses.
const text = @import("text.zig");

/// Output ring capacity (bytes the owner has written, awaiting a front-end).
pub const out_capacity: usize = 4096;
/// Input queue capacity (bytes a front-end has pushed, awaiting the owner).
pub const in_capacity: usize = 1024;
/// How many concurrent terminals the kernel tracks.
pub const max_terminals: usize = 4;

/// M50 TS4 (#1138, ADR 0024 D6): the delegated net-auth protocol.
/// `net_challenge_len` is the fresh 32-byte server challenge minted from the
/// kernel CSPRNG on every accept; `net_auth_line_max` bounds the client's
/// one-line reply (64 hex chars for HMAC-SHA256, 128 for Ed25519 — 160 is
/// the ADR's fixed bound, reassembly-free). `net_auth_deadline` is the 1 Hz
/// seam clock's 10 s bound: no verdict by then is a failed connection,
/// never a bypass.
pub const net_challenge_len: usize = 32;
pub const net_auth_line_max: usize = 160;
pub const net_auth_deadline: u64 = 10;
/// The framing tag: `VIRELAIOS-AUTH/1 <scheme> <hex-challenge>\n`.
pub const net_auth_tag: []const u8 = "VIRELAIOS-AUTH/1";

/// M50 TS4: the scheme the pump frames and the verifier (the attached
/// process) must answer. `.open` is M46's accept-immediately posture,
/// reached only through the explicit insecure CLI mode (ADR 0024 D6).
pub const NetAuthScheme = enum(u8) {
    open = 0,
    hmac_sha256 = 1,
    ed25519 = 2,

    pub fn name(self: NetAuthScheme) []const u8 {
        return switch (self) {
            .open => "open",
            .hmac_sha256 => "hmac-sha256",
            .ed25519 => "ed25519",
        };
    }

    /// The expected hex reply length for the scheme (0 for `.open`).
    pub fn expectedReplyLen(self: NetAuthScheme) usize {
        return switch (self) {
            .open => 0,
            .hmac_sha256 => 64,
            .ed25519 => 128,
        };
    }
};

/// #1082 (ADR 0020 Amendment A): the window front-end's presentation grid.
/// The terminal OBJECT stays a pure byte session (D1); this bounded
/// character grid + scrollback is presentation state rendered by the kernel
/// into the bound `.user` window (A4). 8x8 cells, the kernel glyph raster.
pub const grid_cols: usize = 80;
pub const grid_lines: usize = 128;

/// A bounded character grid with scrollback for one window-bound terminal.
/// Bytes fed from the output ring are laid out (CR/LF/BS/TAB, a minimal CSI
/// clear/home), wrapping at `cols` and scrolling one line at a time. Bytes
/// >= 0x80 are UTF-8-decoded into **rune cells** (M73a-1 #1625): wide
/// pairs, combining overlays, U+FFFD for ill-formed input. A window resize
/// reflows the stored lines to the new column count (M49 SD5 #1132) —
/// placement-aware, so a pair never splits. Pure: fixed arrays, no
/// allocation, host-testable.
pub const Point = struct { line: usize, col: usize };

/// M73a-1 (#1625, ADR 0020 Amendment D): one grid cell as presentation
/// state. `base` is the rune anchored here (U+0000..U+10FFFF), `mark` an
/// optional combining overlay on that rune (0 = none), and `cont` marks the
/// right half of a double-width pair — its `base` is always 0 and the glyph
/// lives in the cell to the left. Packed (43 bits) so the 80x128 grids and
/// the reflow snapshot stay contiguous.
pub const Cell = packed struct {
    base: u21 = ' ',
    mark: u21 = 0,
    cont: u1 = 0,
};

/// The erased/initial cell: a blank, unmarked, glyph-owning cell.
pub const empty_cell: Cell = .{};

fn utf8Len(cp: u21) usize {
    if (cp < 0x80) return 1;
    if (cp < 0x800) return 2;
    if (cp < 0x10000) return 3;
    return 4;
}

/// Encode one rune at `dst[out..]`; null when the whole rune does not fit
/// (selection copy never writes a truncated UTF-8 sequence).
fn encodeOne(dst: []u8, out: usize, cp: u21) ?usize {
    const n = utf8Len(cp);
    if (out + n > dst.len) return null;
    if (n == 1) {
        dst[out] = @intCast(cp);
        return out + 1;
    } else if (n == 2) {
        dst[out] = 0xc0 | @as(u8, @intCast(cp >> 6));
        dst[out + 1] = 0x80 | @as(u8, @intCast(cp & 0x3f));
        return out + 2;
    } else if (n == 3) {
        dst[out] = 0xe0 | @as(u8, @intCast(cp >> 12));
        dst[out + 1] = 0x80 | @as(u8, @intCast((cp >> 6) & 0x3f));
        dst[out + 2] = 0x80 | @as(u8, @intCast(cp & 0x3f));
        return out + 3;
    }
    dst[out] = 0xf0 | @as(u8, @intCast(cp >> 18));
    dst[out + 1] = 0x80 | @as(u8, @intCast((cp >> 12) & 0x3f));
    dst[out + 2] = 0x80 | @as(u8, @intCast((cp >> 6) & 0x3f));
    dst[out + 3] = 0x80 | @as(u8, @intCast(cp & 0x3f));
    return out + 4;
}

/// Encode a cell's base then its overlay as UTF-8, all-or-nothing.
fn encodeCell(dst: []u8, out: usize, cell: Cell) ?usize {
    const total = utf8Len(cell.base) + (if (cell.mark != 0) utf8Len(cell.mark) else 0);
    if (out + total > dst.len) return null;
    var i = encodeOne(dst, out, cell.base).?;
    if (cell.mark != 0) i = encodeOne(dst, i, cell.mark).?;
    return i;
}

/// A terminal cell's rendition — foreground/background colour slot plus
/// attributes (M73h #1634, ADR 0020 Amendment E). This SUPERSEDES the
/// M72b/Amendment-C 16-colour freeze: a compact u16 could not hold the
/// selectors Charm apps actually emit (`38;5;n`, `38;2;r;g;b`, underline,
/// italic, reverse, dim).
///
/// `fg`/`bg` are 9-bit colour slots:
///   0..=255  an xterm 256-colour index (`38;5;n`/`48;5;n`; 0..=15 also
///            covers classic SGR 30-37/40-47/90-97/100-107);
///   256      the presentation default — resolved at PAINT time from the
///            desktop theme (#207 `theme_id`), never a stored RGB;
///   257      truecolour: this cell's RGB rides in the side arrays
///            (`fg_rgb`/`bg_rgb`) — one u32 cannot carry two 24-bit
///            channels, so RGB swaps and reflows beside the style word
///            (presentation state; ADR 0020 D1 holds, no new syscall).
///
/// `flags`: bold (SGR 1/22), dim (2/22), italic (3/23), underline (4/24),
/// reverse (7/27 — resolved at paint by swapping the channels). Nine pad
/// bits are unused: blink/overline/strike are M73h non-goals (storage
/// would be free, paint is not).
///
/// Old sequences stay pixel-identical: SGR 30-37/40-47/90-97 still store
/// 0..=15 and the paint side keeps `ansi_palette` for exactly those.
pub const CellStyle = packed struct(u32) {
    fg: colour_slot = default_colour,
    bg: colour_slot = default_colour,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    _pad: u9 = 0,
};

/// One colour slot in a `CellStyle`.
pub const colour_slot = u9;
/// The presentation-default slot (paint resolves it from the theme).
/// Was 16 in the frozen u16 layout; u9 widens the space so index 16 is a
/// real xterm colour (`38;5;16`) instead of the sentinel.
pub const default_colour: colour_slot = 256;
/// The truecolour marker: the cell's RGB rides in the side arrays.
pub const rgb_colour: colour_slot = 257;
/// A 24-bit colour as stored beside a truecolour cell (3 packed bytes).
pub const Rgb = struct { r: u8 = 0, g: u8 = 0, b: u8 = 0 };

/// The erased/initial RGB side value (matches `empty_cell`).
pub const empty_rgb: Rgb = .{};

pub const default_cell_style: CellStyle = .{};

/// The palette index of a cell's foreground, or null for default AND for
/// truecolour cells (callers wanting RGB use `Screen.rgbAt`).
pub fn styleForeground(style: CellStyle) ?u8 {
    if (style.fg == default_colour or style.fg == rgb_colour) return null;
    return @intCast(style.fg);
}

/// The palette index of a cell's background, or null for default AND for
/// truecolour cells (callers wanting RGB use `Screen.rgbAt`).
pub fn styleBackground(style: CellStyle) ?u8 {
    if (style.bg == default_colour or style.bg == rgb_colour) return null;
    return @intCast(style.bg);
}

pub fn styleBold(style: CellStyle) bool {
    return style.bold;
}

pub fn styleDim(style: CellStyle) bool {
    return style.dim;
}

pub fn styleItalic(style: CellStyle) bool {
    return style.italic;
}

pub fn styleUnderline(style: CellStyle) bool {
    return style.underline;
}

pub fn styleReverse(style: CellStyle) bool {
    return style.reverse;
}

/// M73h (#1634): the canonical xterm 256-colour table, total (no traps).
/// 0..=15 are the canonical xterm ANSI colours — the PAINT side keeps its
/// own `ansi_palette` for those (pixel parity for old sequences) and only
/// calls this for 16..=255; 16..=231 is the 6×6×6 cube (levels 0, 95,
/// 135, 175, 215, 255), 232..=255 the 24-step grayscale ramp
/// (8 + 10·i). Spot-checked class-A.
pub fn xterm256Rgb(index: u8) Rgb {
    const ansi = [_]Rgb{
        .{ .r = 0x00, .g = 0x00, .b = 0x00 }, .{ .r = 0xcd, .g = 0x00, .b = 0x00 },
        .{ .r = 0x00, .g = 0xcd, .b = 0x00 }, .{ .r = 0xcd, .g = 0xcd, .b = 0x00 },
        .{ .r = 0x00, .g = 0x00, .b = 0xee }, .{ .r = 0xcd, .g = 0x00, .b = 0xcd },
        .{ .r = 0x00, .g = 0xcd, .b = 0xcd }, .{ .r = 0xe5, .g = 0xe5, .b = 0xe5 },
        .{ .r = 0x7f, .g = 0x7f, .b = 0x7f }, .{ .r = 0xff, .g = 0x00, .b = 0x00 },
        .{ .r = 0x00, .g = 0xff, .b = 0x00 }, .{ .r = 0xff, .g = 0xff, .b = 0x00 },
        .{ .r = 0x5c, .g = 0x5c, .b = 0xff }, .{ .r = 0xff, .g = 0x00, .b = 0xff },
        .{ .r = 0x00, .g = 0xff, .b = 0xff }, .{ .r = 0xff, .g = 0xff, .b = 0xff },
    };
    if (index < 16) return ansi[index];
    if (index >= 232) {
        const level: u8 = 8 + 10 * (index - 232);
        return .{ .r = level, .g = level, .b = level };
    }
    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
    const n = index - 16;
    return .{
        .r = levels[n / 36],
        .g = levels[(n / 6) % 6],
        .b = levels[n % 6],
    };
}

/// M73k (#1637): scrollback depth beyond the live grid. MEASURED against
/// `tools/verify-bss-budget.sh`, not guessed: one history row is
/// cells 80x8 + styles 80x4 + lens = 968 B (M73h widened CellStyle to
/// u32 — that is what pushes the card's 512-line band down), and five
/// banks are needed: one per terminal (`max_terminals`) plus ONE
/// full-size reflow temp — an EXPANDING re-wrap cannot happen in place
/// (it would write ahead of its own reads on a single ring), so reflow
/// snapshots exactly like the grid's own `reflow_lines` path:
///   5 * 256 * 968 = 1,239,040 B  ->  budget PASS (~195 KiB headroom).
/// 256 = 2x the live screen depth per window, 1024 lines across the
/// fleet. Rows carry the M73a-1 `Cell` repr + rendition; the RGB side
/// arrays do NOT ride along (+480 B/row would blow the budget) —
/// truecolour cells are coerced to the presentation default on push
/// (stated honestly in the PR).
pub const history_lines: usize = 256;

/// One screen's history ring contents. Module BSS for the same reason as
/// `reflow_lines`: far too large for a Screen's .data object or a stack.
pub const HistoryBank = struct {
    cells: [history_lines][grid_cols]Cell,
    styles: [history_lines][grid_cols]CellStyle,
    lens: [history_lines]usize,
};

/// Per-terminal history banks, linked to `screens[i]` by pointer identity.
/// A Screen outside the registry (a local test value) has no bank and
/// simply never accumulates history — existing tests stay byte-identical.
var history_bank: [max_terminals]HistoryBank = undefined;
/// The reflow snapshot (deliverable 3): one at a time, paint-path only.
var history_temp: HistoryBank = undefined;

fn histOf(s: *const Screen) ?*HistoryBank {
    for (&screens, 0..) |*sc, i| {
        if (sc == s) return &history_bank[i];
    }
    return null;
}

pub const Screen = struct {
    cells: [grid_lines][grid_cols]Cell = [_][grid_cols]Cell{[_]Cell{empty_cell} ** grid_cols} ** grid_lines,
    styles: [grid_lines][grid_cols]CellStyle = [_][grid_cols]CellStyle{[_]CellStyle{default_cell_style} ** grid_cols} ** grid_lines,
    lens: [grid_lines]usize = [_]usize{0} ** grid_lines,
    /// Number of lines in use (>= 1); grows to `grid_lines` then scrolls.
    used: usize = 1,
    /// The cursor's line (0..used-1) and column.
    cur: usize = 0,
    col: usize = 0,
    /// The alternate screen is a second bounded grid, not an allocation.
    /// Entering DECSET 47/1049 swaps the primary into this storage and clears
    /// the active grid; DECRST swaps it back unchanged.
    alt_cells: [grid_lines][grid_cols]Cell = [_][grid_cols]Cell{[_]Cell{empty_cell} ** grid_cols} ** grid_lines,
    alt_styles: [grid_lines][grid_cols]CellStyle = [_][grid_cols]CellStyle{[_]CellStyle{default_cell_style} ** grid_cols} ** grid_lines,
    alt_lens: [grid_lines]usize = [_]usize{0} ** grid_lines,
    alt_used: usize = 1,
    alt_cur: usize = 0,
    alt_col: usize = 0,
    alt_view: usize = 0,
    alt_style: CellStyle = default_cell_style,
    alt_active: bool = false,
    /// M73h (#1634): truecolour channels per cell, primary and alternate.
    /// Written by `putRune` from the current rendition state and read ONLY
    /// for cells whose slot marks `rgb_colour`; swapped and reflowed with
    /// their style arrays.
    fg_rgb: [grid_lines][grid_cols]Rgb = [_][grid_cols]Rgb{[_]Rgb{empty_rgb} ** grid_cols} ** grid_lines,
    bg_rgb: [grid_lines][grid_cols]Rgb = [_][grid_cols]Rgb{[_]Rgb{empty_rgb} ** grid_cols} ** grid_lines,
    alt_fg_rgb: [grid_lines][grid_cols]Rgb = [_][grid_cols]Rgb{[_]Rgb{empty_rgb} ** grid_cols} ** grid_lines,
    alt_bg_rgb: [grid_lines][grid_cols]Rgb = [_][grid_cols]Rgb{[_]Rgb{empty_rgb} ** grid_cols} ** grid_lines,
    /// The current truecolour state (applies to FUTURE writes), mirrored
    /// across the alternate swap exactly like `style`/`alt_style`.
    fg_rgb_cur: Rgb = empty_rgb,
    bg_rgb_cur: Rgb = empty_rgb,
    alt_fg_rgb_cur: Rgb = empty_rgb,
    alt_bg_rgb_cur: Rgb = empty_rgb,
    /// CSI state: 0 normal, 1 ESC, 2 CSI.
    esc_state: u8 = 0,
    csi_params: [16]u16 = [_]u16{0} ** 16,
    csi_count: usize = 0,
    csi_private: bool = false,
    /// M73a-1 (#1625): the in-flight UTF-8 sequence, if any. `utf_need` is
    /// the continuation bytes still expected (0 = idle), `utf_acc` the
    /// partial codepoint, `utf_len` the total sequence length (for the
    /// overlong/surrogate/range check at completion).
    utf_need: u8 = 0,
    utf_acc: u32 = 0,
    utf_len: u8 = 0,
    /// Current SGR rendition. It is presentation state, never terminal-object
    /// bytes, so serial and network front-ends remain byte-for-byte unchanged.
    style: CellStyle = default_cell_style,
    /// DECTCEM (`CSI ? 25 h/l`) controls only the painted block cursor.
    /// Unlike grid content and rendition, this terminal-mode bit is shared
    /// across primary and alternate screens: changing cursor visibility while
    /// an alternate screen is active remains in effect after it is restored.
    cursor_visible: bool = true,
    /// M73e (#1629): DECSET/DECRST `CSI ? 2004 h/l` — bracketed paste.
    /// A paste pushed while this is set is wrapped in `\e[200~ … \e[201~`
    /// so the receiving editor keeps paste content literal. Like DECTCEM
    /// it is a terminal-mode bit: shared across primary/alternate screens.
    bracketed_paste: bool = false,
    /// M49 SD5 (#1132): the effective column count (8..grid_cols). A window
    /// resize reflows the grid to the new client width.
    cols: usize = grid_cols,
    /// M49 SD5: scrollback view offset — 0 follows the tail, N shows N
    /// lines further back. New output snaps the view back to the tail.
    view: usize = 0,
    /// M49 SD5: the selection endpoints (absolute grid rows), if any.
    sel_anchor: ?Point = null,
    sel_cursor: ?Point = null,
    /// M73k (#1637): history ring position for THIS screen — `hist_count`
    /// surviving rows (0..history_lines), `hist_start` the oldest slot,
    /// `hist_dropped` the total ever evicted. `u + hist_dropped` is a
    /// line's STABLE absolute identity (unified indices shift when the
    /// ring rotates; absolutes do not).
    hist_count: usize = 0,
    hist_start: usize = 0,
    hist_dropped: u64 = 0,
    /// M73k: kernel-side search — presentation state like selection,
    /// never in the byte pipe (D1 holds). Normal screen only. Literal,
    /// row-local, rune-aware, ASCII-case-insensitive (pinned by test).
    search_active: bool = false,
    search_pat: [32]u21 = [_]u21{0} ** 32,
    search_len: usize = 0,
    search_count: usize = 0,
    search_row: usize = 0, // unified row of the current match
    search_col: usize = 0, // start column of the current match
    search_has_cur: bool = false,
    /// The user's selection, saved while search owns `sel_*` for the
    /// current-match highlight; restored on exit.
    saved_sel_anchor: ?Point = null,
    saved_sel_cursor: ?Point = null,
    /// The row under the prompt bar, saved/restored through ABSOLUTE
    /// identity (survives ring rotation and grid scroll; an evicted row
    /// has nothing left to restore, so the restore skips it).
    ov_cells: [grid_cols]Cell = [_]Cell{empty_cell} ** grid_cols,
    ov_styles: [grid_cols]CellStyle = [_]CellStyle{default_cell_style} ** grid_cols,
    ov_fg: [grid_cols]Rgb = [_]Rgb{empty_rgb} ** grid_cols,
    ov_bg: [grid_cols]Rgb = [_]Rgb{empty_rgb} ** grid_cols,
    ov_lens: usize = 0,
    ov_abs: u64 = 0,
    ov_valid: bool = false,

    pub fn reset(self: *Screen) void {
        self.* = .{};
    }

    fn clearLine(self: *Screen, i: usize) void {
        @memset(&self.cells[i], empty_cell);
        @memset(&self.styles[i], default_cell_style);
        @memset(&self.fg_rgb[i], empty_rgb);
        @memset(&self.bg_rgb[i], empty_rgb);
        self.lens[i] = 0;
    }

    fn newline(self: *Screen) void {
        if (self.cur + 1 < grid_lines) {
            self.cur += 1;
            const grew = (self.cur >= self.used);
            if (grew) self.used = self.cur + 1;
            self.clearLine(self.cur);
            if (grew) self.noteTailGrowth();
        } else {
            // Scroll up one line. M73k (#1637): the evicted oldest row
            // enters the history ring — pushed BEFORE the shift, which
            // would otherwise overwrite row 0 and lose it (normal screen
            // only — history belongs to the primary screen, pinned by
            // test) — and a scrolled-back view PINS instead of snapping.
            self.pushHistory();
            var i: usize = 0;
            while (i + 1 < grid_lines) : (i += 1) {
                self.cells[i] = self.cells[i + 1];
                self.styles[i] = self.styles[i + 1];
                self.lens[i] = self.lens[i + 1];
                // M73h fixup: the truecolour side arrays ride with their
                // cells — otherwise a scroll repaints surviving rows
                // with the wrong cell's rgb.
                self.fg_rgb[i] = self.fg_rgb[i + 1];
                self.bg_rgb[i] = self.bg_rgb[i + 1];
            }
            self.clearLine(grid_lines - 1);
            self.cur = grid_lines - 1;
            self.used = grid_lines;
            self.noteTailGrowth();
        }
        self.col = 0;
    }

    /// M73k: the tail grew (line pushed to history, or a new grid row
    /// materialised). While the reader is scrolled back the window's
    /// BOTTOM must stay put: view counts from the tail, so bumping it by
    /// the growth keeps `lineCount - view` — and the absolute identity
    /// behind every unified row — exactly where it was. At view 0
    /// nothing changes (the tail follows, as ever).
    fn noteTailGrowth(self: *Screen) void {
        if (self.view > 0) {
            self.view += 1;
            // Ring-full pushes do not grow lineCount: clamp so a pinned
            // view can never outrange the stored space (bottom >= 0).
            const max_view = self.lineCount() - 1;
            if (self.view > max_view) self.view = max_view;
        }
    }

    /// M73k: move the grid's evicted oldest row into this screen's ring.
    /// Registry screens only (a local Screen has no bank and drops like
    /// before — existing tests unchanged). RGB side arrays are coerced to
    /// the presentation default: history does not store them (budget),
    /// and a stale `rgb_colour` slot with no side data would paint black.
    fn pushHistory(self: *Screen) void {
        if (self.alt_active) return; // history belongs to the normal screen
        const bank = histOf(self) orelse return;
        var styles_row: [grid_cols]CellStyle = undefined;
        for (0..grid_cols) |c| {
            var st = self.styles[0][c];
            if (st.fg == rgb_colour) st.fg = default_colour;
            if (st.bg == rgb_colour) st.bg = default_colour;
            styles_row[c] = st;
        }
        if (self.hist_count < history_lines) {
            const slot = (self.hist_start + self.hist_count) % history_lines;
            @memcpy(bank.cells[slot][0..], self.cells[0][0..]);
            @memcpy(bank.styles[slot][0..], styles_row[0..]);
            bank.lens[slot] = self.lens[0];
            self.hist_count += 1;
        } else {
            // Ring full: overwrite the oldest slot and rotate — the same
            // drop-oldest policy the grid itself has always used.
            @memcpy(bank.cells[self.hist_start][0..], self.cells[0][0..]);
            @memcpy(bank.styles[self.hist_start][0..], styles_row[0..]);
            bank.lens[self.hist_start] = self.lens[0];
            self.hist_start = (self.hist_start + 1) % history_lines;
            self.hist_dropped += 1;
        }
    }

    pub fn clearScreen(self: *Screen) void {
        // M73k: a screen clear takes the whole space — history included —
        // and any live search with it (its overlay row is about to vanish;
        // restoring it later would resurrect pre-clear content). The ALT
        // entry clear is the exception: it clears the freshly swapped-in
        // alt grid, while the history belongs to the primary screen
        // waiting underneath and must survive the round trip (pinned).
        self.searchAbort();
        if (!self.alt_active and histOf(self) != null) {
            self.hist_count = 0;
            self.hist_start = 0;
            self.hist_dropped = 0;
        }
        var i: usize = 0;
        while (i < grid_lines) : (i += 1) self.clearLine(i);
        self.used = 1;
        self.cur = 0;
        self.col = 0;
        self.view = 0;
        self.clearSelection();
    }

    /// M73a-1 (#1625): place one rune. Width comes from `text.char_width`:
    /// a double-width rune takes base + continuation cells and never splits
    /// across a wrap; a zero-width rune overlays its mark onto the base
    /// behind the cursor (stepping over a continuation cell), with no base
    /// behind it pinned to U+FFFD, and ignorable zero-width runes dropped
    /// without a cell. `mark` is only non-zero for the reflow re-feed,
    /// which restores a stored overlay verbatim. A write that would split
    /// a wide pair repairs the pair first.
    fn putRune(self: *Screen, cp: u21, mark: u21, style: CellStyle) void {
        const width: usize = text.char_width(cp);
        if (width == 0) {
            if (text.is_zero_width_ignorable(cp)) return; // no cell, cursor unchanged
            if (self.col == 0) {
                self.putRune(0xFFFD, 0, style); // no base behind: pin to U+FFFD
                return;
            }
            var base_col = self.col - 1;
            if (base_col > 0 and self.cells[self.cur][base_col].cont != 0) base_col -= 1;
            if (self.cells[self.cur][base_col].cont != 0) {
                // A continuation at column 0 would be corrupt; be honest.
                self.putRune(0xFFFD, 0, style);
                return;
            }
            self.cells[self.cur][base_col].mark = cp; // one overlay slot: last wins
            return; // M73k: writes never touch the view (pin-while-scrolled)
        }
        if (width == 2 and self.col + 2 > self.cols) {
            self.newline();
        } else if (self.col >= self.cols) {
            self.newline();
        }
        // Pair repair: a continuation cell we overwrite loses its base, and
        // a continuation cell just past the written range belonged to a
        // base we are replacing. Clear the orphan rather than leave a
        // torn half-pair for the painter.
        if (self.col > 0 and self.cells[self.cur][self.col].cont != 0) {
            self.cells[self.cur][self.col - 1] = empty_cell;
            self.styles[self.cur][self.col - 1] = default_cell_style;
        }
        if (self.col + width < grid_cols and self.cells[self.cur][self.col + width].cont != 0) {
            self.cells[self.cur][self.col + width] = empty_cell;
            self.styles[self.cur][self.col + width] = default_cell_style;
        }
        self.cells[self.cur][self.col] = .{ .base = cp, .mark = mark, .cont = 0 };
        self.styles[self.cur][self.col] = style;
        self.fg_rgb[self.cur][self.col] = self.fg_rgb_cur;
        self.bg_rgb[self.cur][self.col] = self.bg_rgb_cur;
        if (width == 2) {
            self.cells[self.cur][self.col + 1] = empty_cell;
            self.cells[self.cur][self.col + 1].cont = 1;
            self.styles[self.cur][self.col + 1] = style;
            self.fg_rgb[self.cur][self.col + 1] = self.fg_rgb_cur;
            self.bg_rgb[self.cur][self.col + 1] = self.bg_rgb_cur;
        }
        const end = self.col + width;
        if (end > self.lens[self.cur]) self.lens[self.cur] = end;
        self.col = end;
    }

    fn setForeground(self: *Screen, colour: colour_slot) void {
        self.style.fg = colour;
    }

    fn setBackground(self: *Screen, colour: colour_slot) void {
        self.style.bg = colour;
    }

    fn setBold(self: *Screen, on: bool) void {
        self.style.bold = on;
    }

    // M73h: the remaining rendition flags (SGR 2/3/4/7 and their resets).
    fn setDim(self: *Screen, on: bool) void {
        self.style.dim = on;
    }

    fn setItalic(self: *Screen, on: bool) void {
        self.style.italic = on;
    }

    fn setUnderline(self: *Screen, on: bool) void {
        self.style.underline = on;
    }

    fn setReverse(self: *Screen, on: bool) void {
        self.style.reverse = on;
    }

    fn resetCsi(self: *Screen) void {
        self.csi_params = [_]u16{0} ** self.csi_params.len;
        self.csi_count = 1;
        self.csi_private = false;
    }

    fn csiParam(self: *const Screen, index: usize, fallback: u16) u16 {
        if (index >= self.csi_count) return fallback;
        const value = self.csi_params[index];
        return if (value == 0) fallback else value;
    }

    fn eraseLine(self: *Screen, mode: u16) void {
        var start: usize = switch (mode) {
            1 => 0,
            2 => 0,
            else => @min(self.col, self.cols),
        };
        var end: usize = switch (mode) {
            1 => @min(self.col + 1, self.cols),
            else => self.cols,
        };
        // M73a-1: never erase half a wide pair — extend the range over any
        // pair edge the requested range would split.
        if (start > 0 and self.cells[self.cur][start].cont != 0) start -= 1;
        if (end < grid_cols and self.cells[self.cur][end].cont != 0) end += 1;
        var c = start;
        while (c < end) : (c += 1) {
            self.cells[self.cur][c] = empty_cell;
            self.styles[self.cur][c] = default_cell_style;
            self.fg_rgb[self.cur][c] = empty_rgb;
            self.bg_rgb[self.cur][c] = empty_rgb;
        }
        if (mode == 2) {
            self.lens[self.cur] = 0;
        } else if (mode == 0 and start < self.lens[self.cur]) {
            self.lens[self.cur] = start;
        }
    }

    fn eraseDisplay(self: *Screen, mode: u16) void {
        switch (mode) {
            1 => {
                var row: usize = 0;
                while (row < self.cur) : (row += 1) self.clearLine(row);
                self.eraseLine(1);
            },
            2, 3 => self.clearScreen(),
            else => {
                self.eraseLine(0);
                var row = self.cur + 1;
                while (row < self.used) : (row += 1) self.clearLine(row);
            },
        }
    }

    fn moveCursor(self: *Screen, row_one_based: u16, col_one_based: u16) void {
        const row = @min(@as(usize, row_one_based - 1), grid_lines - 1);
        const column = @min(@as(usize, col_one_based - 1), self.cols - 1);
        while (self.used <= row) {
            self.clearLine(self.used);
            self.used += 1;
            self.noteTailGrowth(); // M73k: growth under a pinned view
        }
        self.cur = row;
        self.col = column;
    }

    fn swapAlternate(self: *Screen) void {
        var row: usize = 0;
        while (row < grid_lines) : (row += 1) {
            std.mem.swap([grid_cols]Cell, &self.cells[row], &self.alt_cells[row]);
            std.mem.swap([grid_cols]CellStyle, &self.styles[row], &self.alt_styles[row]);
        }
        std.mem.swap([grid_lines]usize, &self.lens, &self.alt_lens);
        std.mem.swap(usize, &self.used, &self.alt_used);
        std.mem.swap(usize, &self.cur, &self.alt_cur);
        std.mem.swap(usize, &self.col, &self.alt_col);
        std.mem.swap(usize, &self.view, &self.alt_view);
        std.mem.swap(CellStyle, &self.style, &self.alt_style);
        std.mem.swap([grid_lines][grid_cols]Rgb, &self.fg_rgb, &self.alt_fg_rgb);
        std.mem.swap([grid_lines][grid_cols]Rgb, &self.bg_rgb, &self.alt_bg_rgb);
        std.mem.swap(Rgb, &self.fg_rgb_cur, &self.alt_fg_rgb_cur);
        std.mem.swap(Rgb, &self.bg_rgb_cur, &self.alt_bg_rgb_cur);
    }

    fn setAlternate(self: *Screen, enabled: bool) void {
        if (self.alt_active == enabled) return;
        // M73k: close a live search BEFORE the swap — its prompt row
        // lives in the primary grid, and an abort after the swap would
        // stash the prompt and ghost it on exit (pinned by test).
        if (self.search_active) self.searchExit();
        self.swapAlternate();
        self.alt_active = enabled;
        self.clearSelection();
        if (enabled) {
            self.clearScreen();
            self.style = default_cell_style;
            self.fg_rgb_cur = empty_rgb;
            self.bg_rgb_cur = empty_rgb;
        }
    }

    fn applySgr(self: *Screen) void {
        var i: usize = 0;
        while (i < self.csi_count) : (i += 1) {
            const param = self.csi_params[i];
            switch (param) {
                0 => self.style = default_cell_style,
                1 => self.setBold(true),
                2 => self.setDim(true),
                3 => self.setItalic(true),
                4 => self.setUnderline(true),
                7 => self.setReverse(true),
                22 => {
                    self.setBold(false);
                    self.setDim(false);
                },
                23 => self.setItalic(false),
                24 => self.setUnderline(false),
                27 => self.setReverse(false),
                30...37 => self.setForeground(@intCast(param - 30)),
                39 => self.setForeground(default_colour),
                40...47 => self.setBackground(@intCast(param - 40)),
                49 => self.setBackground(default_colour),
                90...97 => self.setForeground(@intCast(param - 90 + 8)),
                100...107 => self.setBackground(@intCast(param - 100 + 8)),
                // M73h extended selectors: each consumes its own trailing
                // params so `1;38;5;196;48;2;1;2;3m` walks correctly.
                38 => self.applyExtendedColour(&i, true),
                48 => self.applyExtendedColour(&i, false),
                else => {}, // unknown — consumed, rendition unchanged (pinned)
            }
        }
    }

    /// M73h (#1634): the `38`/`48` extended colour selector — `5;n` (xterm
    /// 256) or `2;r;g;b` (truecolour). `i` points at the selector; its
    /// arguments are consumed past it. Invalid, out-of-range, or
    /// truncated forms leave the slot unchanged — never a
    /// half-interpreted colour; a truncated tail drops the remaining
    /// params (they cannot be trusted as standalone SGRs). The colon (ITU)
    /// sub-parameter form has no parse arm: ':' lands in the intermediate
    /// skip, the digits collapse into one unknown param, and the selector
    /// is ignored (pinned by the corpus).
    fn applyExtendedColour(self: *Screen, i: *usize, fg: bool) void {
        const kind_i = i.* + 1;
        if (kind_i >= self.csi_count) return; // bare `38`/`48` — ignore
        i.* = kind_i;
        const kind = self.csi_params[kind_i];
        if (kind == 5) {
            const n_i = kind_i + 1;
            if (n_i >= self.csi_count) return; // truncated `38;5` — ignore
            i.* = n_i;
            const n = self.csi_params[n_i];
            if (n <= 255) {
                if (fg) self.setForeground(@intCast(n)) else self.setBackground(@intCast(n));
            } // out of range: slot unchanged
        } else if (kind == 2) {
            const b_i = kind_i + 3;
            if (b_i >= self.csi_count) {
                i.* = self.csi_count - 1; // truncated rgb: drop the tail
                return;
            }
            i.* = b_i;
            const r = self.csi_params[kind_i + 1];
            const g = self.csi_params[kind_i + 2];
            const b = self.csi_params[b_i];
            if (r <= 255 and g <= 255 and b <= 255) {
                const rgb = Rgb{ .r = @intCast(r), .g = @intCast(g), .b = @intCast(b) };
                if (fg) {
                    self.style.fg = rgb_colour;
                    self.fg_rgb_cur = rgb;
                } else {
                    self.style.bg = rgb_colour;
                    self.bg_rgb_cur = rgb;
                }
            } // out of range: slot unchanged (mode NOT set)
        } // any other kind: consumed and ignored
    }

    fn dispatchCsi(self: *Screen, final: u8) void {
        const p0 = self.csiParam(0, 0);
        if (self.csi_private) {
            if (p0 == 47 or p0 == 1049) {
                if (final == 'h') self.setAlternate(true);
                if (final == 'l') self.setAlternate(false);
            }
            if (p0 == 25) {
                if (final == 'h') self.cursor_visible = true;
                if (final == 'l') self.cursor_visible = false;
            }
            // M73e (#1629): bracketed-paste mode — tracked, never painted.
            if (p0 == 2004) {
                self.bracketed_paste = (final == 'h');
            }
            return;
        }
        switch (final) {
            'm' => self.applySgr(),
            'H', 'f' => self.moveCursor(self.csiParam(0, 1), self.csiParam(1, 1)),
            'J' => self.eraseDisplay(p0),
            'K' => self.eraseLine(p0),
            else => {},
        }
    }

    /// Feed one output byte. CSI is intentionally bounded to the sequences
    /// a window TUI needs; unsupported sequences are consumed, never painted.
    /// Bytes >= 0x80 are UTF-8-decoded into the grid (M73a-1 #1625); an
    /// ill-formed sequence becomes U+FFFD, never a raw byte.
    pub fn putByte(self: *Screen, b: u8) void {
        // M73a-1: a pending UTF-8 sequence continues here (b is a
        // continuation byte) or fails: one U+FFFD for the truncated
        // sequence, then this byte is processed fresh as if idle (an ESC
        // after a half-sequence still starts an escape).
        if (self.utf_need > 0) {
            if ((b & 0xc0) == 0x80) {
                self.utfContinue(b);
                return;
            }
            self.utf_need = 0;
            self.utf_len = 0;
            self.putRune(0xFFFD, 0, self.style);
        }
        switch (self.esc_state) {
            0 => {},
            1 => {
                self.esc_state = 0;
                if (b == '[') {
                    self.esc_state = 2;
                    self.resetCsi();
                }
                return;
            },
            2 => {
                if (b >= '0' and b <= '9') {
                    const last = self.csi_count - 1;
                    self.csi_params[last] = self.csi_params[last] *% 10 +% (b - '0');
                    return;
                }
                if (b == ';') {
                    if (self.csi_count < self.csi_params.len) self.csi_count += 1;
                    return;
                }
                if (b == '?' and self.csi_count == 1 and self.csi_params[0] == 0) {
                    self.csi_private = true;
                    return;
                }
                if (b >= 0x20 and b <= 0x3f) return; // unsupported intermediates
                self.esc_state = 0;
                self.dispatchCsi(b);
                return;
            },
            else => self.esc_state = 0,
        }
        switch (b) {
            0x1b => self.esc_state = 1,
            '\n' => self.newline(),
            '\r' => self.col = 0,
            0x08 => {
                if (self.col > 0) self.col -= 1;
            },
            '\t' => {
                const next = (self.col + 8) & ~@as(usize, 7);
                self.col = @min(next, self.cols - 1);
            },
            0x07 => {}, // bell — silent
            else => {
                if (b < 0x20 or b == 0x7f) return;
                if (b < 0x80) {
                    self.putRune(b, 0, self.style);
                } else {
                    self.utfStart(b);
                }
            },
        }
    }

    /// M73a-1: start a UTF-8 sequence — C2..F4 are well-formed leads; a
    /// stray continuation byte or an invalid lead (C0/C1, F5..FF) is one
    /// U+FFFD.
    fn utfStart(self: *Screen, b: u8) void {
        if (b < 0xc2 or b > 0xf4) {
            self.putRune(0xFFFD, 0, self.style);
            return;
        }
        self.utf_need = if (b < 0xe0) @as(u8, 1) else if (b < 0xf0) 2 else 3;
        self.utf_acc = if (b < 0xe0) b & 0x1f else if (b < 0xf0) b & 0x0f else b & 0x07;
        self.utf_len = self.utf_need + 1;
    }

    /// M73a-1: accumulate a continuation byte; at the last byte validate
    /// the whole sequence (overlong, surrogate, and above U+10FFFF each
    /// fail as one U+FFFD for the sequence, not one per byte).
    fn utfContinue(self: *Screen, b: u8) void {
        self.utf_acc = (self.utf_acc << 6) | @as(u32, b & 0x3f);
        self.utf_need -= 1;
        if (self.utf_need > 0) return;
        const cp = self.utf_acc;
        const ok = switch (self.utf_len) {
            2 => cp >= 0x80,
            3 => cp >= 0x800 and !(cp >= 0xd800 and cp <= 0xdfff),
            4 => cp >= 0x10000 and cp <= 0x10ffff,
            else => false,
        };
        self.utf_len = 0;
        const rune: u21 = if (ok) @intCast(cp) else 0xFFFD;
        self.putRune(rune, 0, self.style);
    }

    pub fn feed(self: *Screen, bytes: []const u8) void {
        for (bytes) |b| self.putByte(b);
    }

    /// M73k (#1637): the total surviving lines as ONE space — history
    /// first (oldest at 0), then the grid. The painter's existing
    /// `lineCount - view - rows` walk and `terminalHitAt`'s mirror both
    /// index this, so history paints and hit-tests with zero walk edits.
    /// Alt-screen: its own bounded world — history never shows there.
    pub fn lineCount(self: *const Screen) usize {
        if (self.alt_active) return self.used;
        return self.hist_count + self.used;
    }

    /// The unified row the cursor sits on — the PAINT-side index (the
    /// corpus, wheel reports and search keep the grid-relative `cursorLine`).
    pub fn cursorLineUnified(self: *const Screen) usize {
        return if (self.alt_active) self.cur else self.hist_count + self.cur;
    }

    /// The ASCII projection of line `i` (empty for an out-of-range line):
    /// base runes U+0000..U+007F as themselves; continuation cells and any
    /// non-ASCII rune project to one 0x00 byte (the renderer already skips
    /// <0x20 and >0x7E, so rune cells draw nothing until M73a-2's painter
    /// reads `cellAt`). The length is still the cell count (`lens`), so
    /// column indices line up. Module scratch: consume the result before
    /// the next call.
    pub fn line(self: *const Screen, i: usize) []const u8 {
        const row_cells = self.uCells(i) orelse return &.{};
        const n = @min(self.uLen(i) orelse 0, grid_cols);
        for (0..n) |c| {
            const cell = row_cells[c];
            line_scratch[c] = if (cell.cont != 0 or cell.base >= 0x80) 0 else @intCast(cell.base);
        }
        return line_scratch[0..n];
    }

    /// M73k: resolve unified row `i` to its cells / length / rendition
    /// (null = past the end). History rows come from this screen's bank,
    /// grid rows shift by `hist_count`, the alt screen never has history.
    fn uCells(self: *const Screen, i: usize) ?[]const Cell {
        if (self.alt_active) {
            if (i >= self.used) return null;
            return &self.cells[i];
        }
        if (i < self.hist_count) {
            const bank = histOf(self) orelse return null;
            return &bank.cells[(self.hist_start + i) % history_lines];
        }
        const gr = i - self.hist_count;
        if (gr >= self.used) return null;
        return &self.cells[gr];
    }

    fn uLen(self: *const Screen, i: usize) ?usize {
        if (self.alt_active) {
            if (i >= self.used) return null;
            return self.lens[i];
        }
        if (i < self.hist_count) {
            const bank = histOf(self) orelse return null;
            return bank.lens[(self.hist_start + i) % history_lines];
        }
        const gr = i - self.hist_count;
        if (gr >= self.used) return null;
        return self.lens[gr];
    }

    fn uStyles(self: *const Screen, i: usize) ?[]const CellStyle {
        if (self.alt_active) {
            if (i >= self.used) return null;
            return &self.styles[i];
        }
        if (i < self.hist_count) {
            const bank = histOf(self) orelse return null;
            return &bank.styles[(self.hist_start + i) % history_lines];
        }
        const gr = i - self.hist_count;
        if (gr >= self.used) return null;
        return &self.styles[gr];
    }

    /// The real cell at (line, col) — M73a-1's presentation truth for the
    /// painter, tests, and anyone who needs runes rather than bytes.
    pub fn cellAt(self: *const Screen, line_index: usize, col_index: usize) Cell {
        if (col_index >= grid_cols) return empty_cell;
        const row_cells = self.uCells(line_index) orelse return empty_cell;
        return row_cells[col_index];
    }

    pub fn cursorLine(self: *const Screen) usize {
        return self.cur;
    }

    pub fn cursorCol(self: *const Screen) usize {
        return self.col;
    }

    pub fn columns(self: *const Screen) usize {
        return self.cols;
    }

    pub fn styleAt(self: *const Screen, line_index: usize, col_index: usize) CellStyle {
        if (col_index >= self.cols) return default_cell_style;
        const row_styles = self.uStyles(line_index) orelse return default_cell_style;
        return row_styles[col_index];
    }

    /// M73h (#1634): the truecolour channels for a cell — null unless that
    /// cell's slot marks `rgb_colour` (palette/default cells store no RGB).
    pub fn rgbAt(self: *const Screen, line_index: usize, col_index: usize) struct { fg: ?Rgb, bg: ?Rgb } {
        // M73k: history rows store no RGB side arrays (push coerces those
        // slots to the presentation default) — nulls are truthful there.
        if (!self.alt_active and line_index < self.hist_count) return .{ .fg = null, .bg = null };
        const gr = if (self.alt_active) line_index else line_index - self.hist_count;
        if (gr >= self.used or col_index >= self.cols) return .{ .fg = null, .bg = null };
        const st = self.styles[gr][col_index];
        return .{
            .fg = if (st.fg == rgb_colour) self.fg_rgb[gr][col_index] else null,
            .bg = if (st.bg == rgb_colour) self.bg_rgb[gr][col_index] else null,
        };
    }

    // -- M49 SD5 (#1132): scrollback view -----------------------------------

    /// Move the scrollback view by `delta` lines (positive = older). Clamped
    /// to the stored range; 0 follows the tail.
    pub fn scrollBy(self: *Screen, delta: i32) void {
        // M73k: the stored range is now grid+history as one space.
        const total = self.lineCount();
        const max_view: i64 = if (total > 0) @intCast(total - 1) else 0;
        var v: i64 = @as(i64, @intCast(self.view)) + delta;
        if (v < 0) v = 0;
        if (v > max_view) v = max_view;
        self.view = @intCast(v);
        // M73k: the prompt bar follows the window (its row is bottom-1).
        if (self.search_active) self.searchDrawPrompt();
    }

    /// Snap the view back to the tail. M73k: new output no longer does
    /// this implicitly — pin-while-scrolled; Shift+End still snaps.
    pub fn scrollReset(self: *Screen) void {
        self.view = 0;
        if (self.search_active) self.searchDrawPrompt(); // M73k: bar follows
    }

    pub fn viewOffset(self: *const Screen) usize {
        return self.view;
    }

    // -- M49 SD5 (#1132): resize reflow -------------------------------------

    /// The number of grid rows the cells of one logical line occupy at
    /// `cols` columns — placement-aware (M73a-1): wide pairs never split,
    /// so a pair that meets the last free column wraps early (at least one
    /// row, even for an empty line).
    fn wrappedRows(cells_in: []const Cell, cols: usize) usize {
        if (cells_in.len == 0) return 1;
        var rows: usize = 1;
        var col: usize = 0;
        for (cells_in) |cell| {
            if (cell.cont != 0) continue;
            const w: usize = if (text.char_width(cell.base) >= 2) 2 else 1;
            if (col + w > cols) {
                rows += 1;
                col = w;
            } else {
                col += w;
            }
        }
        return rows;
    }

    /// Reflow the stored lines to `new_cols` columns. The buffer is fixed;
    /// when the wrapped result would overflow `grid_lines`, whole oldest
    /// lines are dropped (the same policy as output scrolling). The cursor
    /// follows the last kept line. Selection is cleared (its coordinates
    /// were for the old layout).
    pub fn reflow(self: *Screen, new_cols: usize) void {
        const c = @max(@as(usize, 8), @min(new_cols, grid_cols));
        if (c == self.cols) return;
        // M73k: close any live search FIRST — its overlay row must be
        // restored as the OLD content before rows re-lay out, and match
        // coordinates cannot survive a re-wrap (resize closes the bar).
        self.searchExit();

        // The oldest line that still fits, so the reflow drops from the top
        // exactly like new output would.
        var kept: usize = 0;
        var first: usize = self.used;
        while (first > 0) {
            const k = wrappedRows(self.cells[first - 1][0..self.lens[first - 1]], c);
            if (kept + k > grid_lines) break;
            kept += k;
            first -= 1;
        }

        // Snapshot the kept lines (module BSS scratch: the rune-cell grid
        // is ~80 KiB, too much for IRQ/Task stacks).
        var count: usize = 0;
        var i: usize = first;
        while (i < self.used) : (i += 1) {
            const len = @min(self.lens[i], grid_cols);
            @memcpy(reflow_lines[count][0..len], self.cells[i][0..len]);
            @memcpy(reflow_styles[count][0..len], self.styles[i][0..len]);
            @memcpy(reflow_fg_rgb[count][0..len], self.fg_rgb[i][0..len]);
            @memcpy(reflow_bg_rgb[count][0..len], self.bg_rgb[i][0..len]);
            reflow_lens[count] = len;
            count += 1;
        }
        var line_count: usize = 0;
        while (line_count < grid_lines) : (line_count += 1) self.clearLine(line_count);
        self.used = 1;
        self.cur = 0;
        self.col = 0;
        self.esc_state = 0;
        self.cols = c;
        self.view = 0;
        self.clearSelection();

        // Re-feed the kept logical lines at the new width.
        var n: usize = 0;
        while (n < count) : (n += 1) {
            var cell: usize = 0;
            while (cell < reflow_lens[n]) : (cell += 1) {
                const src = reflow_lines[n][cell];
                if (src.cont != 0) continue; // its base re-creates the pair
                const width = text.char_width(src.base);
                self.putRune(src.base, src.mark, reflow_styles[n][cell]);
                if (width > 0) {
                    // putRune left the cursor past the glyph it just wrote
                    // (after a wrap that is column `width`); M73h: carry the
                    // cell's truecolour channels to the same landing spot.
                    const landed = self.col - width;
                    self.fg_rgb[self.cur][landed] = reflow_fg_rgb[n][cell];
                    self.bg_rgb[self.cur][landed] = reflow_bg_rgb[n][cell];
                    if (width == 2) {
                        self.fg_rgb[self.cur][landed + 1] = reflow_fg_rgb[n][cell];
                        self.bg_rgb[self.cur][landed + 1] = reflow_bg_rgb[n][cell];
                    }
                }
            }
            if (n + 1 < count) self.newline();
        }
        self.reflowHistory(c);
    }

    /// M73k (#1637, deliverable 3): history re-wraps WITH the grid — the
    /// same per-row `wrappedRows` policy and the same drop-oldest bound —
    /// so grid and history can never disagree after a drag. A logical-
    /// store/view-wrap alternative would break the paint walk's 1:1 row
    /// mapping (that constraint is why this policy is THE policy). The
    /// kept rows bounce through the temp bank because an EXPANDING
    /// re-wrap cannot be done in place: on one ring it would overwrite
    /// rows it has not read yet.
    fn reflowHistory(self: *Screen, new_cols: usize) void {
        if (self.hist_count == 0) return;
        const bank = histOf(self) orelse {
            self.hist_count = 0;
            return;
        };
        // Pass 1 (read-only): newest-first, keep the longest suffix whose
        // re-wrapped row count fits the ring — drop-oldest, like the grid.
        var out_rows: usize = 0;
        var hfirst: usize = self.hist_count;
        while (hfirst > 0) {
            const idx = hfirst - 1;
            const slot = (self.hist_start + idx) % history_lines;
            const k = wrappedRows(bank.cells[slot][0..bank.lens[slot]], new_cols);
            if (out_rows + k > history_lines) break;
            out_rows += k;
            hfirst -= 1;
        }
        // Pass 2: snapshot the kept rows (forward) into the temp bank.
        var m: usize = 0;
        var i = hfirst;
        while (i < self.hist_count) : (i += 1) {
            const slot = (self.hist_start + i) % history_lines;
            const len = bank.lens[slot];
            @memcpy(history_temp.cells[m][0..len], bank.cells[slot][0..len]);
            @memcpy(history_temp.styles[m][0..len], bank.styles[slot][0..len]);
            history_temp.lens[m] = len;
            m += 1;
        }
        // Pass 3: rebuild the ring at the new width. Direct cell
        // placement (no decode): wide pairs stay together, a wrap that
        // would split one lands early — the same rule as `wrappedRows`.
        self.hist_count = 0;
        self.hist_start = 0;
        self.hist_dropped += hfirst;
        var t: usize = 0;
        while (t < m) : (t += 1) {
            const len = history_temp.lens[t];
            var oc: usize = 0; // output column on the current row
            var ci: usize = 0;
            while (ci < len) : (ci += 1) {
                const src = history_temp.cells[t][ci];
                if (src.cont != 0) continue; // its base already placed the pair
                const w: usize = if (text.char_width(src.base) >= 2) 2 else 1;
                if (oc + w > new_cols and oc > 0) {
                    self.closeHistRow(bank, oc);
                    oc = 0;
                }
                const slot = self.hist_count; // hist_start = 0 during rebuild
                bank.cells[slot][oc] = src;
                bank.styles[slot][oc] = history_temp.styles[t][ci];
                if (w == 2 and ci + 1 < len) {
                    bank.cells[slot][oc + 1] = history_temp.cells[t][ci + 1];
                    bank.styles[slot][oc + 1] = history_temp.styles[t][ci + 1];
                }
                oc += w;
            }
            self.closeHistRow(bank, oc); // every input row ends one output row
        }
    }

    /// Finish the ring row currently being rebuilt (`hist_count` grows
    /// only when a row is complete, so a partial row is never visible).
    fn closeHistRow(self: *Screen, bank: *HistoryBank, len: usize) void {
        bank.lens[self.hist_count] = len;
        self.hist_count += 1;
    }

    /// Set the effective column count, reflowing when it changes. Returns
    /// the effective value.
    pub fn setCols(self: *Screen, new_cols: usize) usize {
        const c = @max(@as(usize, 8), @min(new_cols, grid_cols));
        if (c != self.cols) self.reflow(c);
        return self.cols;
    }

    // -- M49 SD5 (#1132): selection + copy ----------------------------------

    fn clampPoint(self: *const Screen, row: usize, col: usize) Point {
        return .{
            .line = @min(row, self.used - 1),
            .col = @min(col, self.cols),
        };
    }

    pub fn beginSelection(self: *Screen, row: usize, col: usize) void {
        const p = self.clampPoint(row, col);
        self.sel_anchor = p;
        self.sel_cursor = p;
    }

    pub fn extendSelection(self: *Screen, row: usize, col: usize) void {
        if (self.sel_anchor == null) return;
        self.sel_cursor = self.clampPoint(row, col);
    }

    pub fn clearSelection(self: *Screen) void {
        self.sel_anchor = null;
        self.sel_cursor = null;
    }

    pub fn hasSelection(self: *const Screen) bool {
        return self.sel_anchor != null and self.sel_cursor != null;
    }

    /// True when the cell (row, col) lies inside the current selection
    /// (used by the renderer to highlight it). Empty selections match
    /// nothing.
    pub fn inSelection(self: *const Screen, row: usize, col: usize) bool {
        const a = self.sel_anchor orelse return false;
        const b = self.sel_cursor orelse return false;
        const start = if (a.line < b.line or (a.line == b.line and a.col <= b.col)) a else b;
        const end = if (start.line == a.line and start.col == a.col) b else a;
        if (row < start.line or row > end.line) return false;
        if (row == start.line and col < start.col) return false;
        if (row == end.line and col > end.col) return false;
        return true;
    }

    /// Copy the selected region into `dst` as UTF-8 (lines joined by `\n`,
    /// endpoints inclusive; the region is clamped to the line lengths).
    /// A wide glyph copies once even when only one of its two cells is in
    /// the selection, and a combining overlay rides its base. Returns the
    /// byte count; 0 when there is no selection. Whole runes only — a rune
    /// that does not fit the remaining room ends the copy.
    pub fn copySelection(self: *const Screen, dst: []u8) usize {
        const a = self.sel_anchor orelse return 0;
        const b = self.sel_cursor orelse return 0;
        const start = if (a.line < b.line or (a.line == b.line and a.col <= b.col)) a else b;
        const end = if (start.line == a.line and start.col == a.col) b else a;
        var out: usize = 0;
        var row = start.line;
        while (row <= end.line) : (row += 1) {
            const len = if (row < self.used) self.lens[row] else 0;
            const from = if (row == start.line) @min(start.col, len) else 0;
            const to = if (row == end.line) @min(end.col, len) else len;
            var c = from;
            while (c < to) : (c += 1) {
                const cell = self.cells[row][c];
                if (cell.cont != 0) {
                    // The selection starts inside a wide glyph: emit the
                    // whole glyph once — its base lies just outside.
                    if (c == from and c > 0) {
                        out = encodeCell(dst, out, self.cells[row][c - 1]) orelse break;
                    }
                    continue; // never a second copy of an emitted glyph
                }
                out = encodeCell(dst, out, cell) orelse break;
            }
            if (row < end.line and out < dst.len) {
                dst[out] = '\n';
                out += 1;
            }
        }
        return out;
    }

    // -- M73k (#1637): kernel-side search over grid + history ------------

    /// The abstract keys the search bar consumes. input.zig maps HID keys
    /// to these; tests construct them directly — which is also how a
    /// RUNE enters the pattern (HID keys are ASCII; cells hold runes).
    pub const SearchKey = union(enum) { ch: u21, backspace, enter, prev, esc };

    pub fn searchActive(self: *const Screen) bool {
        return self.search_active;
    }

    /// Open the bar: NORMAL screen only (alt returns false and changes
    /// nothing — pinned). The user's selection is saved (search owns
    /// `sel_*` for the current-match highlight until exit), and the view
    /// lifts off the tail so live output never rewrites the overlay row
    /// (single-line screens cannot lift — documented edge).
    pub fn searchOpen(self: *Screen) bool {
        if (self.alt_active) return false;
        if (self.search_active) return true;
        self.saved_sel_anchor = self.sel_anchor;
        self.saved_sel_cursor = self.sel_cursor;
        self.clearSelection();
        self.search_active = true;
        self.search_len = 0;
        self.search_count = 0;
        self.search_has_cur = false;
        if (self.view == 0 and self.lineCount() > 1) self.view = 1;
        self.searchDrawPrompt(); // positions + saves the overlay row too
        return true;
    }

    /// Feed one key. Returns the match count to klog (`null` = nothing
    /// changed — nav, esc, empty backspace; the `tty: copy`-style klog
    /// mirror in input.zig fires only on a pattern change, and the empty
    /// pattern is a no-op).
    pub fn searchFeed(self: *Screen, key: SearchKey) ?usize {
        if (!self.search_active) return null;
        switch (key) {
            .esc => {
                self.searchExit();
                return null;
            },
            .enter => {
                if (self.search_count > 0) self.searchStep(1);
                return null;
            },
            .prev => {
                if (self.search_count > 0) self.searchStep(-1);
                return null;
            },
            .backspace => {
                if (self.search_len == 0) return null;
                self.search_len -= 1;
                self.searchRecompute();
                self.searchDrawPrompt();
                return if (self.search_len > 0) self.search_count else null;
            },
            .ch => |c| {
                if (self.search_len >= self.search_pat.len) return null;
                self.search_pat[self.search_len] = c;
                self.search_len += 1;
                self.searchRecompute();
                self.searchDrawPrompt();
                return self.search_count;
            },
        }
    }

    /// Exit (Esc): the overlay row and the user's selection come back,
    /// state clears — and the VIEW STAYS where the match put it (the
    /// card's "exits and restores the view at the match").
    pub fn searchExit(self: *Screen) void {
        if (!self.search_active) return;
        self.searchRestoreOverlay();
        self.sel_anchor = self.saved_sel_anchor;
        self.sel_cursor = self.saved_sel_cursor;
        self.searchAbort();
    }

    /// Abort without writing anything back (clearScreen): the row content
    /// is about to vanish, so restoring it later would resurrect stale
    /// pre-clear bytes.
    fn searchAbort(self: *Screen) void {
        self.search_active = false;
        self.search_len = 0;
        self.search_count = 0;
        self.search_has_cur = false;
        self.ov_valid = false;
        self.saved_sel_anchor = null;
        self.saved_sel_cursor = null;
    }

    // Row-local literal matcher: ASCII-case-insensitive, everything else
    // exact. Rune-aware by construction — cells hold runes, the pattern
    // holds runes, an accented match compares codepoint to codepoint.
    // Matches NEVER cross row boundaries (v1, pinned): each row is its
    // own haystack.
    fn foldAscii(c: u21) u21 {
        return if (c >= 'A' and c <= 'Z') c + 32 else c;
    }

    fn matchAt(row_cells: []const Cell, row_len: usize, col: usize, pat: []const u21) bool {
        if (col + pat.len > row_len) return false;
        var j: usize = 0;
        while (j < pat.len) : (j += 1) {
            if (foldAscii(row_cells[col + j].base) != foldAscii(pat[j])) return false;
        }
        return true;
    }

    /// M73k: the unified row the prompt bar currently covers — from the
    /// STASH (absolute across ring rotation), not from `view`: during a
    /// scan the bar still sits where the last draw left it.
    fn stashedRow(self: *const Screen) ?usize {
        if (!self.ov_valid) return null;
        if (self.ov_abs < self.hist_dropped) return null;
        return @intCast(self.ov_abs - self.hist_dropped);
    }

    /// Scan-time row view: the covered row yields its STASHED original
    /// content — the live cells hold prompt chrome, which is neither the
    /// user's data nor searchable (the count must see the real row under
    /// the bar, and must never self-match the pattern the bar draws).
    fn scanCells(self: *const Screen, row: usize) ?[]const Cell {
        if (self.stashedRow()) |u| {
            if (row == u) return self.ov_cells[0..];
        }
        return self.uCells(row);
    }

    fn scanLen(self: *const Screen, row: usize) ?usize {
        if (self.stashedRow()) |u| {
            if (row == u) return self.ov_lens;
        }
        return self.uLen(row);
    }

    /// Rescan the whole space: count every row-local occurrence, park the
    /// current match on the FIRST (top-anchored incremental search), move
    /// the view so it sits right above the prompt bar, and expose it via
    /// the selection range so the existing inversion paint highlights it.
    fn searchRecompute(self: *Screen) void {
        self.search_count = 0;
        self.search_has_cur = false;
        self.clearSelection();
        if (self.search_len == 0) return; // empty pattern = no-op
        const pat = self.search_pat[0..self.search_len];
        const total = self.lineCount();
        var row: usize = 0;
        var first: ?Point = null;
        while (row < total) : (row += 1) {
            const row_cells = self.scanCells(row) orelse continue;
            const row_len = self.scanLen(row) orelse continue;
            var c: usize = 0;
            while (c + pat.len <= row_len) : (c += 1) {
                if (matchAt(row_cells, row_len, c, pat)) {
                    self.search_count += 1;
                    if (first == null) first = .{ .line = row, .col = c };
                    c += pat.len - 1; // non-overlapping occurrences
                }
            }
        }
        if (first) |f| {
            self.search_row = f.line;
            self.search_col = f.col;
            self.search_has_cur = true;
            self.searchHighlight();
            self.searchScrollTo(f.line);
        }
    }

    /// Next/prev with wrap-around — a linear walk over candidate start
    /// positions (rows never contribute cross-row candidates).
    fn searchStep(self: *Screen, dir: i32) void {
        if (!self.search_has_cur or self.search_len == 0) return;
        const pat = self.search_pat[0..self.search_len];
        const total = self.lineCount();
        if (total == 0) return;
        var row: usize = self.search_row;
        var col: usize = self.search_col;
        var guard: usize = 0;
        const guard_max = (history_lines + grid_lines) * grid_cols;
        while (guard < guard_max) : (guard += 1) {
            if (dir > 0) {
                col += 1;
                const rl = self.scanLen(row) orelse continue;
                if (col + pat.len > rl) {
                    row += 1;
                    if (row >= total) row = 0;
                    col = 0;
                }
            } else {
                if (col == 0) {
                    row = if (row == 0) total - 1 else row - 1;
                    const rl = self.scanLen(row) orelse continue;
                    col = if (rl >= pat.len) rl - pat.len else 0;
                } else {
                    col -= 1;
                }
            }
            const row_cells = self.scanCells(row) orelse continue;
            const row_len = self.scanLen(row) orelse continue;
            if (col + pat.len > row_len) continue;
            if (matchAt(row_cells, row_len, col, pat)) {
                self.search_row = row;
                self.search_col = col;
                self.searchHighlight();
                self.searchScrollTo(row);
                return;
            }
        }
    }

    /// The current match IS the selection range while search is up —
    /// `inSelection` treats the end column as inclusive, so the cursor
    /// parks on the last cell of the match.
    fn searchHighlight(self: *Screen) void {
        if (!self.search_has_cur) return;
        self.sel_anchor = .{ .line = self.search_row, .col = self.search_col };
        self.sel_cursor = .{
            .line = self.search_row,
            .col = self.search_col + self.search_len - 1,
        };
    }

    /// Park the match two rows above the window bottom — the row directly
    /// above the prompt bar — without knowing the window's height (the
    /// painter derives `first = lineCount - view - rows` from view alone).
    fn searchScrollTo(self: *Screen, row: usize) void {
        const total = self.lineCount();
        var v: i64 = @as(i64, @intCast(total)) - @as(i64, @intCast(row)) - 2;
        if (v < 0) v = 0;
        const max_v: i64 = if (total > 0) @as(i64, @intCast(total - 1)) else 0;
        if (v > max_v) v = max_v;
        self.view = @intCast(v);
    }

    /// The bar's row: one above the window bottom (absolute-indexed via
    /// `hist_dropped` so ring rotation and grid scroll cannot lose it).
    fn searchOverlayRow(self: *const Screen) usize {
        const total = self.lineCount();
        const v = @min(self.view, total - 1);
        return total - v - 1;
    }

    /// Restore whatever row the bar currently covers, then save the row
    /// about to be covered — so as the view jumps between matches the
    /// saved content FOLLOWS the bar (no prompt ghosts, no lost rows).
    fn searchPositionOverlay(self: *Screen) void {
        self.searchRestoreOverlay();
        const u = self.searchOverlayRow();
        const row_cells = self.uCells(u) orelse return;
        const row_styles = self.uStyles(u) orelse return;
        @memcpy(self.ov_cells[0..], row_cells[0..]);
        @memcpy(self.ov_styles[0..], row_styles[0..]);
        self.ov_lens = self.uLen(u) orelse 0;
        if (!self.alt_active and u >= self.hist_count and (u - self.hist_count) < self.used) {
            const gr = u - self.hist_count;
            @memcpy(self.ov_fg[0..], self.fg_rgb[gr][0..]);
            @memcpy(self.ov_bg[0..], self.bg_rgb[gr][0..]);
        } else {
            @memset(&self.ov_fg, empty_rgb);
            @memset(&self.ov_bg, empty_rgb);
        }
        self.ov_abs = u + self.hist_dropped;
        self.ov_valid = true;
    }

    fn searchRestoreOverlay(self: *Screen) void {
        if (!self.ov_valid) return;
        self.ov_valid = false;
        if (self.ov_abs < self.hist_dropped) return; // the line was evicted
        const u: usize = @intCast(self.ov_abs - self.hist_dropped);
        if (self.alt_active) {
            if (u >= self.used) return;
            @memcpy(self.cells[u][0..], self.ov_cells[0..]);
            @memcpy(self.styles[u][0..], self.ov_styles[0..]);
            @memcpy(self.fg_rgb[u][0..], self.ov_fg[0..]);
            @memcpy(self.bg_rgb[u][0..], self.ov_bg[0..]);
            self.lens[u] = self.ov_lens;
            return;
        }
        if (u < self.hist_count) {
            const bank = histOf(self) orelse return;
            const slot = (self.hist_start + u) % history_lines;
            @memcpy(bank.cells[slot][0..], self.ov_cells[0..]);
            @memcpy(bank.styles[slot][0..], self.ov_styles[0..]);
            bank.lens[slot] = self.ov_lens;
            return;
        }
        const gr = u - self.hist_count;
        if (gr >= self.used) return;
        @memcpy(self.cells[gr][0..], self.ov_cells[0..]);
        @memcpy(self.styles[gr][0..], self.ov_styles[0..]);
        @memcpy(self.fg_rgb[gr][0..], self.ov_fg[0..]);
        @memcpy(self.bg_rgb[gr][0..], self.ov_bg[0..]);
        self.lens[gr] = self.ov_lens;
    }

    /// Draw the prompt bar into the overlay row: `> pattern  (N)` or
    /// `> pattern  no match` (the hint line — never an error), the whole
    /// row reversed so the EXISTING inversion paint renders the bar with
    /// zero painter changes.
    fn searchDrawPrompt(self: *Screen) void {
        if (self.alt_active) return;
        self.searchPositionOverlay();
        const u = self.searchOverlayRow();
        var tgt_cells: *[grid_cols]Cell = undefined;
        var tgt_styles: *[grid_cols]CellStyle = undefined;
        var tgt_len: *usize = undefined;
        if (u < self.hist_count) {
            const bank = histOf(self) orelse return;
            const slot = (self.hist_start + u) % history_lines;
            tgt_cells = &bank.cells[slot];
            tgt_styles = &bank.styles[slot];
            tgt_len = &bank.lens[slot];
        } else {
            const gr = u - self.hist_count;
            if (gr >= self.used) return;
            tgt_cells = &self.cells[gr];
            tgt_styles = &self.styles[gr];
            tgt_len = &self.lens[gr];
        }
        const cols_n = self.cols;
        var x: usize = 0;
        const put = struct {
            fn run(cells: *[grid_cols]Cell, pos: *usize, cols_n_: usize, ch: u21) void {
                if (pos.* < cols_n_) {
                    cells[pos.*] = .{ .base = ch, .mark = 0, .cont = 0 };
                    pos.* += 1;
                }
            }
        };
        put.run(tgt_cells, &x, cols_n, '>');
        put.run(tgt_cells, &x, cols_n, ' ');
        for (self.search_pat[0..self.search_len]) |ch| put.run(tgt_cells, &x, cols_n, ch);
        if (self.search_len > 0) {
            if (self.search_count == 0) {
                const hint = "  no match";
                for (hint) |ch| put.run(tgt_cells, &x, cols_n, ch);
            } else {
                var num: [8]u8 = undefined;
                const s = std.fmt.bufPrint(&num, "  ({d})", .{self.search_count}) catch "";
                for (s) |ch| put.run(tgt_cells, &x, cols_n, ch);
            }
        }
        while (x < cols_n) put.run(tgt_cells, &x, cols_n, ' ');
        for (0..cols_n) |c| {
            tgt_styles.*[c] = default_cell_style;
            tgt_styles.*[c].reverse = true;
        }
        for (cols_n..grid_cols) |c| {
            tgt_cells.*[c] = empty_cell;
            tgt_styles.*[c] = default_cell_style;
        }
        tgt_len.* = cols_n;
    }
};

/// M49 SD5: reflow scratch (module BSS — the grid is too large for the task
/// stacks). One reflow at a time (the paint/idle path), documented bound.
var reflow_lines: [grid_lines][grid_cols]Cell = undefined;

/// M73a-1 (#1625): `line()`'s ASCII projection scratch (module BSS). One
/// consumer at a time — the paint path reads a line and moves on.
var line_scratch: [grid_cols]u8 = undefined;
var reflow_styles: [grid_lines][grid_cols]CellStyle = undefined;
/// M73h: reflow scratch for the truecolour side arrays (module BSS).
var reflow_fg_rgb: [grid_lines][grid_cols]Rgb = undefined;
var reflow_bg_rgb: [grid_lines][grid_cols]Rgb = undefined;
var reflow_lens: [grid_lines]usize = undefined;

/// The consumer that renders output and supplies input. Exclusive per
/// terminal: one front-end at a time (ADR 0020 D2).
pub const FrontEnd = enum(u8) {
    none = 0,
    /// The raw virtio serial console.
    serial = 1,
    /// A TABWM desktop terminal window (TERM.BIN).
    window = 2,
    /// A network session (remote console / SSH channel).
    net = 3,
};

/// A terminal session. All methods are pure; the struct is `extern`-free and
/// host-testable as a value.
pub const Terminal = struct {
    out: [out_capacity]u8 = [_]u8{0} ** out_capacity,
    out_start: usize = 0,
    out_len: usize = 0,
    out_dropped: u64 = 0,

    in: [in_capacity]u8 = [_]u8{0} ** in_capacity,
    in_start: usize = 0,
    in_len: usize = 0,
    in_dropped: u64 = 0,

    attached: bool = false,
    front_end: FrontEnd = .none,
    owner_pid: ?usize = null,
    in_use: bool = false,
    /// #1082 (ADR 0020 Amendment A): the `.user` window this terminal is a
    /// front-end for, when `front_end == .window`. Null otherwise.
    window_id: ?u8 = null,
    /// #1083 (ADR 0020 Amendment B): the TCP listen port this terminal is a
    /// front-end for, when `front_end == .net`. 0 otherwise.
    net_port: u16 = 0,
    /// M50 TS4 (#1138, ADR 0024 D6): the delegated net-auth state. When
    /// `net_auth_on`, the pump mints a fresh 32-byte challenge once the
    /// connection is ESTABLISHED, frames it as
    /// `VIRELAIOS-AUTH/1 <scheme> <hex>\n`, buffers the client's one-line
    /// reply, and gates every post-challenge byte on the attached process's
    /// verdict. `net_authed` is the byte gate; `net_reply_ready` means a
    /// well-formed reply awaits the verdict; `net_auth_ticks` is the
    /// challenge clock (10 s deadline). All cleared on detach/reset.
    net_auth_on: bool = false,
    net_auth_scheme: NetAuthScheme = .open,
    net_authed: bool = true, // no auth => open (SH7 behavior)
    net_challenge: [net_challenge_len]u8 = [_]u8{0} ** net_challenge_len,
    net_challenge_sent: bool = false,
    net_auth_ticks: u64 = 0,
    net_reply: [net_auth_line_max]u8 = [_]u8{0} ** net_auth_line_max,
    net_reply_len: usize = 0,
    net_reply_ready: bool = false,
    /// Bytes pipelined after the reply line (the client's first command):
    /// held until the verdict accepts, then delivered — never before.
    net_post: [tcp.payload_max]u8 = [_]u8{0} ** tcp.payload_max,
    net_post_len: usize = 0,
    net_verdict: ?bool = null,
    net_allow_ip: [4]u8 = .{ 0, 0, 0, 0 },
    net_allow_on: bool = false,

    /// Append owner output to the ring. Always accepts every byte; when the
    /// ring is full it drops the oldest byte and counts it. Returns bytes
    /// accepted (== `bytes.len`).
    pub fn write(self: *Terminal, bytes: []const u8) usize {
        for (bytes) |b| {
            if (self.out_len == out_capacity) {
                self.out_start = (self.out_start + 1) % out_capacity;
                self.out_len -= 1;
                self.out_dropped += 1;
            }
            self.out[(self.out_start + self.out_len) % out_capacity] = b;
            self.out_len += 1;
        }
        return bytes.len;
    }

    /// Drain up to `buf.len` output bytes, oldest first. Returns the count.
    pub fn readOut(self: *Terminal, buf: []u8) usize {
        const n = @min(buf.len, self.out_len);
        for (0..n) |i| buf[i] = self.out[(self.out_start + i) % out_capacity];
        self.out_start = (self.out_start + n) % out_capacity;
        self.out_len -= n;
        return n;
    }

    /// Bytes waiting for a front-end to drain.
    pub fn pendingOut(self: *const Terminal) usize {
        return self.out_len;
    }

    /// Push front-end input. When the queue is full the NEWEST byte is
    /// dropped and counted. Returns bytes accepted.
    pub fn pushInput(self: *Terminal, bytes: []const u8) usize {
        var accepted: usize = 0;
        for (bytes) |b| {
            if (self.in_len == in_capacity) {
                self.in_dropped += 1;
                continue;
            }
            self.in[(self.in_start + self.in_len) % in_capacity] = b;
            self.in_len += 1;
            accepted += 1;
        }
        return accepted;
    }

    /// Drain up to `buf.len` input bytes, oldest first. Returns the count.
    pub fn readInput(self: *Terminal, buf: []u8) usize {
        const n = @min(buf.len, self.in_len);
        for (0..n) |i| buf[i] = self.in[(self.in_start + i) % in_capacity];
        self.in_start = (self.in_start + n) % in_capacity;
        self.in_len -= n;
        return n;
    }

    /// Input bytes waiting for the owner.
    pub fn pendingInput(self: *const Terminal) usize {
        return self.in_len;
    }

    /// Attach a front-end. Exclusive: fails when one is already attached or
    /// `fe` is `.none`. Idempotent re-attach by the SAME front-end succeeds.
    pub fn attach(self: *Terminal, fe: FrontEnd) bool {
        if (fe == .none) return false;
        if (self.attached) return self.front_end == fe;
        self.attached = true;
        self.front_end = fe;
        return true;
    }

    /// Detach whatever front-end is attached (no-op when none).
    pub fn detach(self: *Terminal) void {
        self.attached = false;
        self.front_end = .none;
        self.window_id = null;
        self.net_port = 0;
        self.clearNetAuth();
    }

    /// M50 TS4: drop all net-auth state (challenge, reply, post bytes,
    /// verdict, auth flag, allowlist). Called on detach and before a fresh
    /// bind. Wipes the challenge and reply buffers (key-material hygiene).
    pub fn clearNetAuth(self: *Terminal) void {
        self.net_auth_on = false;
        self.net_auth_scheme = .open;
        self.net_authed = true;
        self.net_challenge_sent = false;
        self.net_auth_ticks = 0;
        self.net_reply_len = 0;
        self.net_reply_ready = false;
        self.net_post_len = 0;
        self.net_verdict = null;
        self.net_allow_on = false;
        self.net_allow_ip = .{ 0, 0, 0, 0 };
        @memset(&self.net_challenge, 0);
        @memset(&self.net_reply, 0);
        @memset(&self.net_post, 0);
    }

    /// #1082 (ADR 0020 Amendment A): attach this terminal to a `.user`
    /// window as its front-end. Exclusive per terminal (D2) and per window
    /// (A6): fails when another front-end is attached, or when another
    /// terminal already binds `window_id`. Idempotent for the same window.
    pub fn attachWindow(self: *Terminal, window_id: u8) bool {
        if (self.attached) {
            if (self.front_end == .window and self.window_id == window_id) return true;
            return false;
        }
        for (&terminals) |*o| {
            if (@intFromPtr(o) == @intFromPtr(self)) continue;
            if (o.in_use and o.attached and o.front_end == .window and o.window_id == window_id) return false;
        }
        self.attached = true;
        self.front_end = .window;
        self.window_id = window_id;
        return true;
    }

    /// #1083 (ADR 0020 Amendment B): attach this terminal to a TCP listener
    /// on `port`. Exclusive per terminal (D2) and — because the TCP seam is
    /// a single connection at a time (B2) — at most one terminal may hold
    /// the net front-end. Idempotent for the same port. The caller must have
    /// entered LISTEN first.
    pub fn attachNet(self: *Terminal, port: u16) bool {
        if (self.attached) {
            if (self.front_end == .net and self.net_port == port) return true;
            return false;
        }
        for (&terminals) |*o| {
            if (@intFromPtr(o) == @intFromPtr(self)) continue;
            if (o.in_use and o.attached and o.front_end == .net) return false;
        }
        self.attached = true;
        self.front_end = .net;
        self.net_port = port;
        return true;
    }

    /// M50 TS4 (#1138, ADR 0024 D6): attach the net front-end with the
    /// delegated challenge-response gate. `scheme` is what the pump frames
    /// in `VIRELAIOS-AUTH/1`; `.open` reproduces M46's accept-immediately
    /// behavior (the explicit insecure mode). A source-IP `allow_ip` is
    /// optional and unchanged from ADR 0022 D4.
    pub fn attachNetAuth(self: *Terminal, port: u16, scheme: NetAuthScheme, allow_ip: ?[4]u8) bool {
        if (!self.attachNet(port)) return false;
        self.clearNetAuth();
        if (scheme != .open) {
            self.net_auth_on = true;
            self.net_auth_scheme = scheme;
            self.net_authed = false; // the handshake must complete first
        }
        if (allow_ip) |ip| {
            self.net_allow_ip = ip;
            self.net_allow_on = true;
        }
        return true;
    }

    pub fn isAttached(self: *const Terminal) bool {
        return self.attached;
    }

    /// Drop all buffered bytes/counters and detach. Keeps `in_use`/owner.
    pub fn flush(self: *Terminal) void {
        self.out_start = 0;
        self.out_len = 0;
        self.out_dropped = 0;
        self.in_start = 0;
        self.in_len = 0;
        self.in_dropped = 0;
    }

    /// Full reset to a free slot (used by the registry on release/tests).
    pub fn reset(self: *Terminal) void {
        self.* = .{};
    }
};

// ---------------------------------------------------------------------------
// The kernel terminal registry (bounded; no allocation).
// ---------------------------------------------------------------------------

pub var terminals: [max_terminals]Terminal = [_]Terminal{.{}} ** max_terminals;

/// #1082 (ADR 0020 Amendment A): the per-terminal presentation grid,
/// parallel to `terminals` and keyed by the same registry handle. Kept out
/// of `Terminal` so the object stays a pure byte session (D1).
pub var screens: [max_terminals]Screen = [_]Screen{.{}} ** max_terminals;

/// Allocate a free terminal for `owner`, or null when all slots are taken.
pub fn create(owner: ?usize) ?usize {
    for (&terminals, 0..) |*t, i| {
        if (!t.in_use) {
            t.reset();
            t.in_use = true;
            t.owner_pid = owner;
            screens[i].reset();
            return i;
        }
    }
    return null;
}

/// The terminal at `handle`, or null when out of range / free.
pub fn get(handle: usize) ?*Terminal {
    if (handle >= max_terminals) return null;
    if (!terminals[handle].in_use) return null;
    return &terminals[handle];
}

/// Release a terminal slot (e.g. owner death). Clears everything.
pub fn release(handle: usize) void {
    if (handle >= max_terminals) return;
    terminals[handle].reset();
    screens[handle].reset();
}

/// The registry handle of `t`, or null when it is not a live slot.
fn handleOf(t: *const Terminal) ?usize {
    for (&terminals, 0..) |*x, i| {
        if (@intFromPtr(x) == @intFromPtr(t)) return i;
    }
    return null;
}

/// #1082 (A5): the terminal bound to the `.user` window `window_id`, or
/// null when the window is not a terminal front-end. `input.zig` uses this
/// to encode focused-window keys into the bound terminal's input queue.
pub fn windowTerminal(window_id: u8) ?*Terminal {
    for (&terminals) |*t| {
        if (t.in_use and t.attached and t.front_end == .window) {
            if (t.window_id) |wid| {
                if (wid == window_id) return t;
            }
        }
    }
    return null;
}

/// #1082 (A6): auto-detach any terminal bound to `window_id` (called by the
/// window close / owner-exit path). The terminal survives, buffered,
/// unattached; the serial console is NOT reclaimed.
pub fn detachWindow(window_id: u8) void {
    if (windowTerminal(window_id)) |t| t.detach();
}

/// True when any live terminal holds the window front-end (used by the
/// attach syscall to keep serial/window/net mutually exclusive, B2/A2).
pub fn anyWindowAttached() bool {
    for (&terminals) |*t| {
        if (t.in_use and t.attached and t.front_end == .window) return true;
    }
    return false;
}

/// #1082 (A4): drain terminal `handle`'s output ring into its presentation
/// grid. Returns bytes moved; a no-op when the terminal has no window
/// binding. The caller marks the bound window damaged (deferred present).
pub fn pumpWindowOutput(handle: usize) usize {
    const t = get(handle) orelse return 0;
    if (t.window_id == null) return 0;
    var total: usize = 0;
    var buf: [128]u8 = undefined;
    while (true) {
        const n = t.readOut(&buf);
        if (n == 0) break;
        screens[handle].feed(buf[0..n]);
        total += n;
    }
    return total;
}

/// #1630 (M73f-1): append `bytes` to a WINDOW-bound terminal without dropping.
/// The ring is 4 KiB and a TUI frame can be larger; the window path drains
/// into the grid as it writes, in chunks that always fit, so `out_dropped`
/// stays 0. Serial/net keep the drop-oldest ring policy (non-goal). Returns
/// bytes accepted (`bytes.len` when the handle is window-bound, else 0).
pub fn writeWindow(handle: usize, bytes: []const u8) usize {
    const t = get(handle) orelse return 0;
    if (t.window_id == null) return 0;
    var off: usize = 0;
    while (off < bytes.len) {
        const room = out_capacity - t.pendingOut();
        if (room == 0) {
            // Defensive: a leftover full ring must drain before we write.
            // If it cannot, return the prefix accepted rather than spin.
            if (pumpWindowOutput(handle) == 0) return off;
            continue;
        }
        const take = @min(room, bytes.len - off);
        _ = t.write(bytes[off..][0..take]);
        _ = pumpWindowOutput(handle);
        off += take;
    }
    return bytes.len;
}

/// #1082 (A4): the presentation grid bound to `window_id`, or null when the
/// window is not a terminal front-end. `driving_award.paint` renders it.
pub fn screenOf(window_id: u8) ?*const Screen {
    const t = windowTerminal(window_id) orelse return null;
    const h = handleOf(t) orelse return null;
    return &screens[h];
}

/// M49 SD5 (#1132): the mutable presentation grid bound to `window_id`.
pub fn screenForWindow(window_id: u8) ?*Screen {
    const t = windowTerminal(window_id) orelse return null;
    const h = handleOf(t) orelse return null;
    return &screens[h];
}

/// M49 SD5 (#1132): the mutable presentation grid for an already-resolved
/// window-bound terminal.
pub fn screenForTerminal(t: *Terminal) ?*Screen {
    const h = handleOf(t) orelse return null;
    return &screens[h];
}

/// M49 SD5 (#1132): sync the presentation grid to the window's current
/// client width, reflowing the stored lines when the column count changed.
/// Called by the compositor before rendering (never in IRQ context).
pub fn syncWindowCols(window_id: u8, pixel_w: u32) void {
    const s = screenForWindow(window_id) orelse return;
    _ = s.setCols(@intCast(pixel_w / 8));
}

/// M49 SD5 (#1132): copy the window terminal's selection into the shared
/// clipboard. Returns the bytes copied (0 when there is no selection).
pub fn copySelectionToClipboard(window_id: u8) usize {
    const s = screenForWindow(window_id) orelse return 0;
    var buf: [clipboard.capacity]u8 = undefined;
    const n = s.copySelection(&buf);
    if (n == 0) return 0;
    return clipboard.set(buf[0..n]);
}

/// M73e (#1629): Ctrl+Shift+V — push the clipboard into the bound
/// terminal's input queue, wrapped in `\e[200~ … \e[201~` when the app
/// enabled DECSET 2004 (the shell requests it at startup). Returns the
/// bytes accepted; `in_capacity` holds one full paste (512 B clipboard +
/// 12 B markers), and any overflow is the queue's drop-newest +
/// `in_dropped` — visible, never silent. Returns 0 when the window has no
/// terminal or the clipboard is empty.
pub fn pasteFromClipboard(window_id: u8) usize {
    const t = windowTerminal(window_id) orelse return 0;
    const s = screenForWindow(window_id) orelse return 0;
    var content: [clipboard.capacity]u8 = undefined;
    const n = clipboard.get(&content);
    if (n == 0) return 0;
    if (!s.bracketed_paste) return t.pushInput(content[0..n]);
    var buf: [clipboard.capacity + 12]u8 = undefined;
    @memcpy(buf[0..6], "\x1b[200~");
    @memcpy(buf[6..][0..n], content[0..n]);
    @memcpy(buf[6 + n ..][0..6], "\x1b[201~");
    return t.pushInput(buf[0 .. 6 + n + 6]);
}

// ---------------------------------------------------------------------------
// The net front-end pump (SH7 #1083, ADR 0020 Amendment B; M46 RC3 #1111,
// ADR 0022; M50 TS4 #1138, ADR 0024 D6). The kernel's TCP seam is a single
// bounded connection; the pump moves bytes between the net-bound terminal
// and that connection. Incoming segments are drained, a pending ACK/SYN-ACK
// is flushed, the received payload is delivered through the delegated
// challenge-response gate (the process's verdict), and (on the owner's
// `/dev/tty` write) the terminal output ring is chunked into TCP data
// segments. A peer FIN / dead connection / exhausted SYN-ACK accept
// auto-detaches the terminal (B4, #1105). The pump is driven from the
// `/dev/tty` syscall path.
//
// The transport is an injectable seam (`NetSeam`) so the byte movement is
// host-testable without a live NIC (#1105): the default seam drives
// virtio-net + the 1 Hz timer; tests inject a capture seam.
// ---------------------------------------------------------------------------

/// The net transport seam: `rxDrain` pulls pending frames from the device,
/// `tx` transmits one built frame, `now` is the accept-timeout clock. It is a
/// COMPTIME type parameter, not a runtime function-pointer table — a static
/// initializer holding code addresses is exactly the unrelocated link-time
/// pointer hazard the M33 sweep guards against (issue #1042). A host test
/// injects its own type with the same three functions.
pub const NetSeam = struct {
    pub fn rxDrain() void {
        virtio_net.net_rx_drain();
    }
    pub fn tx(bytes: []const u8) bool {
        var out_len: usize = 0;
        return virtio_net.net_tcp_send(bytes, &out_len) == .ok;
    }
    pub fn now() u64 {
        return timer.ticks;
    }
};

/// The terminal currently attached to the net front-end, if any (at most
/// one — the TCP seam is a single connection at a time).
pub fn attachedNet() ?*Terminal {
    for (&terminals) |*t| {
        if (t.in_use and t.attached and t.front_end == .net) return t;
    }
    return null;
}

/// M50 TS4 (#1138): the deterministic-challenge hook for pinned-vector host
/// tests. Production never sets it; `mintChallenge` uses the kernel CSPRNG.
pub var test_challenge: ?[net_challenge_len]u8 = null;

/// Mint a fresh 32-byte challenge (CSPRNG, or the test override).
fn mintChallenge(out: *[net_challenge_len]u8) void {
    if (test_challenge) |c| {
        out.* = c;
        return;
    }
    csprng.random_bytes(out);
}

const hex_digits = "0123456789abcdef";

/// Append the lowercase hex of `bytes` to `out`; returns the characters
/// written (a short `out` truncates — callers size it for the full form).
fn appendHex(out: []u8, bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |b| {
        if (n + 2 > out.len) break;
        out[n] = hex_digits[b >> 4];
        out[n + 1] = hex_digits[b & 0xf];
        n += 2;
    }
    return n;
}

/// True when every byte is a hex digit (either case).
fn isHex(bytes: []const u8) bool {
    for (bytes) |b| {
        const ok = (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F');
        if (!ok) return false;
    }
    return true;
}

/// Transmit `auth failed`, end the session, and detach — the one failed-door
/// path shared by a wrong/malformed reply, a reject verdict, and the
/// deadline. Pre-auth bytes are never delivered by this path.
fn netAuthFailSeam(t: *Terminal, comptime seam: type) void {
    _ = netTx(seam, "auth failed\n");
    klog.line("tty net: auth failed\n");
    tcp.reset();
    t.detach();
}

/// Production-seam wrapper (used by the slot-71 verdict handler).
pub fn netAuthFail(t: *Terminal) void {
    netAuthFailSeam(t, NetSeam);
}

/// Send the `VIRELAIOS-AUTH/1 <scheme> <hex-challenge>\n` line once, when
/// the connection is ESTABLISHED. Stamps the 10 s deadline clock. Returns
/// whether the challenge was sent (or already sent).
pub fn netAuthSendChallengeSeam(t: *Terminal, comptime seam: type) bool {
    if (t.net_challenge_sent) return true;
    if (!t.net_auth_on or t.net_auth_scheme == .open) return false;
    mintChallenge(&t.net_challenge);
    var line: [tcp.payload_max]u8 = undefined;
    var n: usize = 0;
    @memcpy(line[n..][0..net_auth_tag.len], net_auth_tag);
    n += net_auth_tag.len;
    line[n] = ' ';
    n += 1;
    const sname = t.net_auth_scheme.name();
    @memcpy(line[n..][0..sname.len], sname);
    n += sname.len;
    line[n] = ' ';
    n += 1;
    n += appendHex(line[n..], &t.net_challenge);
    line[n] = '\n';
    n += 1;
    if (!netTx(seam, line[0..n])) return false;
    t.net_challenge_sent = true;
    t.net_auth_ticks = seam.now();
    return true;
}

/// Production-seam wrapper (the pump uses the injected seam directly).
pub fn netAuthSendChallenge(t: *Terminal) bool {
    return netAuthSendChallengeSeam(t, NetSeam);
}

/// Hold pipelined post-reply bytes until the verdict (bounded by
/// `tcp.payload_max`; overflow is an honest failed connection).
fn netAuthAppendPost(t: *Terminal, comptime seam: type, bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    if (t.net_post_len + bytes.len > t.net_post.len) {
        netAuthFailSeam(t, seam);
        return 0;
    }
    @memcpy(t.net_post[t.net_post_len..][0..bytes.len], bytes);
    t.net_post_len += bytes.len;
    return 0;
}

/// Buffer one received payload through the delegated auth gate (ADR 0024
/// D6). Pre-auth bytes go to the bounded reply line (or the pipelined-post
/// buffer) and NEVER to the terminal input queue. A complete reply line is
/// length- and hex-validated immediately; malformed/over-long is a failed
/// connection. A valid reply waits for the process's verdict. Once
/// `net_authed`, every byte flows to the input queue. Returns bytes
/// delivered to the terminal (0 while the handshake is pending).
fn netAuthConsume(t: *Terminal, comptime seam: type, bytes: []const u8) usize {
    const delivered: usize = 0;
    if (t.net_authed) {
        return t.pushInput(bytes);
    }
    // Already have a reply: only pipeline post bytes (the client may send
    // its first command without waiting for the accept marker).
    if (t.net_reply_ready) {
        _ = netAuthAppendPost(t, seam, bytes);
        return 0;
    }
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        i += 1;
        if (b == '\n' or b == '\r') {
            if (b == '\r' and i < bytes.len and bytes[i] == '\n') i += 1; // CRLF
            const want = t.net_auth_scheme.expectedReplyLen();
            if (t.net_reply_len != want or !isHex(t.net_reply[0..t.net_reply_len])) {
                netAuthFailSeam(t, seam);
                return delivered;
            }
            t.net_reply_ready = true;
            return delivered + netAuthAppendPost(t, seam, bytes[i..]);
        }
        if (t.net_reply_len < net_auth_line_max) {
            t.net_reply[t.net_reply_len] = b;
            t.net_reply_len += 1;
        } else {
            // Over-long line: reject honestly (bounded buffer).
            netAuthFailSeam(t, seam);
            return delivered;
        }
    }
    return delivered;
}

/// Apply the attached process's verdict for the buffered reply (slot 71
/// op = verdict). Accept opens the byte gate and delivers any pipelined
/// post-auth bytes; reject is the same failed connection as a malformed
/// line. Returns false when there is no reply awaiting a verdict.
pub fn netAuthVerdictSeam(t: *Terminal, accept: bool, comptime seam: type) bool {
    if (!t.net_auth_on or t.net_authed or !t.net_reply_ready or t.net_verdict != null) return false;
    t.net_verdict = accept;
    if (!accept) {
        netAuthFailSeam(t, seam);
        return true;
    }
    t.net_authed = true;
    t.net_reply_ready = false;
    const n = t.net_post_len;
    if (n > 0) {
        _ = t.pushInput(t.net_post[0..n]);
        t.net_post_len = 0;
    }
    // Key-material hygiene: the challenge and the reply (a MAC/signature)
    // are never needed again.
    t.net_reply_len = 0;
    @memset(&t.net_reply, 0);
    @memset(&t.net_challenge, 0);
    return true;
}

/// Production-seam wrapper (the slot-71 handler).
pub fn netAuthVerdict(t: *Terminal, accept: bool) bool {
    return netAuthVerdictSeam(t, accept, NetSeam);
}

/// Build + transmit one raw TCP data segment, advancing the send state.
/// Returns whether the transport accepted it.
fn netTx(comptime seam: type, bytes: []const u8) bool {
    tcp.build_data_msg(bytes);
    if (!seam.tx(tcp.msg[0..tcp.msg_len])) return false;
    tcp.data_sent += 1;
    tcp.advance_snd(bytes.len);
    tcp.record_pending();
    return true;
}

/// Pump TCP bytes into the net-attached terminal's input queue: drain the
/// device RX, flush any built ACK/SYN-ACK, deliver a received payload through
/// the auth gate, enforce the half-open accept timeout (#1105), and
/// auto-detach on a peer FIN / dead connection. Returns bytes delivered.
pub fn pumpNetInput() usize {
    return pumpNetInputSeam(NetSeam);
}

pub fn pumpNetInputSeam(comptime seam: type) usize {
    const t = attachedNet() orelse return 0;
    seam.rxDrain();
    tcp.now_ticks = seam.now(); // the #1105 accept-timeout clock
    if (tcp.ack_pending) {
        if (seam.tx(tcp.msg[0..tcp.msg_len])) {
            tcp.ack_pending = false;
            tcp.ack_sent += 1;
        }
    }
    var total: usize = 0;
    if (tcp.rx_pending) {
        total += netAuthConsume(t, seam, tcp.take_rx());
    }
    // #1105: a half-open accept (a SYN whose ACK never arrives) is ended after
    // a bounded timeout instead of stranding the terminal in `.syn_received`.
    // A dedicated accept clock (not the client RTO) so the front-end never
    // retransmits and only ever TXes from the owner's read/write path.
    if (tcp.state == .syn_received and
        tcp.now_ticks -| tcp.accept_ticks >= tcp.accept_timeout)
    {
        klog.line("tty net: accept timeout\n");
        tcp.reset();
        t.detach();
        return total;
    }
    // M50 TS4 (#1138, ADR 0024 D6): the delegated handshake. Once the
    // connection is ESTABLISHED, mint + send the fresh challenge (never
    // before establishment), then enforce the 10 s deadline: no process
    // verdict in time is the same failed connection as a bad reply.
    if (t.net_auth_on and !t.net_authed) {
        if (tcp.state == .established and !tcp.peer_fin) {
            _ = netAuthSendChallengeSeam(t, seam);
        }
        if (t.net_challenge_sent and
            tcp.now_ticks -| t.net_auth_ticks >= net_auth_deadline)
        {
            klog.line("tty net: auth deadline\n");
            netAuthFailSeam(t, seam);
            return total;
        }
    }
    // Once the connection is up, flush anything the shell wrote before the
    // handshake completed (the initial prompt).
    if (tcp.state == .established and !tcp.peer_fin) _ = pumpNetOutputSeam(NetCapture);
    if (tcp.peer_fin or tcp.state == .closed) {
        // The peer disconnected (or the connection died): end the session,
        // release the listener, and leave the terminal buffered/unattached.
        tcp.reset();
        t.detach();
        klog.line("tty net: detached\n");
    }
    return total;
}

/// Drain the net-attached terminal's output ring into TCP data segments
/// (chunked to the stack's `payload_max`). A no-op unless the connection is
/// ESTABLISHED and authenticated (output is never leaked before auth).
/// Returns bytes sent.
pub fn pumpNetOutput() usize {
    return pumpNetOutputSeam(NetSeam);
}

pub fn pumpNetOutputSeam(comptime seam: type) usize {
    const t = attachedNet() orelse return 0;
    if (!t.net_authed) return 0; // never leak output before auth
    if (tcp.state != .established) return 0;
    var total: usize = 0;
    var buf: [tcp.payload_max]u8 = undefined;
    while (true) {
        const n = t.readOut(&buf);
        if (n == 0) break;
        if (!netTx(seam, buf[0..n])) break;
        total += n;
    }
    return total;
}

// ---------------------------------------------------------------------------
// The serial front-end pump (ADR 0020 D2/D4). The kernel console is a
// front-end like any other: input bytes it reads are pushed into the
// attached terminal, and the terminal's output ring is drained back to it.
// The pump is driven from the syscall path (a process reading/writing its
// `/dev/tty`), so no idle-loop integration is needed — the console's RX
// FIFO buffers keys until the next read. Boot default is unchanged because
// nothing is attached until a process asks (ADR 0020 D4).
// ---------------------------------------------------------------------------

/// The kernel console used as the `.serial` front-end, set once at boot.
pub var runtime_console: ?console.Console = null;

pub fn setRuntimeConsole(con: console.Console) void {
    runtime_console = con;
}

/// The terminal currently attached to the serial console front-end, if any.
pub fn attachedSerial() ?*Terminal {
    for (&terminals) |*t| {
        if (t.in_use and t.attached and t.front_end == .serial) return t;
    }
    return null;
}

/// Drain the console's pending input into the serial-attached terminal.
/// Pure w.r.t. the terminal object (the console is the side effect). Returns
/// bytes moved. A no-op with no serial-attached terminal.
pub fn pumpInput(con: console.Console) usize {
    const t = attachedSerial() orelse return 0;
    var total: usize = 0;
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    while (con.readByte()) |b| {
        buf[n] = b;
        n += 1;
        if (n == buf.len) {
            total += t.pushInput(buf[0..n]);
            n = 0;
        }
    }
    if (n > 0) total += t.pushInput(buf[0..n]);
    return total;
}

/// Drain the serial-attached terminal's output ring to the console. A no-op
/// with no serial-attached terminal. Returns bytes moved.
pub fn pumpOutput(con: console.Console) usize {
    const t = attachedSerial() orelse return 0;
    var total: usize = 0;
    var buf: [128]u8 = undefined;
    while (true) {
        const n = t.readOut(&buf);
        if (n == 0) break;
        con.write(buf[0..n]);
        total += n;
    }
    if (total > 0) con.flush();
    return total;
}

/// Pump the runtime console (no-op before `setRuntimeConsole` / with no
/// serial-attached terminal). Used by the `/dev/tty` read path.
pub fn pumpRuntimeInput() usize {
    const con = runtime_console orelse return 0;
    return pumpInput(con);
}

/// Pump the runtime console out. Used by the `/dev/tty` write path.
pub fn pumpRuntimeOutput() usize {
    const con = runtime_console orelse return 0;
    return pumpOutput(con);
}

// ---------------------------------------------------------------------------
// Tests (pure; no hardware)
// ---------------------------------------------------------------------------

test "terminal: output round-trips FIFO from owner to front-end" {
    var t = Terminal{};
    try std.testing.expectEqual(@as(usize, 5), t.write("hello"));
    try std.testing.expectEqual(@as(usize, 5), t.pendingOut());
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), t.readOut(&buf));
    try std.testing.expectEqualStrings("hello", buf[0..5]);
    try std.testing.expectEqual(@as(usize, 0), t.pendingOut());
    // Draining an empty ring is a no-op.
    try std.testing.expectEqual(@as(usize, 0), t.readOut(&buf));
}

test "terminal: output ring wraps and preserves order across fill/drain cycles" {
    var t = Terminal{};
    var big: [out_capacity]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i);
    try std.testing.expectEqual(out_capacity, t.write(&big));
    // Drain the first half, refill, then read everything back in order.
    var half: [out_capacity]u8 = undefined;
    try std.testing.expectEqual(out_capacity / 2, t.readOut(half[0 .. out_capacity / 2]));
    try std.testing.expectEqualStrings(big[0 .. out_capacity / 2], half[0 .. out_capacity / 2]);
    const more = "XYZ";
    _ = t.write(more);
    var rest: [out_capacity + 4]u8 = undefined;
    const n = t.readOut(&rest);
    try std.testing.expectEqual(out_capacity / 2 + more.len, n);
    // The tail of the original fill, then the appended bytes.
    try std.testing.expectEqualSlices(u8, big[out_capacity / 2 ..], rest[0 .. out_capacity / 2]);
    try std.testing.expectEqualStrings(more, rest[out_capacity / 2 .. n]);
}

test "terminal: output overflow drops the OLDEST byte and counts it" {
    // Serial/net still drop-oldest (M73f-1 non-goal). The window path's
    // polarity lives in "a window write larger than the ring cannot drop".
    var t = Terminal{};
    var big: [out_capacity + 10]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i);
    _ = t.write(&big);
    try std.testing.expectEqual(@as(u64, 10), t.out_dropped);
    // The surviving window is the LAST out_capacity bytes.
    var buf: [out_capacity]u8 = undefined;
    try std.testing.expectEqual(out_capacity, t.readOut(&buf));
    try std.testing.expectEqualSlices(u8, big[10..], &buf);
}

test "terminal: input round-trips FIFO from front-end to owner" {
    var t = Terminal{};
    try std.testing.expectEqual(@as(usize, 3), t.pushInput("abc"));
    try std.testing.expectEqual(@as(usize, 3), t.pendingInput());
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), t.readInput(&buf));
    try std.testing.expectEqualStrings("abc", buf[0..3]);
    try std.testing.expectEqual(@as(usize, 0), t.pendingInput());
}

test "terminal: input overflow drops the NEWEST byte (never evicts unread keys)" {
    var t = Terminal{};
    var big: [in_capacity]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i);
    try std.testing.expectEqual(in_capacity, t.pushInput(&big));
    // One over capacity: the new byte is refused, the queue is untouched.
    try std.testing.expectEqual(@as(usize, 0), t.pushInput("Z"));
    try std.testing.expectEqual(@as(u64, 1), t.in_dropped);
    try std.testing.expectEqual(in_capacity, t.pendingInput());
    var buf: [in_capacity]u8 = undefined;
    try std.testing.expectEqual(in_capacity, t.readInput(&buf));
    try std.testing.expectEqualSlices(u8, &big, &buf);
}

test "terminal: front-end attach is exclusive and detach re-opens it" {
    var t = Terminal{};
    try std.testing.expect(!t.isAttached());
    try std.testing.expect(t.attach(.serial));
    try std.testing.expect(t.isAttached());
    try std.testing.expectEqual(FrontEnd.serial, t.front_end);
    // A second, different front-end is refused while attached.
    try std.testing.expect(!t.attach(.window));
    try std.testing.expectEqual(FrontEnd.serial, t.front_end);
    // Re-attach by the same front-end is idempotent.
    try std.testing.expect(t.attach(.serial));
    // `.none` is never a valid attach.
    t.detach();
    try std.testing.expect(!t.isAttached());
    try std.testing.expect(!t.attach(.none));
    // Now the window can take it.
    try std.testing.expect(t.attach(.window));
}

test "terminal: flush clears buffers and counters without detaching the owner" {
    var t = Terminal{};
    _ = t.write("out");
    _ = t.pushInput("in");
    t.attached = true;
    t.front_end = .serial;
    t.flush();
    try std.testing.expectEqual(@as(usize, 0), t.pendingOut());
    try std.testing.expectEqual(@as(usize, 0), t.pendingInput());
    try std.testing.expectEqual(@as(u64, 0), t.out_dropped);
    try std.testing.expectEqual(@as(u64, 0), t.in_dropped);
    try std.testing.expect(t.isAttached());
}

test "terminal: registry creates, looks up, and releases bounded slots" {
    for (&terminals) |*t| t.reset();
    const a = create(7) orelse return error.TestUnexpectedResult;
    const b = create(8) orelse return error.TestUnexpectedResult;
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(?usize, 7), get(a).?.owner_pid);
    try std.testing.expectEqual(@as(?usize, 8), get(b).?.owner_pid);
    // Fill the rest; overflow is an honest null.
    var made: usize = 2;
    while (made < max_terminals) : (made += 1) {
        _ = create(null) orelse return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(?usize, null), create(null));
    // Release frees a slot; the freed handle is a fresh empty terminal.
    release(a);
    try std.testing.expectEqual(@as(?*Terminal, null), get(a));
    const c = create(9) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?usize, 9), get(c).?.owner_pid);
    for (&terminals) |*t| t.reset();
}

test "terminal: serial pump round-trips console input/output through an attached terminal" {
    for (&terminals) |*t| t.reset();
    var mock = console.MockConsole(256){};
    const con = mock.console();

    // No attachment: the pump is a no-op (boot default unchanged).
    mock.feed("abc");
    try std.testing.expectEqual(@as(usize, 0), pumpInput(con));
    try std.testing.expectEqual(@as(usize, 0), pumpOutput(con));

    // Attach a terminal to the serial front-end.
    const h = create(5) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attach(.serial));
    try std.testing.expect(attachedSerial() != null and attachedSerial().? == t);

    // Console RX flows into the terminal's input queue.
    try std.testing.expectEqual(@as(usize, 3), pumpInput(con));
    var in: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), t.readInput(&in));
    try std.testing.expectEqualStrings("abc", in[0..3]);

    // Terminal output flows out to the console (front-end drain).
    _ = t.write("hello");
    try std.testing.expectEqual(@as(usize, 5), pumpOutput(con));
    try std.testing.expectEqualStrings("hello", mock.contents());

    // Detach stops the pump entirely.
    t.detach();
    try std.testing.expect(attachedSerial() == null);
    mock.feed("x");
    try std.testing.expectEqual(@as(usize, 0), pumpInput(con));
    try std.testing.expectEqual(@as(usize, 0), pumpOutput(con));
    for (&terminals) |*tt| tt.reset();
}

test "terminal: screen lays out CR/LF/BS/TAB and wraps at the column bound" {
    var s = Screen{};
    s.feed("abc\r\nx");
    try std.testing.expectEqual(@as(usize, 2), s.lineCount());
    try std.testing.expectEqualStrings("abc", s.line(0));
    try std.testing.expectEqualStrings("x", s.line(1));
    try std.testing.expectEqual(@as(usize, 1), s.cursorCol());
    // Backspace erases the cursor's column (no glyph invented).
    s.feed("\x08y");
    try std.testing.expectEqualStrings("y", s.line(1));
    // TAB advances to the next multiple of 8.
    s.feed("\tz");
    try std.testing.expectEqual(@as(usize, 9), s.cursorCol());
    try std.testing.expectEqualStrings("y       z", s.line(1));
    // A line longer than the grid wraps instead of overrunning.
    var long: [grid_cols + 3]u8 = undefined;
    @memset(&long, 'a');
    s.feed(&long);
    try std.testing.expectEqual(@as(usize, 3), s.lineCount());
    try std.testing.expectEqual(@as(usize, grid_cols), s.line(1).len);
    try std.testing.expectEqual(@as(usize, 12), s.line(2).len);
}

test "terminal: screen scrolls past the line bound and clears on CSI 2J" {
    var s = Screen{};
    var i: usize = 0;
    while (i < grid_lines + 5) : (i += 1) {
        s.feed("L\n");
    }
    // The buffer is full and the oldest lines were dropped.
    try std.testing.expectEqual(@as(usize, grid_lines), s.lineCount());
    // `ESC [ 2 J` clears the screen back to one empty line.
    s.feed("\x1b[2J\x1b[Hx");
    try std.testing.expectEqual(@as(usize, 1), s.lineCount());
    try std.testing.expectEqualStrings("x", s.line(0));
}

test "terminal: CSI SGR and CUP preserve per-cell attributes" {
    var s = Screen{};
    // A Bubble-Tea-shaped paint burst: clear, position, set SGR, paint, reset.
    s.feed("\x1b[2J\x1b[3;4H\x1b[31mR\x1b[1;44;97mB\x1b[0mN");
    try std.testing.expectEqualStrings("   RBN", s.line(2));
    try std.testing.expectEqual(@as(usize, 2), s.cursorLine());
    try std.testing.expectEqual(@as(usize, 6), s.cursorCol());

    const red = s.styleAt(2, 3);
    try std.testing.expectEqual(@as(?u8, 1), styleForeground(red));
    try std.testing.expectEqual(@as(?u8, null), styleBackground(red));
    try std.testing.expect(!styleBold(red));

    const bright = s.styleAt(2, 4);
    try std.testing.expectEqual(@as(?u8, 15), styleForeground(bright));
    try std.testing.expectEqual(@as(?u8, 4), styleBackground(bright));
    try std.testing.expect(styleBold(bright));

    const reset = s.styleAt(2, 5);
    try std.testing.expectEqual(@as(?u8, null), styleForeground(reset));
    try std.testing.expectEqual(@as(?u8, null), styleBackground(reset));
    try std.testing.expect(!styleBold(reset));
}

test "terminal: CSI EL and ED erase only their declared regions" {
    var s = Screen{};
    s.feed("abcdef\x1b[1;4H\x1b[K");
    try std.testing.expectEqualStrings("abc", s.line(0));

    s.feed("\x1b[2Jkeep");
    try std.testing.expectEqual(@as(usize, 1), s.lineCount());
    try std.testing.expectEqualStrings("keep", s.line(0));

    s.feed("\x1b[1;3H\x1b[1J");
    try std.testing.expectEqualStrings("   p", s.line(0));
}

test "terminal: alternate screen restores the primary grid and DECTCEM hides the cursor" {
    var s = Screen{};
    s.feed("primary");
    s.feed("\x1b[?1049halt\x1b[?25l");
    try std.testing.expect(s.alt_active);
    try std.testing.expectEqualStrings("alt", s.line(0));
    try std.testing.expect(!s.cursor_visible);

    s.feed("\x1b[?1049l");
    try std.testing.expect(!s.alt_active);
    try std.testing.expectEqualStrings("primary", s.line(0));
    s.feed("\x1b[?25h");
    try std.testing.expect(s.cursor_visible);
}

test "terminal: unsupported CSI is swallowed rather than painted" {
    var s = Screen{};
    s.feed("before\x1b[999zafter");
    try std.testing.expectEqualStrings("beforeafter", s.line(0));
}

// M73e (#1629): DECSET 2004 state, the bracketed wrap, and the queue
// contract a full clipboard paste needs.
test "terminal: DECSET/DECRST 2004 tracks bracketed paste mode" {
    var s = Screen{};
    try std.testing.expect(!s.bracketed_paste);
    s.feed("ok\x1b[?2004h");
    try std.testing.expect(s.bracketed_paste);
    try std.testing.expectEqualStrings("ok", s.line(0));
    s.feed("\x1b[?2004l");
    try std.testing.expect(!s.bracketed_paste);
    // Mode bits survive an alternate-screen round trip (like DECTCEM).
    s.feed("\x1b[?2004h\x1b[?1049h\x1b[?1049l");
    try std.testing.expect(s.bracketed_paste);
}

test "terminal: pasteFromClipboard wraps per mode and lands intact (#1629)" {
    for (&terminals) |*t| t.reset();
    const payload = "LINE-00 pppp\nLINE-29 pppp";
    _ = clipboard.set(payload);
    const h = create(7) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attachWindow(7));
    // Bracketed OFF: raw content, newline included.
    screenForWindow(7).?.bracketed_paste = false;
    try std.testing.expectEqual(payload.len, pasteFromClipboard(7));
    var buf: [96]u8 = undefined;
    try std.testing.expectEqual(payload.len, t.readInput(&buf));
    try std.testing.expectEqualStrings(payload, buf[0..payload.len]);
    // Bracketed ON: markers around the same bytes.
    screenForWindow(7).?.feed("\x1b[?2004h");
    _ = pasteFromClipboard(7);
    const m = t.readInput(&buf);
    const wrapped = "\x1b[200~" ++ payload ++ "\x1b[201~";
    try std.testing.expectEqual(wrapped.len, m);
    try std.testing.expectEqualStrings(wrapped, buf[0..m]);
}

test "terminal: a full-clipboard paste exceeds the old 256 B queue, dropping nothing (#1629)" {
    var t = Terminal{};
    var content: [clipboard.capacity]u8 = undefined;
    @memset(&content, 'x');
    var wrap: [clipboard.capacity + 12]u8 = undefined;
    @memcpy(wrap[0..6], "\x1b[200~");
    @memcpy(wrap[6..][0..clipboard.capacity], &content);
    @memcpy(wrap[6 + clipboard.capacity ..][0..6], "\x1b[201~");
    try std.testing.expectEqual(clipboard.capacity + 12, t.pushInput(&wrap));
    try std.testing.expectEqual(@as(u64, 0), t.in_dropped);
    try std.testing.expectEqual(clipboard.capacity + 12, t.pendingInput());
    var buf: [clipboard.capacity + 16]u8 = undefined;
    try std.testing.expectEqual(clipboard.capacity + 12, t.readInput(&buf));
    try std.testing.expectEqualStrings(&wrap, buf[0 .. clipboard.capacity + 12]);
}

test "terminal: window binding is exclusive per terminal and per window" {
    for (&terminals) |*t| t.reset();
    const a = create(1) orelse return error.TestUnexpectedResult;
    const b = create(2) orelse return error.TestUnexpectedResult;
    const ta = get(a).?;
    const tb = get(b).?;
    try std.testing.expect(ta.attachWindow(2));
    try std.testing.expectEqual(@as(?u8, 2), ta.window_id);
    try std.testing.expect(windowTerminal(2) == ta);
    // Another terminal may not bind the same window.
    try std.testing.expect(!tb.attachWindow(2));
    // The same terminal may not bind a second window (front-end exclusive).
    try std.testing.expect(!ta.attachWindow(3));
    // Idempotent re-attach of the same window succeeds.
    try std.testing.expect(ta.attachWindow(2));
    // A different window on a free terminal succeeds.
    try std.testing.expect(tb.attachWindow(3));
    try std.testing.expect(windowTerminal(3) == tb);
    // Detach frees the binding for both lookups.
    detachWindow(2);
    try std.testing.expect(windowTerminal(2) == null);
    try std.testing.expect(!ta.isAttached());
    for (&terminals) |*t| t.reset();
}

test "terminal: window pump drains the output ring into the grid and screenOf finds it" {
    for (&terminals) |*t| t.reset();
    const h = create(3) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attachWindow(7));
    _ = t.write("hi\nthere");
    try std.testing.expectEqual(@as(usize, 8), pumpWindowOutput(h));
    const scr = screenOf(7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hi", scr.line(0));
    try std.testing.expectEqualStrings("there", scr.line(1));
    // A second pump with an empty ring moves nothing (idempotent).
    try std.testing.expectEqual(@as(usize, 0), pumpWindowOutput(h));
    // An unbound handle pumps nothing.
    const h2 = create(4) orelse return error.TestUnexpectedResult;
    _ = get(h2).?.write("x");
    try std.testing.expectEqual(@as(usize, 0), pumpWindowOutput(h2));
    try std.testing.expect(screenOf(99) == null);
    for (&terminals) |*tt| tt.reset();
    for (&screens) |*ss| ss.reset();
}

test "terminal: a window write larger than the ring cannot drop (M73f-1)" {
    for (&terminals) |*tt| tt.reset();
    for (&screens) |*ss| ss.reset();
    const h = create(3) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attachWindow(7));

    // Distinctive head and tail around a payload bigger than the 4 KiB ring.
    const extra = 64;
    var big: [out_capacity + extra]u8 = undefined;
    @memcpy(big[0..4], "HEAD");
    for (big[4 .. big.len - 4], 0..) |*b, i| b.* = 'A' + @as(u8, @intCast(i % 26));
    @memcpy(big[big.len - 4 ..], "TAIL");

    try std.testing.expectEqual(big.len, writeWindow(h, &big));
    try std.testing.expectEqual(@as(u64, 0), t.out_dropped);
    try std.testing.expectEqual(@as(usize, 0), t.pendingOut());

    const scr = screenOf(7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("HEAD", scr.line(0)[0..4]);
    const last_off = big.len - 4;
    const last_line = last_off / grid_cols;
    const last_col = last_off % grid_cols;
    try std.testing.expectEqual(@as(u21, 'T'), scr.cellAt(last_line, last_col).base);
    try std.testing.expectEqual(@as(u21, 'A'), scr.cellAt(last_line, last_col + 1).base);
    try std.testing.expectEqual(@as(u21, 'I'), scr.cellAt(last_line, last_col + 2).base);
    try std.testing.expectEqual(@as(u21, 'L'), scr.cellAt(last_line, last_col + 3).base);

    // An unbound handle does not consume (serial/net keep Terminal.write).
    const h2 = create(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), writeWindow(h2, "nope"));
    try std.testing.expectEqual(@as(usize, 0), get(h2).?.pendingOut());

    for (&terminals) |*tt| tt.reset();
    for (&screens) |*ss| ss.reset();
}

test "terminal: net binding is exclusive and single-session (SH7 B2)" {
    for (&terminals) |*tt| tt.reset();
    const a = create(1) orelse return error.TestUnexpectedResult;
    const b = create(2) orelse return error.TestUnexpectedResult;
    const ta = get(a).?;
    const tb = get(b).?;
    try std.testing.expect(ta.attachNet(2323));
    try std.testing.expectEqual(FrontEnd.net, ta.front_end);
    try std.testing.expectEqual(@as(u16, 2323), ta.net_port);
    try std.testing.expect(attachedNet() == ta);
    // A second terminal may not hold the net front-end (one TCP connection).
    try std.testing.expect(!tb.attachNet(4242));
    try std.testing.expect(attachedNet() == ta);
    // A net terminal may not take a window (front-end exclusive).
    try std.testing.expect(!ta.attachWindow(5));
    // Idempotent re-attach of the same port succeeds.
    try std.testing.expect(ta.attachNet(2323));
    // Detach frees the single net slot.
    ta.detach();
    try std.testing.expect(attachedNet() == null);
    try std.testing.expectEqual(@as(u16, 0), ta.net_port);
    try std.testing.expect(tb.attachNet(4242));
    for (&terminals) |*tt| tt.reset();
}

// M46 RC3 (#1111) / #1105: the net pump is host-testable through an injected
// seam. These fixtures drive the auth gate and byte movement with no NIC.
const NetCapture = struct {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    var clock: u64 = 0;
    fn clear() void {
        len = 0;
    }
    pub fn rxDrain() void {}
    pub fn tx(bytes: []const u8) bool {
        if (len + bytes.len > buf.len) return false;
        @memcpy(buf[len..][0..bytes.len], bytes);
        len += bytes.len;
        return true;
    }
    pub fn now() u64 {
        return clock;
    }
};

fn netTestSetRx(bytes: []const u8) void {
    @memcpy(tcp.rx_payload[0..bytes.len], bytes);
    tcp.rx_len = bytes.len;
    tcp.rx_pending = true;
}

fn netTestSent(needle: []const u8) bool {
    return std.mem.indexOf(u8, NetCapture.buf[0..NetCapture.len], needle) != null;
}

fn netTestEstablish(port: u16) void {
    tcp.reset();
    tcp.listen(port);
    tcp.state = .established;
}

test "terminal: net pump mints a fresh challenge and gates delivery on the verdict (TS4)" {
    for (&terminals) |*tt| tt.reset();
    tcp.reset();
    defer tcp.reset();
    defer test_challenge = null;
    NetCapture.clock = 0;
    NetCapture.clear();

    // (1) The challenge is minted + framed on establishment: pre-auth output
    // is withheld and nothing reaches the shell.
    const h1 = create(3) orelse return error.TestUnexpectedResult;
    const t1 = get(h1).?;
    try std.testing.expect(t1.attachNetAuth(2323, .hmac_sha256, null));
    try std.testing.expect(!t1.net_authed);
    try std.testing.expect(!t1.net_challenge_sent);
    var fixed: [net_challenge_len]u8 = undefined;
    for (&fixed, 0..) |*b, i| b.* = @intCast(i);
    test_challenge = fixed;
    netTestEstablish(2323);
    _ = t1.write("prompt> ");
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(t1.net_challenge_sent);
    try std.testing.expect(netTestSent("VIRELAIOS-AUTH/1 hmac-sha256 "));
    // The exact 32-byte challenge hex (000102...1f) + newline.
    try std.testing.expect(netTestSent("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n"));
    try std.testing.expect(!netTestSent("prompt> ")); // output withheld pre-verdict
    try std.testing.expectEqual(@as(usize, 0), t1.pendingInput());

    // (2) A malformed (non-hex) reply is the failed connection: `auth failed`
    // + reset + detach, and NO byte reached the shell.
    NetCapture.clear();
    netTestSetRx("zz\n");
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(attachedNet() == null);
    try std.testing.expect(netTestSent("auth failed"));
    try std.testing.expectEqual(@as(usize, 0), t1.pendingInput());
    release(h1);

    // (3) A fresh accept mints a NEW challenge (the CSPRNG stream advances,
    // never a reused nonce): a captured handshake cannot answer it. No test
    // override here, so the mint path runs.
    test_challenge = null;
    NetCapture.clear();
    const h2 = create(4) orelse return error.TestUnexpectedResult;
    const t2 = get(h2).?;
    try std.testing.expect(t2.attachNetAuth(2323, .hmac_sha256, null));
    netTestEstablish(2323);
    _ = pumpNetInputSeam(NetCapture);
    var first: [net_challenge_len]u8 = undefined;
    @memcpy(&first, &t2.net_challenge);
    release(h2);
    tcp.reset();
    NetCapture.clear();
    const h2b = create(5) orelse return error.TestUnexpectedResult;
    const t2b = get(h2b).?;
    try std.testing.expect(t2b.attachNetAuth(2323, .hmac_sha256, null));
    netTestEstablish(2323);
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(!std.mem.eql(u8, &first, &t2b.net_challenge));
    release(h2b);

    // (4) A well-formed reply + an accept verdict delivers the pipelined
    // command and opens the output gate.
    NetCapture.clear();
    tcp.reset();
    const h3 = create(6) orelse return error.TestUnexpectedResult;
    const t3 = get(h3).?;
    try std.testing.expect(t3.attachNetAuth(2323, .hmac_sha256, null));
    netTestEstablish(2323);
    _ = t3.write("prompt> ");
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(!netTestSent("prompt> "));
    const mac_hex = "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf" ++
        "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf";
    netTestSetRx(mac_hex ++ "\r\nhelp\n");
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(t3.net_reply_ready); // awaiting the process verdict
    try std.testing.expect(!t3.net_authed);
    try std.testing.expectEqual(@as(usize, 0), t3.pendingInput());
    try std.testing.expectEqualStrings("help\n", t3.net_post[0..t3.net_post_len]);
    try std.testing.expect(netAuthVerdict(t3, true));
    var in: [32]u8 = undefined;
    const n = t3.readInput(&in);
    try std.testing.expectEqualStrings("help\n", in[0..n]);
    try std.testing.expectEqual(@as(usize, 0), t3.net_reply_len); // wiped
    try std.testing.expect(t3.net_authed);
    release(h3);

    // (5) A reject verdict is the same failed connection.
    NetCapture.clear();
    tcp.reset();
    const h4 = create(7) orelse return error.TestUnexpectedResult;
    const t4 = get(h4).?;
    try std.testing.expect(t4.attachNetAuth(2323, .hmac_sha256, null));
    netTestEstablish(2323);
    test_challenge = fixed;
    _ = pumpNetInputSeam(NetCapture);
    netTestSetRx(mac_hex ++ "\n");
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(t4.net_reply_ready);
    try std.testing.expect(netAuthVerdictSeam(t4, false, NetCapture));
    try std.testing.expect(attachedNet() == null);
    try std.testing.expect(netTestSent("auth failed"));
    try std.testing.expectEqual(@as(usize, 0), t4.pendingInput());

    for (&terminals) |*tt| tt.reset();
    tcp.reset();
}

test "terminal: ED25519 net auth accepts the 128-hex reply (TS4 class-A framing)" {
    for (&terminals) |*tt| tt.reset();
    tcp.reset();
    defer tcp.reset();
    defer test_challenge = null;
    NetCapture.clock = 0;
    NetCapture.clear();
    const h = create(3) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attachNetAuth(2323, .ed25519, null));
    netTestEstablish(2323);
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(netTestSent("VIRELAIOS-AUTH/1 ed25519 "));
    // A 128-hex signature line (the kernel frames 64/128; it does not
    // verify — the process does).
    var sig_hex: [128]u8 = undefined;
    for (&sig_hex, 0..) |*b, i| b.* = hex_digits[i % 16];
    netTestSetRx(sig_hex ++ "\n");
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(t.net_reply_ready);
    try std.testing.expect(netAuthVerdict(t, true));
    try std.testing.expect(t.net_authed);
    // A 64-hex HMAC line is malformed for ed25519.
    t.detach();
    tcp.reset();
    NetCapture.clear();
    const h2 = create(4) orelse return error.TestUnexpectedResult;
    const t2 = get(h2).?;
    try std.testing.expect(t2.attachNetAuth(2323, .ed25519, null));
    netTestEstablish(2323);
    _ = pumpNetInputSeam(NetCapture);
    netTestSetRx("a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf\n");
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(attachedNet() == null);
    try std.testing.expect(netTestSent("auth failed"));
    for (&terminals) |*tt| tt.reset();
    tcp.reset();
}

test "terminal: net auth deadline trips to a failed connection, never a bypass (TS4)" {
    for (&terminals) |*tt| tt.reset();
    tcp.reset();
    defer tcp.reset();
    NetCapture.clear();
    const h = create(3) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attachNetAuth(2323, .hmac_sha256, null));
    netTestEstablish(2323);
    NetCapture.clock = 0;
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(t.net_challenge_sent);
    // One tick short of the deadline: still waiting, not authed.
    NetCapture.clock = net_auth_deadline - 1;
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(attachedNet() != null);
    try std.testing.expect(!t.net_authed);
    // At the deadline: the failed connection — `auth failed`, reset, detach.
    NetCapture.clock = net_auth_deadline;
    NetCapture.clear();
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(attachedNet() == null);
    try std.testing.expect(netTestSent("auth failed"));
    try std.testing.expectEqual(@as(usize, 0), t.pendingInput());
    try std.testing.expectEqual(@as(u64, 0), tcp.listen_port);
    for (&terminals) |*tt| tt.reset();
    tcp.reset();
}

test "terminal: the TS4 auth framing fits one bounded TCP segment (bounds audit)" {
    // The challenge line: tag + scheme + 2*32 hex + newline.
    const hmac_line = net_auth_tag.len + 1 + "hmac-sha256".len + 1 + 2 * net_challenge_len + 1;
    const ed_line = net_auth_tag.len + 1 + "ed25519".len + 1 + 2 * net_challenge_len + 1;
    try std.testing.expect(hmac_line <= tcp.payload_max);
    try std.testing.expect(ed_line <= tcp.payload_max);
    // The reply line: 128 hex chars (Ed25519) + newline fits the raised bound.
    try std.testing.expect(NetAuthScheme.hmac_sha256.expectedReplyLen() + 1 <= tcp.payload_max);
    try std.testing.expect(NetAuthScheme.ed25519.expectedReplyLen() + 1 <= tcp.payload_max);
    try std.testing.expect(net_auth_line_max >= NetAuthScheme.ed25519.expectedReplyLen());
    try std.testing.expectEqual(@as(usize, 192), tcp.payload_max);
    try std.testing.expectEqual(@as(usize, 212), tcp.segment_max);
}

test "terminal: explicit open mode reproduces SH7 byte flow (TS4)" {
    for (&terminals) |*tt| tt.reset();
    tcp.reset();
    defer tcp.reset();
    NetCapture.clear();
    const h = create(3) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attachNetAuth(2323, .open, null));
    try std.testing.expect(t.net_authed);
    try std.testing.expect(!t.net_auth_on);
    netTestEstablish(2323);
    netTestSetRx("help\n");
    _ = pumpNetInputSeam(NetCapture);
    var in: [32]u8 = undefined;
    const n = t.readInput(&in);
    try std.testing.expectEqualStrings("help\n", in[0..n]);
    // No challenge was ever framed in open mode.
    try std.testing.expect(!netTestSent("VIRELAIOS-AUTH/1"));
    for (&terminals) |*tt| tt.reset();
    tcp.reset();
}

test "terminal: net pump ends a half-open accept on its timeout (M46 #1105)" {
    for (&terminals) |*tt| tt.reset();
    tcp.reset();
    defer tcp.reset();
    NetCapture.clear();
    const h = create(3) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attachNetAuth(2323, .open, null));
    // A SYN was accepted (state syn_received) with the accept clock stamped.
    tcp.listen(2323);
    tcp.state = .syn_received;
    tcp.accept_ticks = 0;
    NetCapture.clock = tcp.accept_timeout - 1;
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(attachedNet() != null); // still waiting for the ACK
    NetCapture.clock = tcp.accept_timeout;
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(attachedNet() == null); // timed out and detached
    try std.testing.expectEqual(@as(u64, 0), tcp.listen_port);
    for (&terminals) |*tt| tt.reset();
    tcp.reset();
}

// ---------------------------------------------------------------------------
// M49 SD5 (#1132): reflow, scrollback view, selection/copy tests
// ---------------------------------------------------------------------------

test "terminal: setCols reflows long lines to the narrower width" {
    var s = Screen{};
    s.feed("abcdefghij\nxy");
    try std.testing.expectEqual(@as(usize, 2), s.lineCount());
    _ = s.setCols(4); // clamped to the 8-column floor
    try std.testing.expectEqual(@as(usize, 8), s.cols);
    try std.testing.expectEqual(@as(usize, 3), s.lineCount());
    try std.testing.expectEqualStrings("abcdefgh", s.line(0));
    try std.testing.expectEqualStrings("ij", s.line(1));
    try std.testing.expectEqualStrings("xy", s.line(2));
    // The cursor follows the last line.
    try std.testing.expectEqual(@as(usize, 2), s.cursorLine());
    try std.testing.expectEqual(@as(usize, 2), s.cursorCol());
    // New output now wraps at the new width.
    s.feed("z12345");
    try std.testing.expectEqual(@as(usize, 3), s.lineCount());
    try std.testing.expectEqualStrings("xyz12345", s.line(2));
    s.feed("9");
    try std.testing.expectEqual(@as(usize, 4), s.lineCount());
    try std.testing.expectEqualStrings("9", s.line(3));
}

test "terminal: reflow overflow drops whole oldest lines" {
    var s = Screen{};
    var i: usize = 0;
    while (i < grid_lines) : (i += 1) s.feed("0123456789\n");
    try std.testing.expectEqual(@as(usize, grid_lines), s.lineCount());
    // Each 10-byte line wraps to 2 rows at 8 columns: only half the content
    // lines fit, and the old trailing empty line survives (127 rows).
    _ = s.setCols(8);
    try std.testing.expectEqual(@as(usize, 8), s.cols);
    try std.testing.expectEqual(@as(usize, 127), s.lineCount());
    // The newest lines survived; the oldest are gone.
    try std.testing.expectEqualStrings("01234567", s.line(0));
    try std.testing.expectEqualStrings("89", s.line(1));
    try std.testing.expectEqualStrings("01234567", s.line(124));
    try std.testing.expectEqualStrings("89", s.line(125));
}

test "terminal: setCols to the same value is a no-op; growth keeps lines" {
    var s = Screen{};
    s.feed("hello\nworld");
    _ = s.setCols(40);
    try std.testing.expectEqual(@as(usize, 40), s.cols);
    try std.testing.expectEqualStrings("hello", s.line(0));
    try std.testing.expectEqualStrings("world", s.line(1));
    _ = s.setCols(80);
    try std.testing.expectEqual(@as(usize, 2), s.lineCount());
    try std.testing.expectEqualStrings("world", s.line(1));
}

test "terminal: scrollback view clamps to the stored range" {
    var s = Screen{};
    s.feed("one\ntwo\nthree\n");
    try std.testing.expectEqual(@as(usize, 0), s.viewOffset());
    s.scrollBy(1);
    try std.testing.expectEqual(@as(usize, 1), s.viewOffset());
    s.scrollBy(100);
    try std.testing.expectEqual(@as(usize, s.lineCount() - 1), s.viewOffset());
    s.scrollBy(-1);
    try std.testing.expectEqual(@as(usize, s.lineCount() - 2), s.viewOffset());
    s.scrollBy(-100);
    try std.testing.expectEqual(@as(usize, 0), s.viewOffset());
    s.scrollBy(2);
    const bottom_before = s.lineCount() - s.viewOffset();
    // M73k (#1637): PIN-while-scrolled — new output must not yank the
    // reader back to the tail; the window's bottom stays put instead
    // (chosen over snap: a deep log or an active search breaks under
    // snap-on-output; Shift+End/scrollReset still snaps on demand).
    s.feed("four\n");
    try std.testing.expectEqual(bottom_before, s.lineCount() - s.viewOffset());
    try std.testing.expectEqual(@as(usize, 3), s.viewOffset());
    // At view 0 the tail follows new output exactly as before.
    s.scrollReset();
    s.feed("five\n");
    try std.testing.expectEqual(@as(usize, 0), s.viewOffset());
}

test "terminal: history ring keeps lines past the grid, drops oldest (#1637)" {
    for (&terminals) |*t| t.reset();
    for (&screens) |*sc| sc.reset();
    const h = create(7) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attachWindow(7));
    const s = screenForWindow(7).?;
    var i: usize = 0;
    while (i < 140) : (i += 1) {
        var b: [16]u8 = undefined;
        const row = std.fmt.bufPrint(&b, "L{d:0>3}\n", .{i}) catch unreachable;
        s.feed(row);
    }
    // 140 LFs + the final unterminated row = 141 surviving lines:
    // 128 in the grid, the oldest 13 in the ring.
    try std.testing.expectEqual(@as(usize, 141), s.lineCount());
    try std.testing.expectEqual(@as(usize, 13), s.hist_count);
    // The oldest line is reachable BELOW the old 128-line limit.
    try std.testing.expectEqualStrings("L000", s.line(0));
    // …and the newest: every feed ends in \n, so L139 sits at lineCount-2
    // and index 140 is the cleared cursor row the last LF moved onto.
    try std.testing.expectEqualStrings("L139", s.line(139));
    try std.testing.expectEqualStrings("", s.line(140));
    // Scroll back to the very top through the unified space.
    s.scrollBy(100_000);
    try std.testing.expectEqual(@as(usize, 140), s.viewOffset());
    // Overflow: past history_lines the OLDEST drops (drop-oldest policy),
    // lineCount saturates at history_lines + grid_lines.
    i = 0;
    while (i < 300) : (i += 1) {
        var b: [16]u8 = undefined;
        const row = std.fmt.bufPrint(&b, "Z{d:0>3}\n", .{i}) catch unreachable;
        s.feed(row);
    }
    try std.testing.expectEqual(@as(usize, history_lines), s.hist_count);
    try std.testing.expect(s.hist_dropped > 0);
    try std.testing.expectEqual(
        @as(usize, history_lines + grid_lines),
        s.lineCount(),
    );
    try std.testing.expect(!(std.mem.eql(u8, s.line(0), "L000")));
}

test "terminal: history is normal-screen only; alt walks its own space (#1637)" {
    for (&terminals) |*t| t.reset();
    for (&screens) |*sc| sc.reset();
    const h = create(7) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attachWindow(7));
    const s = screenForWindow(7).?;
    var i: usize = 0;
    while (i < 140) : (i += 1) {
        var b: [16]u8 = undefined;
        const row = std.fmt.bufPrint(&b, "N{d:0>3}\n", .{i}) catch unreachable;
        s.feed(row);
    }
    const hist_before = s.hist_count;
    try std.testing.expect(hist_before > 0);
    const lines_before = s.lineCount();
    // Enter the alternate screen: its world is the alt grid, no history.
    s.feed("\x1b[?1049h");
    try std.testing.expectEqual(@as(usize, 1), s.lineCount());
    try std.testing.expectEqual(@as(usize, 0), s.cursorLineUnified());
    // Fill the alt grid far past 128 — history must NOT grow there.
    i = 0;
    while (i < 200) : (i += 1) s.feed("alt\n");
    try std.testing.expectEqual(hist_before, s.hist_count);
    try std.testing.expectEqual(@as(usize, grid_lines), s.lineCount());
    // Leave: the primary space (with its history) comes back untouched.
    s.feed("\x1b[?1049l");
    try std.testing.expectEqual(lines_before, s.lineCount());
    try std.testing.expectEqual(hist_before, s.hist_count);
    try std.testing.expectEqualStrings("N000", s.line(0));
}

test "terminal: reflow re-wraps history with the grid, never disagreeing (#1637)" {
    for (&terminals) |*t| t.reset();
    for (&screens) |*sc| sc.reset();
    const h = create(7) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attachWindow(7));
    const s = screenForWindow(7).?;
    // Long rows fill the grid and spill a batch into history.
    var i: usize = 0;
    while (i < 150) : (i += 1) {
        var b: [96]u8 = undefined;
        @memset(&b, 'x');
        const row = std.fmt.bufPrint(&b, "row{d:0>3}" ++ "x" ** 72, .{i}) catch unreachable;
        s.feed(row);
        s.feed("\n");
    }
    try std.testing.expect(s.hist_count > 0);
    // Shrink 80 -> 40: EVERY row, history and grid alike, must re-lay to
    // <= 40 cells — that is the whole point of the shared policy.
    _ = s.setCols(40);
    try std.testing.expectEqual(@as(usize, 40), s.cols);
    try std.testing.expect(s.lineCount() <= history_lines + grid_lines);
    i = 0;
    while (i < s.lineCount()) : (i += 1) {
        const n = s.uLen(i) orelse continue;
        try std.testing.expect(n <= 40);
    }
    // Back up: still consistent, still bounded.
    _ = s.setCols(80);
    try std.testing.expect(s.lineCount() <= history_lines + grid_lines);
    i = 0;
    while (i < s.lineCount()) : (i += 1) {
        const n = s.uLen(i) orelse continue;
        try std.testing.expect(n <= 80);
    }
}

test "terminal: a pushed history row drops its RGB slots to default (#1637)" {
    for (&terminals) |*t| t.reset();
    for (&screens) |*sc| sc.reset();
    const h = create(7) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attachWindow(7));
    const s = screenForWindow(7).?;
    s.feed("\x1b[48;2;10;20;30mCOLOURED\x1b[0m\n");
    // Grid cell carries the truecolour slot…
    const gr = s.hist_count; // unified index the row will land on after push
    s.feed("\n"); // fill 127 more rows to force the push
    var i: usize = 2;
    while (i < grid_lines) : (i += 1) s.feed(".\n");
    try std.testing.expect(s.hist_count > 0);
    // …the stored history row does not: slot coerced, rgbAt truthful.
    const st = s.styleAt(0, 0);
    try std.testing.expect(st.bg != rgb_colour);
    const side = s.rgbAt(0, 0);
    try std.testing.expect(side.bg == null);
    _ = gr;
}

test "terminal: scroll carries truecolour side arrays with the cells (#1637)" {
    for (&terminals) |*t| t.reset();
    for (&screens) |*sc| sc.reset();
    const h = create(7) orelse return error.TestUnexpectedResult;
    const t = get(h).?;
    try std.testing.expect(t.attachWindow(7));
    const s = screenForWindow(7).?;
    s.feed("plain\n\x1b[48;2;10;20;30mTOP\x1b[0m\n");
    // Scroll exactly once (registry screen — a local Screen{} has no
    // history bank, so its ring never fills): the coloured row (grid
    // row 1) moves to grid row 0 = unified row hist_count (1), side
    // arrays in tow. Pre-M73k fix they stayed behind → default bg.
    while (s.hist_count == 0) s.feed("x\n");
    try std.testing.expectEqual(@as(usize, 1), s.hist_count);
    const side = s.rgbAt(1, 0);
    try std.testing.expectEqual(@as(u8, 10), side.bg.?.r);
    try std.testing.expectEqual(@as(u8, 20), side.bg.?.g);
    try std.testing.expectEqual(@as(u8, 30), side.bg.?.b);
}

test "terminal: search table — literal, case, rows, wrap, empty, alt (#1637)" {
    var s = Screen{};
    s.feed("top a\nb bottom\nthe Needle in HAY\nneedle rows\nnone here\n");
    // Alt screen: the chord refuses — search/history are normal-screen only.
    s.feed("\x1b[?1049h");
    try std.testing.expect(!s.searchOpen());
    try std.testing.expect(!s.searchActive());
    s.feed("\x1b[?1049l");
    // Open: empty pattern is a no-op (count 0, backspace at 0 = null).
    try std.testing.expect(s.searchOpen());
    try std.testing.expect(s.searchActive());
    try std.testing.expectEqual(@as(usize, 0), s.search_count);
    try std.testing.expect(s.searchFeed(.backspace) == null);
    // Literal + ASCII-case-insensitive: "needle" hits Needle and needle
    // ("none here" does not), first match parked, exposed as selection.
    var n: ?usize = null;
    for ("needle") |ch| n = s.searchFeed(.{ .ch = ch });
    try std.testing.expectEqual(@as(usize, 2), n.?);
    // First match is row 2 ("the Needle in HAY"), col 4; row 3
    // ("needle rows") is the second — rows 0/1 carry no match.
    try std.testing.expectEqual(@as(usize, 2), s.search_row);
    try std.testing.expectEqual(@as(usize, 4), s.search_col);
    try std.testing.expect(s.inSelection(2, 4));
    try std.testing.expect(s.inSelection(2, 9)); // end col inclusive
    try std.testing.expect(!s.inSelection(2, 10));
    // Enter/prev walk with wrap-around (the bar's Shift+Enter sibling).
    s.searchStep(1);
    try std.testing.expectEqual(@as(usize, 3), s.search_row); // "needle rows"
    try std.testing.expectEqual(@as(usize, 0), s.search_col);
    s.searchStep(1);
    try std.testing.expectEqual(@as(usize, 2), s.search_row); // wrapped
    try std.testing.expectEqual(@as(usize, 4), s.search_col);
    s.searchStep(-1);
    try std.testing.expectEqual(@as(usize, 3), s.search_row); // wrapped back
    // Matches do NOT cross row boundaries (v1): row 0 ends 'a', row 1
    // starts 'b' — the pair "ab" exists only ACROSS the break.
    var i: usize = 0;
    while (i < 6) : (i += 1) _ = s.searchFeed(.backspace);
    try std.testing.expect(s.searchFeed(.backspace) == null); // empty now
    _ = s.searchFeed(.{ .ch = 'a' });
    try std.testing.expectEqual(@as(usize, 0), s.searchFeed(.{ .ch = 'b' }).?);
    try std.testing.expect(s.searchActive()); // no-match = hint, not error
    try std.testing.expect(!s.search_has_cur); // nothing to highlight
    _ = s.searchFeed(.esc);
    try std.testing.expect(!s.searchActive());
    // Alt switch with a LIVE search: the prompt must not ghost into the
    // stashed primary grid (search closes cleanly before the swap).
    try std.testing.expect(s.searchOpen());
    _ = s.searchFeed(.{ .ch = 'a' });
    try std.testing.expect(s.searchActive());
    s.feed("\x1b[?1049h");
    try std.testing.expect(!s.searchActive());
    s.feed("\x1b[?1049l");
    try std.testing.expect(!s.searchActive());
    try std.testing.expectEqualStrings("top a", s.line(0));
    try std.testing.expectEqualStrings("needle rows", s.line(3));
}

test "terminal: search overlay + user selection restore exactly (#1637)" {
    var s = Screen{};
    s.feed("row one\nrow two\nrow three\n");
    s.beginSelection(1, 0);
    s.extendSelection(1, 4);
    try std.testing.expect(s.searchOpen()); // lifts view 0 -> 1
    try std.testing.expectEqual(@as(usize, 1), s.viewOffset());
    // The bar sits on the overlay row, drawn reversed through the grid.
    const bar_u = s.searchOverlayRow();
    try std.testing.expect(s.styleAt(bar_u, 0).reverse);
    _ = s.searchFeed(.{ .ch = 'x' }); // no match here — bar shows hint
    _ = s.searchFeed(.esc);
    // The covered row's original content came back byte-for-byte… (the
    // bar sits at total-view-1 = row 2 = "row three", proven by the
    // reversed styleAt assert above).
    try std.testing.expectEqualStrings("row three", s.line(bar_u));
    // …the user's selection is restored…
    try std.testing.expect(s.hasSelection());
    try std.testing.expect(s.sel_anchor.?.line == 1 and s.sel_anchor.?.col == 0);
    try std.testing.expect(s.sel_cursor.?.line == 1 and s.sel_cursor.?.col == 4);
    // …and the view stays where the search left it ("at the match").
    try std.testing.expectEqual(@as(usize, 1), s.viewOffset());
}

test "terminal: search is rune-aware — accented match, non-ASCII exact (#1637)" {
    var s = Screen{};
    s.feed("caf\u{e9} latte\n");
    try std.testing.expect(s.searchOpen());
    try std.testing.expectEqual(@as(usize, 1), s.searchFeed(.{ .ch = '\u{e9}' }).?);
    try std.testing.expectEqual(@as(usize, 0), s.search_row);
    try std.testing.expectEqual(@as(usize, 3), s.search_col);
    _ = s.searchFeed(.esc);
    // Case policy pin: folding is ASCII-only — \u{c9} does NOT match \u{e9}.
    try std.testing.expect(s.searchOpen());
    try std.testing.expectEqual(@as(usize, 0), s.searchFeed(.{ .ch = '\u{c9}' }).?);
    _ = s.searchFeed(.esc);
}

test "terminal: selection copies across lines and normalizes direction" {
    var s = Screen{};
    s.feed("alpha\nbeta\ngamma");
    var buf: [64]u8 = undefined;

    // Forward selection from (0,2) to (2,3): "pha\nbeta\ngam".
    s.beginSelection(0, 2);
    s.extendSelection(2, 3);
    const n = s.copySelection(&buf);
    try std.testing.expectEqualStrings("pha\nbeta\ngam", buf[0..n]);

    // Backwards selection (2,3) -> (0,2) is the same region.
    s.beginSelection(2, 3);
    s.extendSelection(0, 2);
    const n2 = s.copySelection(&buf);
    try std.testing.expectEqualStrings("pha\nbeta\ngam", buf[0..n2]);

    // A single-point selection merges to the cell.
    s.beginSelection(1, 1);
    s.extendSelection(1, 3);
    const n3 = s.copySelection(&buf);
    try std.testing.expectEqualStrings("et", buf[0..n3]);

    // In-range query.
    s.beginSelection(0, 0);
    s.extendSelection(0, 2);
    try std.testing.expect(s.inSelection(0, 1));
    try std.testing.expect(!s.inSelection(0, 3));
    try std.testing.expect(!s.inSelection(1, 0));

    s.clearSelection();
    try std.testing.expectEqual(@as(usize, 0), s.copySelection(&buf));
    try std.testing.expect(!s.hasSelection());
}

test "terminal: selection coordinates clamp to the grid" {
    var s = Screen{};
    s.feed("x");
    var buf: [16]u8 = undefined;
    // An out-of-range line clamps to the last row; the region then covers it.
    s.beginSelection(999, 0);
    s.extendSelection(0, 1);
    const n = s.copySelection(&buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);
    // An out-of-range column clamps to the grid width (the copy clamps to
    // the stored line length).
    s.beginSelection(0, 999);
    s.extendSelection(0, 0);
    const n2 = s.copySelection(&buf);
    try std.testing.expectEqualStrings("x", buf[0..n2]);
}

test "terminal: copySelectionToClipboard is a no-op without a window binding" {
    for (&terminals) |*t| t.reset();
    try std.testing.expectEqual(@as(usize, 0), copySelectionToClipboard(42));
    for (&terminals) |*t| t.reset();
}

// ---------------------------------------------------------------------------
// M73a-1 (#1625): rune cells — UTF-8 decode, wide pairs, overlays, UTF-8 copy
// ---------------------------------------------------------------------------

test "terminal: grid stores ASCII as a single cell and projects it unchanged" {
    var s = Screen{};
    s.feed("A");
    const cell = s.cellAt(0, 0);
    try std.testing.expectEqual(@as(u21, 'A'), cell.base);
    try std.testing.expectEqual(@as(u21, 0), cell.mark);
    try std.testing.expectEqual(@as(u1, 0), cell.cont);
    try std.testing.expectEqualStrings("A", s.line(0));
}

test "terminal: 2-, 3-, and 4-byte UTF-8 decodes to one rune cell" {
    var s = Screen{};
    s.feed("\xc3\xa9"); // U+00E9 e-acute (2-byte, narrow)
    try std.testing.expectEqual(@as(u21, 0xE9), s.cellAt(0, 0).base);
    try std.testing.expectEqual(@as(usize, 1), s.cursorCol());
    s.feed("\xe2\x82\xac"); // U+20AC euro (3-byte, narrow)
    try std.testing.expectEqual(@as(u21, 0x20AC), s.cellAt(0, 1).base);
    try std.testing.expectEqual(@as(usize, 2), s.cursorCol());
    s.feed("\xf0\x9f\x98\x80"); // U+1F600 grin (4-byte, wide)
    try std.testing.expectEqual(@as(u21, 0x1F600), s.cellAt(0, 2).base);
    try std.testing.expectEqual(@as(u1, 1), s.cellAt(0, 3).cont);
    try std.testing.expectEqual(@as(usize, 4), s.cursorCol());
    try std.testing.expectEqual(@as(usize, 4), s.line(0).len); // lens counts cells
    // The ASCII projection skips rune cells; M73a-2's painter reads cellAt.
    try std.testing.expectEqualStrings("\x00\x00\x00\x00", s.line(0));
}

test "terminal: ill-formed UTF-8 is one U+FFFD per bad sequence, never a raw byte" {
    var s = Screen{};
    s.feed("\x80"); // stray continuation
    try std.testing.expectEqual(@as(u21, 0xFFFD), s.cellAt(0, 0).base);
    s.feed("\xc0\x80"); // C0 is not a lead: two bad bytes, two FFFDs
    try std.testing.expectEqual(@as(u21, 0xFFFD), s.cellAt(0, 1).base);
    try std.testing.expectEqual(@as(u21, 0xFFFD), s.cellAt(0, 2).base);
    s.feed("\xff"); // invalid lead
    try std.testing.expectEqual(@as(u21, 0xFFFD), s.cellAt(0, 3).base);
    // Truncated tail: one FFFD, then the offending byte reprocessed fresh.
    s.feed("\xc3");
    s.feed("x");
    try std.testing.expectEqual(@as(u21, 0xFFFD), s.cellAt(0, 4).base);
    try std.testing.expectEqual(@as(u21, 'x'), s.cellAt(0, 5).base);
    s.feed("\xe0\x80\x80"); // overlong NUL fails as one sequence
    try std.testing.expectEqual(@as(u21, 0xFFFD), s.cellAt(0, 6).base);
    try std.testing.expectEqual(@as(usize, 7), s.cursorCol());
    s.feed("\xed\xa0\x80"); // UTF-16 surrogate
    try std.testing.expectEqual(@as(u21, 0xFFFD), s.cellAt(0, 7).base);
    s.feed("\xf4\x90\x80\x80"); // above U+10FFFF
    try std.testing.expectEqual(@as(u21, 0xFFFD), s.cellAt(0, 8).base);
    // A well-formed sequence still decodes after all that.
    s.feed("\xc3\xa9");
    try std.testing.expectEqual(@as(u21, 0xE9), s.cellAt(0, 9).base);
}

test "terminal: a wide pair occupies two cells and never splits across a wrap" {
    var s = Screen{};
    s.feed("\xe4\xbd\xa0"); // U+4F60 (wide)
    try std.testing.expectEqual(@as(u21, 0x4F60), s.cellAt(0, 0).base);
    try std.testing.expectEqual(@as(u1, 1), s.cellAt(0, 1).cont);
    try std.testing.expectEqual(@as(usize, 2), s.cursorCol());
    try std.testing.expectEqual(@as(usize, 2), s.line(0).len);
    // Park the cursor in the last column; a wide glyph wraps, never splits.
    var i: usize = 0;
    while (i < 77) : (i += 1) s.feed("a");
    try std.testing.expectEqual(@as(usize, 79), s.cursorCol());
    s.feed("\xe4\xbd\xa0");
    try std.testing.expectEqual(@as(usize, 1), s.cursorLine());
    try std.testing.expectEqual(@as(usize, 2), s.cursorCol());
    try std.testing.expectEqual(@as(u21, 0x4F60), s.cellAt(1, 0).base);
    try std.testing.expectEqual(@as(u1, 1), s.cellAt(1, 1).cont);
    // The last cell of line 0 was never half-written.
    try std.testing.expectEqual(@as(u1, 0), s.cellAt(0, 79).cont);
}

test "terminal: overwriting or erasing a pair edge repairs the pair" {
    var s = Screen{};
    s.feed("\xe4\xbd\xa0a"); // [0]=wide base [1]=cont [2]=a
    s.feed("\x1b[1;2H"); // cursor onto the continuation cell
    s.feed("x"); // narrow overwrite of the right half clears the base
    try std.testing.expectEqual(@as(u21, 'x'), s.cellAt(0, 1).base);
    try std.testing.expectEqual(@as(u21, ' '), s.cellAt(0, 0).base);
    try std.testing.expectEqual(@as(u1, 0), s.cellAt(0, 0).cont);
    try std.testing.expectEqual(@as(u21, 'a'), s.cellAt(0, 2).base);

    var s2 = Screen{};
    s2.feed("\xe4\xbd\xa0a");
    s2.feed("\r");
    s2.feed("y"); // overwriting the base clears its orphaned continuation
    try std.testing.expectEqual(@as(u21, 'y'), s2.cellAt(0, 0).base);
    try std.testing.expectEqual(@as(u21, ' '), s2.cellAt(0, 1).base);
    try std.testing.expectEqual(@as(u1, 0), s2.cellAt(0, 1).cont);

    // EL0 from the middle of a pair extends over the whole pair.
    var s3 = Screen{};
    s3.feed("\xe4\xbd\xa0a");
    s3.feed("\x1b[1;2H\x1b[0K");
    try std.testing.expectEqual(@as(u21, ' '), s3.cellAt(0, 0).base);
    try std.testing.expectEqual(@as(u21, ' '), s3.cellAt(0, 1).base);
    try std.testing.expectEqual(@as(u1, 0), s3.cellAt(0, 0).cont);
}

test "terminal: combining marks overlay the base behind the cursor" {
    var s = Screen{};
    s.feed("e\xcc\x81"); // e + U+0301 acute
    try std.testing.expectEqual(@as(u21, 'e'), s.cellAt(0, 0).base);
    try std.testing.expectEqual(@as(u21, 0x301), s.cellAt(0, 0).mark);
    try std.testing.expectEqual(@as(usize, 1), s.cursorCol());
    try std.testing.expectEqual(@as(usize, 1), s.line(0).len);
    // One overlay slot per cell: a second mark is last-wins.
    s.feed("\xcc\x80"); // U+0300
    try std.testing.expectEqual(@as(u21, 0x300), s.cellAt(0, 0).mark);
    try std.testing.expectEqual(@as(usize, 1), s.cursorCol());
    // A mark after a wide glyph rides the wide base (step over the cont).
    s.feed("\xe4\xbd\xa0\xcd\x82"); // 你 + U+0342
    try std.testing.expectEqual(@as(u21, 0x4F60), s.cellAt(0, 1).base);
    try std.testing.expectEqual(@as(u21, 0x342), s.cellAt(0, 1).mark);
    try std.testing.expectEqual(@as(u1, 1), s.cellAt(0, 2).cont);
    try std.testing.expectEqual(@as(usize, 3), s.cursorCol());
    // A mark with no base behind it pins to U+FFFD — never a bare mark cell.
    var s2 = Screen{};
    s2.feed("\xcc\x81");
    try std.testing.expectEqual(@as(u21, 0xFFFD), s2.cellAt(0, 0).base);
    try std.testing.expectEqual(@as(usize, 1), s2.cursorCol());
    // Ignorable zero-width runes are dropped: no cell, cursor unchanged.
    var s3 = Screen{};
    s3.feed("a\xe2\x80\x8bb"); // a + ZWSP + b
    try std.testing.expectEqual(@as(usize, 2), s3.cursorCol());
    try std.testing.expectEqualStrings("ab", s3.line(0));
}

test "terminal: reflow keeps wide pairs intact at the new width" {
    var s = Screen{};
    s.feed("abcdefghi\xe4\xbd\xa0"); // 9 narrow + wide pair
    _ = s.setCols(8);
    try std.testing.expectEqual(@as(usize, 8), s.cols);
    try std.testing.expectEqual(@as(usize, 2), s.lineCount());
    try std.testing.expectEqualStrings("abcdefgh", s.line(0));
    try std.testing.expectEqual(@as(u21, 'i'), s.cellAt(1, 0).base);
    try std.testing.expectEqual(@as(u21, 0x4F60), s.cellAt(1, 1).base);
    try std.testing.expectEqual(@as(u1, 1), s.cellAt(1, 2).cont);
    try std.testing.expectEqual(@as(usize, 3), s.line(1).len);
    // Pair invariant across the whole grid: every continuation has a wide
    // base immediately to its left.
    var row: usize = 0;
    while (row < s.used) : (row += 1) {
        var c: usize = 0;
        while (c < grid_cols) : (c += 1) {
            const cell = s.cellAt(row, c);
            if (cell.cont == 0) continue;
            try std.testing.expect(c > 0);
            try std.testing.expect(text.char_width(s.cellAt(row, c - 1).base) >= 2);
        }
    }
}

test "terminal: selection copies UTF-8 runes once, overlays included" {
    var s = Screen{};
    s.feed("a\xe4\xbd\xa0" ++ "b"); // [0]=a [1]=wide base [2]=cont [3]=b
    var buf: [64]u8 = undefined;
    s.beginSelection(0, 0);
    s.extendSelection(0, 4);
    const n = s.copySelection(&buf);
    try std.testing.expectEqualStrings("a\xe4\xbd\xa0" ++ "b", buf[0..n]);
    // Selection starts on the continuation cell: whole glyph, once.
    s.beginSelection(0, 2);
    s.extendSelection(0, 3);
    const n2 = s.copySelection(&buf);
    try std.testing.expectEqualStrings("\xe4\xbd\xa0", buf[0..n2]);
    // Selection covers only the base: one copy, no continuation bytes.
    s.beginSelection(0, 1);
    s.extendSelection(0, 2);
    const n3 = s.copySelection(&buf);
    try std.testing.expectEqualStrings("\xe4\xbd\xa0", buf[0..n3]);
    // A combining overlay rides its base as real UTF-8.
    var s2 = Screen{};
    s2.feed("e\xcc\x81");
    s2.beginSelection(0, 0);
    s2.extendSelection(0, 1);
    const m = s2.copySelection(&buf);
    try std.testing.expectEqualStrings("e\xcc\x81", buf[0..m]);
}

test "terminal: the alternate screen swap carries rune cells verbatim" {
    var s = Screen{};
    s.feed("e\xcc\x81");
    s.feed("\x1b[?1049h");
    s.feed("\xe4\xbd\xa0");
    try std.testing.expectEqual(@as(u21, 0x4F60), s.cellAt(0, 0).base);
    s.feed("\x1b[?1049l");
    try std.testing.expectEqual(@as(u21, 'e'), s.cellAt(0, 0).base);
    try std.testing.expectEqual(@as(u21, 0x301), s.cellAt(0, 0).mark);
    try std.testing.expectEqual(@as(usize, 1), s.cursorCol());
}

// ---------------------------------------------------------------------------
// M73h (#1634, ADR 0020 Amendment E): rendition depth — xterm 256,
// truecolour side arrays, the new flags, and their resets. The 16-colour
// behaviour tests above must stay green UNCHANGED.
// ---------------------------------------------------------------------------

test "terminal: SGR 38;5/48;5 store xterm 256 indices" {
    var s = Screen{};
    s.feed("\x1b[38;5;196mA\x1b[48;5;21mB");
    try std.testing.expectEqual(@as(?u8, 196), styleForeground(s.styleAt(0, 0)));
    try std.testing.expectEqual(@as(?u8, 21), styleBackground(s.styleAt(0, 1)));
    try std.testing.expectEqual(@as(?u8, 196), styleForeground(s.styleAt(0, 1)));
    // Index 16 must be a REAL colour, not the old sentinel: the u9 slot
    // moved the default to 256 exactly so this cannot read as "default".
    s.feed("\x1b[38;5;16mX");
    try std.testing.expectEqual(@as(?u8, 16), styleForeground(s.styleAt(0, 2)));
    // A palette cell stores no RGB (the rgbAt gate is the slot).
    try std.testing.expectEqual(@as(?Rgb, null), s.rgbAt(0, 2).fg);
}

test "terminal: SGR 38;2/48;2 stores truecolour in the side arrays" {
    var s = Screen{};
    s.feed("\x1b[38;2;255;128;71;48;2;17;34;51mX");
    try std.testing.expectEqual(rgb_colour, s.styleAt(0, 0).fg);
    try std.testing.expectEqual(rgb_colour, s.styleAt(0, 0).bg);
    // The accessor contract: truecolour reads as "no palette index" —
    // paint callers check the slot first and fall through to rgbAt.
    try std.testing.expectEqual(@as(?u8, null), styleForeground(s.styleAt(0, 0)));
    const fg = s.rgbAt(0, 0).fg.?;
    const bg = s.rgbAt(0, 0).bg.?;
    try std.testing.expectEqual(@as(u8, 255), fg.r);
    try std.testing.expectEqual(@as(u8, 128), fg.g);
    try std.testing.expectEqual(@as(u8, 71), fg.b);
    try std.testing.expectEqual(@as(u8, 17), bg.r);
    try std.testing.expectEqual(@as(u8, 34), bg.g);
    try std.testing.expectEqual(@as(u8, 51), bg.b);
    // `39` returns the slot to default (rgb no longer applies).
    s.feed("\x1b[39mY");
    try std.testing.expectEqual(default_colour, s.styleAt(0, 1).fg);
    try std.testing.expectEqual(@as(?Rgb, null), s.rgbAt(0, 1).fg);
    // Out-of-range components never become a colour: the slot keeps its
    // PREVIOUS value (still the rgb marker from the earlier 48;2) and the
    // stored channels are untouched.
    s.feed("\x1b[48;2;300;0;0mZ");
    try std.testing.expectEqual(rgb_colour, s.styleAt(0, 2).bg);
    const bg2 = s.rgbAt(0, 2).bg.?;
    try std.testing.expectEqual(@as(u8, 17), bg2.r);
    try std.testing.expectEqual(@as(u8, 34), bg2.g);
    try std.testing.expectEqual(@as(u8, 51), bg2.b);
}

test "terminal: truecolour rides the alternate round trip" {
    var s = Screen{};
    s.feed("\x1b[38;2;10;20;30mA"); // primary: rgb A
    s.feed("\x1b[?1049h");
    s.feed("\x1b[38;2;40;50;60mB"); // alternate: rgb B
    s.feed("\x1b[?1049l");
    // The style word swapped back to the primary; if the rgb side arrays
    // had NOT swapped with it, rgbAt here would report B's channels.
    try std.testing.expectEqual(@as(u21, 'A'), s.cellAt(0, 0).base);
    const fg = s.rgbAt(0, 0).fg.?;
    try std.testing.expectEqual(@as(u8, 10), fg.r);
    try std.testing.expectEqual(@as(u8, 20), fg.g);
    try std.testing.expectEqual(@as(u8, 30), fg.b);
    // The state mirror swapped too: the next write on the primary keeps
    // rgb A even though the last 38;2 seen was B's.
    s.feed("C");
    try std.testing.expectEqual(@as(u8, 30), s.rgbAt(0, 1).fg.?.b);
}

test "terminal: truecolour rides a resize reflow" {
    var s = Screen{};
    s.feed("\x1b[38;2;9;8;7m");
    s.feed("aaaaaaaaaaaaaaaaaaaaaaaaaa"); // 26 cells, all rgb-marked
    _ = s.setCols(8); // reflow: rows of 8 — most cells change row
    try std.testing.expectEqual(@as(u21, 'a'), s.cellAt(1, 1).base);
    const fg = s.rgbAt(1, 1).fg.?; // landed mid-row after the re-feed
    try std.testing.expectEqual(@as(u8, 9), fg.r);
    try std.testing.expectEqual(@as(u8, 8), fg.g);
    try std.testing.expectEqual(@as(u8, 7), fg.b);
    // Erasing zeroes the side arrays, not just the slot.
    s.feed("\x1b[1;1H\x1b[2K");
    try std.testing.expectEqual(empty_rgb, s.fg_rgb[0][0]);
    try std.testing.expectEqual(@as(?Rgb, null), s.rgbAt(0, 0).fg);
}

test "terminal: extended selectors consume their params; invalid forms are ignored" {
    var s = Screen{};
    // Index walk: flags AFTER a full selector still apply — this is the
    // CURRENT rendition (no glyph written yet, so styleAt would be blank).
    s.feed("\x1b[1;38;5;196;4m");
    try std.testing.expectEqual(true, styleBold(s.style));
    try std.testing.expectEqual(@as(?u8, 196), styleForeground(s.style));
    try std.testing.expectEqual(true, styleUnderline(s.style));
    // Out-of-range index: rendition unchanged.
    s.feed("\x1b[38;5;999m");
    try std.testing.expectEqual(@as(?u8, 196), styleForeground(s.style)); // rendition untouched
    // Truncated rgb: the tail is DROPPED, never re-read as standalone
    // SGRs (31 would have turned the foreground red).
    s.feed("\x1b[38;2;31mX");
    try std.testing.expectEqual(@as(?u8, 196), styleForeground(s.styleAt(0, 0)));
    try std.testing.expectEqual(@as(u21, 'X'), s.cellAt(0, 0).base);
    // A bare selector and an unknown kind are consumed, not painted.
    s.feed("\x1b[38m\x1b[48;7mY");
    try std.testing.expectEqual(@as(?u8, 196), styleForeground(s.styleAt(0, 1)));
    try std.testing.expectEqual(@as(?u8, null), styleBackground(s.styleAt(0, 1)));
    // The colon (ITU) sub-parameter form has no arm: digits collapse into
    // one unknown param (3859) and everything stays unchanged.
    s.feed("\x1b[38:5:9mZ");
    try std.testing.expectEqual(@as(?u8, 196), styleForeground(s.styleAt(0, 2)));
    try std.testing.expectEqual(@as(u21, 'Z'), s.cellAt(0, 2).base);
}

test "terminal: rendition flags 2/3/4/7 and their resets" {
    var s = Screen{};
    s.feed("\x1b[2;3;4;7mA");
    try std.testing.expectEqual(true, styleDim(s.styleAt(0, 0)));
    try std.testing.expectEqual(true, styleItalic(s.styleAt(0, 0)));
    try std.testing.expectEqual(true, styleUnderline(s.styleAt(0, 0)));
    try std.testing.expectEqual(true, styleReverse(s.styleAt(0, 0)));
    try std.testing.expectEqual(false, styleBold(s.styleAt(0, 0)));
    s.feed("\x1b[22;23;24;27mB");
    try std.testing.expectEqual(false, styleDim(s.styleAt(0, 1)));
    try std.testing.expectEqual(false, styleItalic(s.styleAt(0, 1)));
    try std.testing.expectEqual(false, styleUnderline(s.styleAt(0, 1)));
    try std.testing.expectEqual(false, styleReverse(s.styleAt(0, 1)));
    // SGR 0 clears EVERYTHING — flags included, byte-exact default.
    // (A and B above already consumed columns 0 and 1, so A' lands at 2
    // and the reset cell B' at 3.)
    s.feed("\x1b[1;4;31mA\x1b[0mB");
    try std.testing.expectEqual(true, styleUnderline(s.styleAt(0, 2)));
    try std.testing.expectEqual(default_cell_style, s.styleAt(0, 3));
    try std.testing.expectEqual(false, styleBold(s.style));
    try std.testing.expectEqual(false, styleUnderline(s.style));
    try std.testing.expectEqual(@as(?u8, null), styleForeground(s.style));
}

test "terminal: xterm256Rgb spot-checks (cube + grayscale + ansi)" {
    // Cube: index 16 = (0,0,0), 22 = level(1,0,0) = (0,95,0),
    // 52 = level(1) on red = (95,0,0), 102 = (135,135,135), 231 = white.
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, xterm256Rgb(16));
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 95, .b = 0 }, xterm256Rgb(22));
    try std.testing.expectEqual(Rgb{ .r = 95, .g = 0, .b = 0 }, xterm256Rgb(52));
    try std.testing.expectEqual(Rgb{ .r = 135, .g = 135, .b = 135 }, xterm256Rgb(102));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, xterm256Rgb(231));
    // Grayscale ramp: 232 = 8, 255 = 8 + 10·23 = 238.
    try std.testing.expectEqual(Rgb{ .r = 8, .g = 8, .b = 8 }, xterm256Rgb(232));
    try std.testing.expectEqual(Rgb{ .r = 238, .g = 238, .b = 238 }, xterm256Rgb(255));
    // 0..=15 are total (paint keeps its ansi_palette for these).
    try std.testing.expectEqual(Rgb{ .r = 0xe5, .g = 0xe5, .b = 0xe5 }, xterm256Rgb(7));
    try std.testing.expectEqual(Rgb{ .r = 0x00, .g = 0xff, .b = 0xff }, xterm256Rgb(14));
}

test "terminal: a 12-param SGR line fits the widened csi_params" {
    // Before M73h this overflowed [8]: params 9.. dropped, so 48;5;9 was
    // lost. 12 params now land in full.
    var s = Screen{};
    s.feed("\x1b[1;4;7;3;38;2;1;2;3;48;5;9mX");
    try std.testing.expectEqual(true, styleBold(s.styleAt(0, 0)));
    try std.testing.expectEqual(true, styleUnderline(s.styleAt(0, 0)));
    try std.testing.expectEqual(true, styleReverse(s.styleAt(0, 0)));
    try std.testing.expectEqual(true, styleItalic(s.styleAt(0, 0)));
    const fg = s.rgbAt(0, 0).fg.?;
    try std.testing.expectEqual(@as(u8, 1), fg.r);
    try std.testing.expectEqual(@as(u8, 2), fg.g);
    try std.testing.expectEqual(@as(u8, 3), fg.b);
    try std.testing.expectEqual(@as(?u8, 9), styleBackground(s.styleAt(0, 0)));
}
