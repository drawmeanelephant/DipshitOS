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

/// Output ring capacity (bytes the owner has written, awaiting a front-end).
pub const out_capacity: usize = 4096;
/// Input queue capacity (bytes a front-end has pushed, awaiting the owner).
pub const in_capacity: usize = 256;
/// How many concurrent terminals the kernel tracks.
pub const max_terminals: usize = 4;

/// #1082 (ADR 0020 Amendment A): the window front-end's presentation grid.
/// The terminal OBJECT stays a pure byte session (D1); this bounded
/// character grid + scrollback is presentation state rendered by the kernel
/// into the bound `.user` window (A4). 8x8 cells, the kernel glyph raster.
pub const grid_cols: usize = 80;
pub const grid_lines: usize = 128;

/// A bounded character grid with scrollback for one window-bound terminal.
/// Bytes fed from the output ring are laid out (CR/LF/BS/TAB, a minimal CSI
/// clear/home), wrapping at `grid_cols` and scrolling one line at a time.
/// Pure: fixed arrays, no allocation, host-testable.
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
    }

    pub fn clearScreen(self: *Screen) void {
        var i: usize = 0;
        while (i < grid_lines) : (i += 1) self.clearLine(i);
        self.used = 1;
        self.cur = 0;
        self.col = 0;
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
                self.col = @min(next, grid_cols - 1);
            },
            0x07 => {}, // bell — silent
            else => {
                if (b < 0x20 or b == 0x7f) return;
                if (self.col >= grid_cols) self.newline();
                self.cells[self.cur][self.col] = b;
                if (self.col + 1 > self.lens[self.cur]) self.lens[self.cur] = self.col + 1;
                self.col += 1;
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

    pub fn cols() usize {
        return grid_cols;
    }
};

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
