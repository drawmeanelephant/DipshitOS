//! VirelaiOS terminal (vt) seam (ADR 0020, issue #1072).
//!
//! A **terminal** is a bounded, hardware-free session buffer: an output ring
//! the owner process writes to, an input queue a front-end fills, and an
//! exclusive attach state naming the front-end (the raw serial console, a
//! TABWM window, a TCP/SSH session). It is the thing `SH.BIN`, `TERM.BIN`,
//! and remote sessions all sit on — see ADR 0020.
//!
//! Pure by construction: fixed arrays, no allocation, no hardware, no
//! syscalls. The device/front-end wiring lives outside this module (the
//! `/dev/tty` routing in `file_table.zig` is the next tranche).
//!
//! Overflow policy is explicit and counted:
//!   * output full -> drop the OLDEST byte (`out_dropped`), so output flows;
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
// M46 RC3 (#1111, ADR 0022): the net pump stamps the TCP RTO clock from the
// 1 Hz generic timer so the half-open accept timeout (#1105) advances while a
// net-bound shell waits for its first client.
const timer = @import("timer.zig");

/// Output ring capacity (bytes the owner has written, awaiting a front-end).
pub const out_capacity: usize = 4096;
/// Input queue capacity (bytes a front-end has pushed, awaiting the owner).
pub const in_capacity: usize = 256;
/// How many concurrent terminals the kernel tracks.
pub const max_terminals: usize = 4;

/// M46 RC3 (#1111, ADR 0022 D3): the longest accepted net-front-end shared
/// secret (bytes). Bounded so the terminal object stays fixed-array sized;
/// the challenge buffer is one byte longer to catch the newline terminator.
pub const net_secret_max: usize = 63;
pub const net_challenge_max: usize = net_secret_max + 1;

/// #1082 (ADR 0020 Amendment A): the window front-end's presentation grid.
/// The terminal OBJECT stays a pure byte session (D1); this bounded
/// character grid + scrollback is presentation state rendered by the kernel
/// into the bound `.user` window (A4). 8x8 cells, the kernel glyph raster.
pub const grid_cols: usize = 80;
pub const grid_lines: usize = 128;

/// A bounded character grid with scrollback for one window-bound terminal.
/// Bytes fed from the output ring are laid out (CR/LF/BS/TAB, a minimal CSI
/// clear/home), wrapping at `cols` and scrolling one line at a time. A
/// window resize reflows the stored lines to the new column count (M49 SD5
/// #1132). Pure: fixed arrays, no allocation, host-testable.
pub const Point = struct { line: usize, col: usize };

