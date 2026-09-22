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

/// A terminal cell stores one of the ANSI 16 colours, or the presentation
/// default (16), for both foreground and background plus the bold bit.
///
/// The grid deliberately keeps this compact instead of retaining arbitrary
/// RGB values: the window terminal is a bounded 8x8 presentation surface,
/// and the M72b contract freezes 16-colour SGR rather than a truecolour ABI.
pub const CellStyle = u16;
pub const default_colour: u8 = 16;
pub const default_cell_style: CellStyle = @as(CellStyle, default_colour) |
    (@as(CellStyle, default_colour) << 5);

pub fn styleForeground(style: CellStyle) ?u8 {
    const colour: u8 = @truncate(style & 0x1f);
    return if (colour == default_colour) null else colour;
}

pub fn styleBackground(style: CellStyle) ?u8 {
    const colour: u8 = @truncate((style >> 5) & 0x1f);
    return if (colour == default_colour) null else colour;
}

pub fn styleBold(style: CellStyle) bool {
    return (style & (@as(CellStyle, 1) << 10)) != 0;
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
    /// CSI state: 0 normal, 1 ESC, 2 CSI.
    esc_state: u8 = 0,
    csi_params: [8]u16 = [_]u16{0} ** 8,
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

    pub fn reset(self: *Screen) void {
        self.* = .{};
    }

    fn clearLine(self: *Screen, i: usize) void {
        @memset(&self.cells[i], empty_cell);
        @memset(&self.styles[i], default_cell_style);
        self.lens[i] = 0;
    }

    fn newline(self: *Screen) void {
        if (self.cur + 1 < grid_lines) {
            self.cur += 1;
            if (self.cur >= self.used) self.used = self.cur + 1;
            self.clearLine(self.cur);
        } else {
            // Scroll up one line, dropping the oldest (bounded scrollback).
            var i: usize = 0;
            while (i + 1 < grid_lines) : (i += 1) {
                self.cells[i] = self.cells[i + 1];
                self.styles[i] = self.styles[i + 1];
                self.lens[i] = self.lens[i + 1];
            }
            self.clearLine(grid_lines - 1);
            self.cur = grid_lines - 1;
            self.used = grid_lines;
        }
        self.col = 0;
        self.view = 0;
    }

    pub fn clearScreen(self: *Screen) void {
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
            self.view = 0;
            return;
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
        if (width == 2) {
            self.cells[self.cur][self.col + 1] = empty_cell;
            self.cells[self.cur][self.col + 1].cont = 1;
            self.styles[self.cur][self.col + 1] = style;
        }
        const end = self.col + width;
        if (end > self.lens[self.cur]) self.lens[self.cur] = end;
        self.col = end;
        self.view = 0;
    }

    fn setForeground(self: *Screen, colour: u8) void {
        self.style = (self.style & ~@as(CellStyle, 0x1f)) | colour;
    }

    fn setBackground(self: *Screen, colour: u8) void {
        self.style = (self.style & ~(@as(CellStyle, 0x1f) << 5)) | (@as(CellStyle, colour) << 5);
    }

    fn setBold(self: *Screen, on: bool) void {
        const bit = @as(CellStyle, 1) << 10;
        if (on) self.style |= bit else self.style &= ~bit;
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
    }

    fn setAlternate(self: *Screen, enabled: bool) void {
        if (self.alt_active == enabled) return;
        self.swapAlternate();
        self.alt_active = enabled;
        self.clearSelection();
        if (enabled) {
            self.clearScreen();
            self.style = default_cell_style;
        }
    }

    fn applySgr(self: *Screen) void {
        var i: usize = 0;
        while (i < self.csi_count) : (i += 1) {
            const param = self.csi_params[i];
            switch (param) {
                0 => self.style = default_cell_style,
                1 => self.setBold(true),
                22 => self.setBold(false),
                30...37 => self.setForeground(@intCast(param - 30)),
                39 => self.setForeground(default_colour),
                40...47 => self.setBackground(@intCast(param - 40)),
                49 => self.setBackground(default_colour),
                90...97 => self.setForeground(@intCast(param - 90 + 8)),
                100...107 => self.setBackground(@intCast(param - 100 + 8)),
                else => {},
            }
        }
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

    pub fn lineCount(self: *const Screen) usize {
        return self.used;
    }

    /// The ASCII projection of line `i` (empty for an out-of-range line):
    /// base runes U+0000..U+007F as themselves; continuation cells and any
    /// non-ASCII rune project to one 0x00 byte (the renderer already skips
    /// <0x20 and >0x7E, so rune cells draw nothing until M73a-2's painter
    /// reads `cellAt`). The length is still the cell count (`lens`), so
    /// column indices line up. Module scratch: consume the result before
    /// the next call.
    pub fn line(self: *const Screen, i: usize) []const u8 {
        if (i >= self.used) return &.{};
        const n = self.lens[i];
        for (0..n) |c| {
            const cell = self.cells[i][c];
            line_scratch[c] = if (cell.cont != 0 or cell.base >= 0x80) 0 else @intCast(cell.base);
        }
        return line_scratch[0..n];
    }

    /// The real cell at (line, col) — M73a-1's presentation truth for the
    /// painter, tests, and anyone who needs runes rather than bytes.
    pub fn cellAt(self: *const Screen, line_index: usize, col_index: usize) Cell {
        if (line_index >= self.used or col_index >= grid_cols) return empty_cell;
        return self.cells[line_index][col_index];
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
        if (line_index >= self.used or col_index >= self.cols) return default_cell_style;
        return self.styles[line_index][col_index];
    }

    // -- M49 SD5 (#1132): scrollback view -----------------------------------

    /// Move the scrollback view by `delta` lines (positive = older). Clamped
    /// to the stored range; 0 follows the tail.
    pub fn scrollBy(self: *Screen, delta: i32) void {
        const max_view: i64 = if (self.used > 0) @intCast(self.used - 1) else 0;
        var v: i64 = @as(i64, @intCast(self.view)) + delta;
        if (v < 0) v = 0;
        if (v > max_view) v = max_view;
        self.view = @intCast(v);
    }

    /// Snap the view back to the tail (new output does this implicitly).
    pub fn scrollReset(self: *Screen) void {
        self.view = 0;
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
                self.putRune(src.base, src.mark, reflow_styles[n][cell]);
            }
            if (n + 1 < count) self.newline();
        }
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
};

/// M49 SD5: reflow scratch (module BSS — the grid is too large for the task
/// stacks). One reflow at a time (the paint/idle path), documented bound.
var reflow_lines: [grid_lines][grid_cols]Cell = undefined;

/// M73a-1 (#1625): `line()`'s ASCII projection scratch (module BSS). One
/// consumer at a time — the paint path reads a line and moves on.
var line_scratch: [grid_cols]u8 = undefined;
var reflow_styles: [grid_lines][grid_cols]CellStyle = undefined;
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
    // New output snaps the view back to the tail.
    s.feed("four\n");
    try std.testing.expectEqual(@as(usize, 0), s.viewOffset());
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