pub const Screen = struct {
    cells: [grid_lines][grid_cols]u8 = [_][grid_cols]u8{[_]u8{' '} ** grid_cols} ** grid_lines,
    lens: [grid_lines]usize = [_]usize{0} ** grid_lines,
    /// Number of lines in use (>= 1); grows to `grid_lines` then scrolls.
    used: usize = 1,
    /// The cursor's line (0..used-1) and column.
    cur: usize = 0,
    col: usize = 0,
    /// Minimal CSI state: 0 normal, 1 ESC, 2 ESC [.
    esc_state: u8 = 0,
    esc_param: u32 = 0,
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
        @memset(&self.cells[i], ' ');
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

    /// Feed one output byte. Control bytes drive the cursor; a minimal
    /// `ESC [ <param> <final>` is consumed (`2J` clears, `H` homes).
    pub fn putByte(self: *Screen, b: u8) void {
        switch (self.esc_state) {
            0 => {},
            1 => {
                if (b == '[') {
                    self.esc_state = 2;
                    self.esc_param = 0;
                } else {
                    self.esc_state = 0;
                }
                return;
            },
            2 => {
                if (b >= '0' and b <= '9') {
                    self.esc_param = self.esc_param *% 10 +% (b - '0');
                    return;
                }
                if (b >= 0x3a and b <= 0x3f) return; // parameter separators
                self.esc_state = 0;
                if (b == 'J' and self.esc_param == 2) self.clearScreen();
                if (b == 'H') self.col = 0;
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
                if (self.col >= self.cols) self.newline();
                self.cells[self.cur][self.col] = b;
                if (self.col + 1 > self.lens[self.cur]) self.lens[self.cur] = self.col + 1;
                self.col += 1;
                self.view = 0;
            },
        }
    }

    pub fn feed(self: *Screen, bytes: []const u8) void {
        for (bytes) |b| self.putByte(b);
    }

    pub fn lineCount(self: *const Screen) usize {
        return self.used;
    }

    /// The rendered bytes of line `i` (empty for an out-of-range line).
    pub fn line(self: *const Screen, i: usize) []const u8 {
        if (i >= self.used) return &.{};
        return self.cells[i][0..self.lens[i]];
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

    /// The number of grid rows needed for `len` bytes at `cols` columns
    /// (at least one row, even for an empty line).
    fn wrappedRows(len: usize, cols: usize) usize {
        return @max(@as(usize, 1), (len + cols - 1) / cols);
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
            const k = wrappedRows(self.lens[first - 1], c);
            if (kept + k > grid_lines) break;
            kept += k;
            first -= 1;
        }

        // Snapshot the kept lines (module BSS scratch: the grid is ~10 KiB,
        // too much for IRQ/Task stacks).
        var count: usize = 0;
        var i: usize = first;
        while (i < self.used) : (i += 1) {
            const len = @min(self.lens[i], grid_cols);
            @memcpy(reflow_lines[count][0..len], self.cells[i][0..len]);
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
            self.feed(reflow_lines[n][0..reflow_lens[n]]);
            if (n + 1 < count) self.feed("\n");
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

    /// Copy the selected region into `dst` (lines joined by `\n`, endpoints
    /// inclusive; the region is clamped to the line lengths). Returns the
    /// byte count; 0 when there is no selection.
    pub fn copySelection(self: *const Screen, dst: []u8) usize {
        const a = self.sel_anchor orelse return 0;
        const b = self.sel_cursor orelse return 0;
        const start = if (a.line < b.line or (a.line == b.line and a.col <= b.col)) a else b;
        const end = if (start.line == a.line and start.col == a.col) b else a;
        var out: usize = 0;
        var row = start.line;
        while (row <= end.line) : (row += 1) {
            const text = self.line(row);
            const from = if (row == start.line) @min(start.col, text.len) else 0;
            const to = if (row == end.line) @min(end.col, text.len) else text.len;
            if (to > from and out < dst.len) {
                const n = @min(to - from, dst.len - out);
                @memcpy(dst[out..][0..n], text[from..][0..n]);
                out += n;
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
var reflow_lines: [grid_lines][grid_cols]u8 = undefined;
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
    /// M46 RC3 (#1111, ADR 0022 D3): the net-front-end v1 auth state. A
    /// non-empty `net_secret` requires the session's first line to match
    /// before any byte reaches the shell; `net_authed` is set on success and
    /// gates delivery. `net_allow_on`/`net_allow_ip` are the optional
    /// source-IP allowlist (D4). All cleared on detach/reset.
    net_secret: [net_secret_max]u8 = [_]u8{0} ** net_secret_max,
    net_secret_len: u8 = 0,
    net_authed: bool = true, // no secret => open (SH7 behavior)
    net_challenge: [net_challenge_max]u8 = [_]u8{0} ** net_challenge_max,
    net_challenge_len: usize = 0,
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

    /// M46 RC3 (#1111): drop all net-auth state (secret, challenge, auth
    /// flag, allowlist). Called on detach and before a fresh bind.
    pub fn clearNetAuth(self: *Terminal) void {
        self.net_secret_len = 0;
        self.net_authed = true;
        self.net_challenge_len = 0;
        self.net_allow_on = false;
        self.net_allow_ip = .{ 0, 0, 0, 0 };
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

    /// M46 RC3 (#1111, ADR 0022 D3/D4): attach the net front-end with v1
    /// auth — an optional shared `secret` (the session's first line must
    /// match) and an optional source-IP `allow_ip`. An empty secret means
    /// "accept immediately" (SH7 behavior, boot default unchanged).
    pub fn attachNetAuth(self: *Terminal, port: u16, secret: []const u8, allow_ip: ?[4]u8) bool {
        if (!self.attachNet(port)) return false;
        self.clearNetAuth();
        const n = @min(secret.len, net_secret_max);
        if (n > 0) {
            @memcpy(self.net_secret[0..n], secret[0..n]);
            self.net_secret_len = @intCast(n);
            self.net_authed = false; // the first line must match
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

// ---------------------------------------------------------------------------
// The net front-end pump (SH7 #1083, ADR 0020 Amendment B; M46 RC3 #1111,
// ADR 0022). The kernel's TCP seam is a single bounded connection; the pump
// moves bytes between the net-bound terminal and that connection. Incoming
// segments are drained, a pending ACK/SYN-ACK is flushed, the received
// payload is delivered (through the v1 shared-secret gate when set), and (on
// the owner's `/dev/tty` write) the terminal output ring is chunked into TCP
// data segments. A peer FIN / dead connection / exhausted SYN-ACK accept
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

/// Best-effort constant-time byte compare (ADR 0022 D3: intent only — a
/// length difference leaks, and this is not a side-channel guarantee).
fn secretEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
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

/// Deliver a received payload through the v1 auth gate (ADR 0022 D3). With no
/// secret set the bytes go straight to the shell; with a secret the FIRST
/// line is the credential — a match consumes it and authenticates, a mismatch
/// transmits `auth failed\n`, ends the session, and detaches. Returns bytes
/// delivered to the terminal input queue.
fn netAuthConsume(t: *Terminal, comptime seam: type, bytes: []const u8) usize {
    var delivered: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (t.net_authed) {
            delivered += t.pushInput(bytes[i..]);
            break;
        }
        const b = bytes[i];
        i += 1;
        if (b == '\n' or b == '\r') {
            if (secretEq(t.net_challenge[0..t.net_challenge_len], t.net_secret[0..t.net_secret_len])) {
                t.net_authed = true;
                t.net_challenge_len = 0;
                if (b == '\r' and i < bytes.len and bytes[i] == '\n') i += 1; // CRLF
                continue; // consume the credential line, deliver the rest
            }
            _ = netTx(seam, "auth failed\n");
            klog.line("tty net: auth failed\n");
            tcp.reset();
            t.detach();
            return delivered;
        }
        if (t.net_challenge_len < net_secret_max) {
            t.net_challenge[t.net_challenge_len] = b;
            t.net_challenge_len += 1;
        } else {
            // Over-long credential line: reject honestly (bounded buffer).
            _ = netTx(seam, "auth failed\n");
            klog.line("tty net: auth failed\n");
            tcp.reset();
            t.detach();
            return delivered;
        }
    }
    return delivered;
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

test "terminal: net pump gates delivery on the shared secret (M46 RC3)" {
    for (&terminals) |*tt| tt.reset();
    tcp.reset();
    defer tcp.reset();
    NetCapture.clock = 0;
    // (1) A wrong secret is rejected: detached, `auth failed` sent, and NO
    // byte reaches the shell.
    NetCapture.clear();
    const h1 = create(3) orelse return error.TestUnexpectedResult;
    const t1 = get(h1).?;
    try std.testing.expect(t1.attachNetAuth(2323, "s3cret", null));
    try std.testing.expect(!t1.net_authed);
    netTestEstablish(2323);
    netTestSetRx("nope\nhelp\n");
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(attachedNet() == null);
    try std.testing.expectEqual(@as(usize, 0), t1.pendingInput());
    try std.testing.expect(netTestSent("auth failed"));

    // (2) The correct secret in the same chunk as a command: the credential
    // line is consumed, the command is delivered, output stays withheld until
    // auth and then flows.
    NetCapture.clear();
    const h2 = create(4) orelse return error.TestUnexpectedResult;
    const t2 = get(h2).?;
    try std.testing.expect(t2.attachNetAuth(2323, "s3cret", null));
    netTestEstablish(2323);
    _ = t2.write("prompt> ");
    try std.testing.expectEqual(@as(usize, 0), pumpNetOutputSeam(NetCapture));
    try std.testing.expect(!netTestSent("prompt> "));
    netTestSetRx("s3cret\r\nhelp\n");
    _ = pumpNetInputSeam(NetCapture);
    try std.testing.expect(t2.net_authed);
    var in: [32]u8 = undefined;
    const n = t2.readInput(&in);
    try std.testing.expectEqualStrings("help\n", in[0..n]);
    try std.testing.expect(netTestSent("prompt> ")); // the withheld prompt flushed
    t2.detach();
    tcp.reset();

    // (3) No secret = SH7 behavior: bytes flow immediately.
    NetCapture.clear();
    const h3 = create(5) orelse return error.TestUnexpectedResult;
    const t3 = get(h3).?;
    try std.testing.expect(t3.attachNetAuth(2323, &.{}, null));
    try std.testing.expect(t3.net_authed);
    netTestEstablish(2323);
    netTestSetRx("help\n");
    _ = pumpNetInputSeam(NetCapture);
    var in3: [32]u8 = undefined;
    const n3 = t3.readInput(&in3);
    try std.testing.expectEqualStrings("help\n", in3[0..n3]);

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
    try std.testing.expect(t.attachNetAuth(2323, &.{}, null));
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
