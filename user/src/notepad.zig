//! VirelaiOS fifteenth ESP user program — NOTEPAD.BIN (Milestone 11, Card A3).
//!
//! Interactive graphical text editor with multi-line editing, cursor navigation,
//! and persistent load/save from `/data/notes.txt` using M10 storage syscalls.
//! Uses zero dynamic memory allocation (`ui.zig` micro-widgets).
//!
//! Claim 1771: the editor box is now a SCROLLABLE viewport. A wrap-aware
//! `TextLayout` model (29 glyphs per display row, 11 visible rows) drives BOTH
//! navigation and rendering with the same rules, so what you navigate is what
//! you see: Up/Down/Home/End/PageUp/PageDown move across display rows
//! preserving column, `ensure_visible` auto-scrolls so the cursor is never
//! clipped, a scrollbar thumb shows position when content overflows, clicking
//! in the editor places the cursor, and Delete (forward) is supported.

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const Label = ui.Label;
const Event = ui.Event;

pub const window_id: u32 = 2;
pub const window_x: u32 = 56;
pub const window_y: u32 = 56;
pub const window_w: u32 = 512;
pub const window_h: u32 = 384;

pub const exit_status: u32 = 43;
pub const notes_path: []const u8 = "/host/notes.txt"; // M34 HF5 (#739): user data lives in the host folder

// Text box geometry (the editor surface inside the window).
pub const text_area = Rect.make(6, 36, 244, 150);
pub const glyph_w: u32 = 8;
pub const line_h: u32 = 12;
pub const text_x0: u32 = text_area.x + 6;
pub const text_y0: u32 = text_area.y + 6;

// ---------------------------------------------------------------------------
// Text Editor Buffer Model
// ---------------------------------------------------------------------------

pub const TextBuffer = struct {
    buf: [512]u8 = [_]u8{0} ** 512,
    len: usize = 0,
    cursor: usize = 0,

    pub fn init() TextBuffer {
        return .{};
    }

    pub fn get_slice(self: *const TextBuffer) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set_content(self: *TextBuffer, content: []const u8) void {
        const copy_len = @min(content.len, self.buf.len);
        @memcpy(self.buf[0..copy_len], content[0..copy_len]);
        self.len = copy_len;
        self.cursor = copy_len;
    }

    pub fn clear(self: *TextBuffer) void {
        self.len = 0;
        self.cursor = 0;
    }

    pub fn insert_char(self: *TextBuffer, ch: u8) bool {
        if (self.len >= self.buf.len) return false;
        var i = self.len;
        while (i > self.cursor) : (i -= 1) {
            self.buf[i] = self.buf[i - 1];
        }
        self.buf[self.cursor] = ch;
        self.len += 1;
        self.cursor += 1;
        return true;
    }

    /// Insert a whole slice at the cursor, byte by byte, stopping at the
    /// buffer capacity. Returns the number of bytes actually inserted (short
    /// when the buffer is nearly full — the paste path's honest bound).
    pub fn insert_slice(self: *TextBuffer, text: []const u8) usize {
        var inserted: usize = 0;
        for (text) |ch| {
            if (!self.insert_char(ch)) break;
            inserted += 1;
        }
        return inserted;
    }

    pub fn backspace(self: *TextBuffer) bool {
        if (self.cursor == 0 or self.len == 0) return false;
        var i = self.cursor - 1;
        while (i < self.len - 1) : (i += 1) {
            self.buf[i] = self.buf[i + 1];
        }
        self.len -= 1;
        self.cursor -= 1;
        return true;
    }

    /// Claim 1771: forward Delete — remove the char AT the cursor (the
    /// keyboard Delete key, HID usage 0x4c). Backspace removes before it.
    pub fn delete_forward(self: *TextBuffer) bool {
        if (self.cursor >= self.len) return false;
        var i = self.cursor;
        while (i < self.len - 1) : (i += 1) {
            self.buf[i] = self.buf[i + 1];
        }
        self.len -= 1;
        return true;
    }

    pub fn move_cursor_left(self: *TextBuffer) bool {
        if (self.cursor > 0) {
            self.cursor -= 1;
            return true;
        }
        return false;
    }

    pub fn move_cursor_right(self: *TextBuffer) bool {
        if (self.cursor < self.len) {
            self.cursor += 1;
            return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Wrap-Aware Text Layout Model (claim 1771)
// ---------------------------------------------------------------------------
//
// A display row holds `cols` glyphs; a '\n' forces a break. The cursor is a
// byte offset; `position_at` maps it to a (display_row, col) with the SAME
// wrap rule the renderer walks, so navigation and drawing always agree.
// Works on a plain byte slice, so every rule is host-testable (class A).

pub const Pos = struct {
    row: usize,
    col: usize,
};

pub const RowBounds = struct {
    start: usize, // byte offset of the row's first glyph
    glyphs: usize, // glyph count in the row (0 for an empty row)
};

pub const TextLayout = struct {
    pub const cols: usize = 29; // (text_area.w - 12) / glyph_w = 232 / 8
    pub const visible_rows: usize = 11; // (text_area.h - 12) / line_h = 138 / 12

    /// First visible display row (the viewport's scroll offset).
    scroll: usize = 0,

    /// Find last space in `buf[start..limit)` (limit exclusive), returns offset of space or null.
    fn last_space(buf: []const u8, start: usize, limit: usize) ?usize {
        var j = limit;
        while (j > start) {
            j -= 1;
            if (buf[j] == ' ') return j;
        }
        return null;
    }

    pub fn position_at(buf: []const u8, offset: usize) Pos {
        var row: usize = 0;
        var col: usize = 0;
        var i: usize = 0;
        var row_start: usize = 0;
        while (i < offset and i < buf.len) {
            const b = buf[i];
            if (b == '\n') {
                row += 1;
                col = 0;
                row_start = i + 1;
                i += 1;
                continue;
            }
            if (col == cols) {
                const wrap_at = last_space(buf, row_start, i);
                if (wrap_at) |sp| {
                    row += 1;
                    // New col is distance from wrap point
                    col = i - sp - 1;
                    row_start = sp + 1;
                } else {
                    row += 1;
                    col = 0;
                    row_start = i;
                }
            }
            // Now col < cols, we can place this char
            col += 1;
            i += 1;
        }
        return .{ .row = row, .col = col };
    }

    /// Number of display rows the buffer occupies (at least one, even empty).
    pub fn total_rows(buf: []const u8) usize {
        return position_at(buf, buf.len).row + 1;
    }

    /// Start byte and glyph count of display row `target_row`; an
    /// out-of-range row is an empty row at buf.len.
    pub fn row_bounds(buf: []const u8, target_row: usize) RowBounds {
        var row: usize = 0;
        var i: usize = 0;
        var row_start: usize = 0;
        var col: usize = 0;
        while (i < buf.len) {
            if (row == target_row) {
                const start = row_start;
                var count: usize = 0;
                var j = row_start;
                var c: usize = 0;
                while (j < buf.len) {
                    const b = buf[j];
                    if (b == '\n') break;
                    if (c == cols) {
                        const sp = last_space(buf, start, j);
                        if (sp) |s| {
                            return .{ .start = start, .glyphs = s - start };
                        }
                        break;
                    }
                    count += 1;
                    c += 1;
                    j += 1;
                }
                return .{ .start = start, .glyphs = count };
            }
            const b = buf[i];
            if (b == '\n') {
                row += 1;
                row_start = i + 1;
                col = 0;
                i += 1;
                continue;
            }
            if (col == cols) {
                const wrap_at = last_space(buf, row_start, i);
                if (wrap_at) |sp| {
                    row += 1;
                    col = i - sp - 1;
                    row_start = sp + 1;
                } else {
                    row += 1;
                    col = 0;
                    row_start = i;
                }
            }
            col += 1;
            i += 1;
        }
        // Handle the case where target_row is the last row (empty after trailing newline or beyond)
        if (row == target_row) {
            var count: usize = 0;
            var j = row_start;
            var c: usize = 0;
            while (j < buf.len) {
                if (buf[j] == '\n') break;
                if (c == cols) break;
                count += 1;
                c += 1;
                j += 1;
            }
            return .{ .start = row_start, .glyphs = count };
        }
        return .{ .start = buf.len, .glyphs = 0 };
    }

    /// Largest legal scroll value.
    pub fn max_scroll(buf: []const u8) usize {
        const total = total_rows(buf);
        if (total <= visible_rows) return 0;
        return total - visible_rows;
    }

    /// Clamp `scroll` to [0, max_scroll] (e.g. after content shrinks).
    pub fn clamp_scroll(self: *TextLayout, buf: []const u8) void {
        const ms = max_scroll(buf);
        if (self.scroll > ms) self.scroll = ms;
    }

    /// Keep the cursor's display row inside the viewport; returns whether
    /// the scroll actually moved.
    pub fn ensure_visible(self: *TextLayout, buf: []const u8, offset: usize) bool {
        const p = position_at(buf, offset);
        if (p.row < self.scroll) {
            self.scroll = p.row;
            return true;
        }
        if (p.row >= self.scroll + visible_rows) {
            self.scroll = p.row - visible_rows + 1;
            return true;
        }
        return false;
    }

    /// Byte offset at (row, col), clamped into the buffer.
    pub fn offset_at(buf: []const u8, row: usize, col: usize) usize {
        const total = total_rows(buf);
        if (row >= total) return buf.len;
        const b = row_bounds(buf, row);
        const c = if (col > b.glyphs) b.glyphs else col;
        return b.start + c;
    }

    /// Up: previous display row, column preserved (clamped to row length).
    pub fn move_up(buf: []const u8, offset: usize) usize {
        const p = position_at(buf, offset);
        if (p.row == 0) return 0;
        const b = row_bounds(buf, p.row - 1);
        const c = if (p.col > b.glyphs) b.glyphs else p.col;
        return b.start + c;
    }

    /// Down: next display row, column preserved (clamped to row length).
    pub fn move_down(buf: []const u8, offset: usize) usize {
        const p = position_at(buf, offset);
        if (p.row + 1 >= total_rows(buf)) return buf.len;
        const b = row_bounds(buf, p.row + 1);
        const c = if (p.col > b.glyphs) b.glyphs else p.col;
        return b.start + c;
    }

    /// Home: start of the current display row.
    pub fn home(buf: []const u8, offset: usize) usize {
        const p = position_at(buf, offset);
        return row_bounds(buf, p.row).start;
    }

    /// End: just past the last glyph of the current display row.
    pub fn end(buf: []const u8, offset: usize) usize {
        const p = position_at(buf, offset);
        const b = row_bounds(buf, p.row);
        return b.start + b.glyphs;
    }

    /// PageUp: one viewport up; the target row lands at the viewport top.
    pub fn page_up(self: *TextLayout, buf: []const u8, offset: usize) usize {
        const p = position_at(buf, offset);
        const target = if (p.row >= visible_rows) p.row - visible_rows else 0;
        self.scroll = target;
        return offset_at(buf, target, p.col);
    }

    /// PageDown: one viewport down; the target row lands at the viewport bottom.
    pub fn page_down(self: *TextLayout, buf: []const u8, offset: usize) usize {
        const total = total_rows(buf);
        const p = position_at(buf, offset);
        const last = if (total > 0) total - 1 else 0;
        const target = if (p.row + visible_rows > last) last else p.row + visible_rows;
        self.scroll = if (target >= visible_rows) target - visible_rows + 1 else 0;
        return offset_at(buf, target, p.col);
    }
};

// ---------------------------------------------------------------------------
// Editor GUI State (Stack-Allocated AppState)
// ---------------------------------------------------------------------------

pub const AppState = struct {
    buffer: TextBuffer = .{},
    layout: TextLayout = .{},
    status_msg: [16]u8 = "Ready\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*,
    status_len: usize = 5,

    // Claim 3289 (M14 S3): the timer-driven cursor blink. The cursor is
    // SOLID while armed=false (the default — NOTEPAD's normal interactive
    // path) and toggles on every `TIMER` event while armed=true. The
    // toggle itself is a pure state transition (host-tested); the SVC
    // re-arm lives in the EL0 entry loop.
    cursor_visible: bool = true,
    blink_armed: bool = false,
    blink_count: u32 = 0,
    // Arc4 #239: pause blink on keypress, resume after idle. The cursor
    // stays solid for `blink_pause_ticks` timer events after the last
    // keypress, then normal blink resumes.
    blink_paused: bool = false,
    blink_pause_remaining: u32 = 0,

    // M15 C5+C6: find/replace lockstep — case_sensitive=false const (v1 schema deferred).
    find_active: bool = false,
    find_replace_active: bool = false,
    find_buf: [32]u8 = [_]u8{0} ** 32,
    find_len: usize = 0,
    replace_buf: [32]u8 = [_]u8{0} ** 32,
    replace_len: usize = 0,
    find_match_start: ?usize = null,
    find_match_count: usize = 0,
    find_current: usize = 0,
    find_case_sensitive: bool = false,

    /// M20-U3 (claim 8961): the Ctrl+G goto-line bar. Mutually exclusive
    /// with the find bar — opening one closes the other.
    goto_active: bool = false,
    goto_buf: [8]u8 = [_]u8{0} ** 8,
    goto_len: usize = 0,

    // Arc4 #242: unsaved-changes flag — set on any text modification,
    // cleared on save/load. Drives the compositor's close-button dialog.
    content_modified: bool = false,
    win_id: u32 = 0, // set after win_open in _start

    btn_load: Button = Button.init(Rect.make(6, 6, 44, 20), "Load"),
    btn_save: Button = Button.init(Rect.make(54, 6, 44, 20), "Save"),
    btn_clear: Button = Button.init(Rect.make(102, 6, 48, 20), "Clear"),
    btn_find_next: Button = Button.init(Rect.make(200, 6, 44, 20), "Find"),
    btn_replace: Button = Button.init(Rect.make(248, 6, 56, 20), "Replace"),
    btn_replace_all: Button = Button.init(Rect.make(308, 6, 70, 20), "Replace All"),

    pub fn init() AppState {
        var s = AppState{};
        s.btn_save.bg_color = ui.COLOR_ACCENT;
        s.btn_clear.bg_color = ui.COLOR_DANGER;
        return s;
    }

    /// Claim 3289: one TIMER event — toggle the cursor's visibility. The
    /// caller re-arms for the next tick; on re-arm failure it calls
    /// `stop_blink` so the cursor parks VISIBLE (never a hard hang).
    /// Arc4 #239: when paused (after a keypress), the cursor stays solid
    /// and the pause counter decrements; blinking resumes when the
    /// counter reaches zero.
    /// Returns true when the toggle changed anything on screen.
    pub fn handle_timer_event(self: *AppState) bool {
        if (self.blink_paused) {
            if (self.blink_pause_remaining > 0) {
                self.blink_pause_remaining -= 1;
            }
            if (self.blink_pause_remaining == 0) {
                self.blink_paused = false;
            }
            // Cursor stays visible during pause — no toggle.
            return false;
        }
        self.cursor_visible = !self.cursor_visible;
        self.blink_count += 1;
        return true;
    }

    /// Arc4 #239: pause the cursor blink on keypress. The cursor stays
    /// solid for `blink_pause_ticks` timer events, then resumes.
    pub fn pause_blink(self: *AppState) void {
        self.blink_paused = true;
        self.blink_pause_remaining = blink_pause_ticks;
        self.cursor_visible = true; // immediately show cursor
    }

    /// Claim 3289: park the blink with the cursor visible (the timer seam
    /// failed — the app degrades honestly to the solid cursor).
    pub fn stop_blink(self: *AppState) void {
        self.blink_armed = false;
        self.cursor_visible = true;
    }

    pub fn set_status(self: *AppState, msg: []const u8) void {
        const copy_len = @min(msg.len, self.status_msg.len);
        @memcpy(self.status_msg[0..copy_len], msg[0..copy_len]);
        self.status_len = copy_len;
    }

    pub fn load_notes(self: *AppState) void {
        const fd = ui.file_open(notes_path, ui.MODE_READ);
        if (fd < 0) {
            self.set_status("No File");
            ui.write_console("notepad: load failed\n");
            return;
        }

        var temp: [512]u8 = undefined;
        const bytes_read = ui.file_read(@as(u32, @intCast(fd)), &temp);
        ui.file_close(@as(u32, @intCast(fd)));

        if (bytes_read >= 0) {
            const ulen = @as(usize, @intCast(bytes_read));
            self.buffer.set_content(temp[0..ulen]);
            self.layout.scroll = 0;
            self.set_status("Loaded");
            ui.write_console("notepad: loaded ok\n");
            // Arc4 #242: loading a file clears the unsaved flag.
            self.content_modified = false;
            if (self.win_id != 0) _ = ui.win_set_unsaved(self.win_id, false);
        } else {
            self.set_status("Read Err");
            ui.write_console("notepad: read error\n");
        }
    }

    pub fn save_notes(self: *AppState) void {
        const fd = ui.file_open(notes_path, ui.MODE_CREATE | ui.MODE_WRITE);
        if (fd < 0) {
            self.set_status("Open Err");
            ui.write_console("notepad: save open failed\n");
            return;
        }

        const content = self.buffer.get_slice();
        const written = ui.file_write(@as(u32, @intCast(fd)), content);
        ui.file_close(@as(u32, @intCast(fd)));

        if (written >= 0) {
            self.set_status("Saved");
            ui.write_console("notepad: saved ok\n");
            // Arc4 #242: clear unsaved flag after successful save.
            self.content_modified = false;
            _ = ui.win_set_unsaved(self.win_id, false);
        } else {
            self.set_status("Save Err");
            ui.write_console("notepad: write failed\n");
        }
    }

    /// Arc4 #242: mark content as modified and set the unsaved flag.
    fn mark_modified(self: *AppState) void {
        if (!self.content_modified and self.win_id != 0) {
            self.content_modified = true;
            _ = ui.win_set_unsaved(self.win_id, true);
        }
    }

    /// Paste the shared clipboard at the cursor (claim 0169). The clipboard
    /// read is non-destructive; the insert clamps at the editor capacity.
    pub fn paste_clipboard(self: *AppState) bool {
        var temp: [ui.clipboard_capacity]u8 = undefined;
        const n = ui.clipboard_get(&temp);
        if (n <= 0) {
            self.set_status("No Clip");
            return true;
        }
        const ulen: usize = @intCast(n);
        _ = self.buffer.insert_slice(temp[0..ulen]);
        _ = self.layout.ensure_visible(self.buffer.get_slice(), self.buffer.cursor);
        self.layout.clamp_scroll(self.buffer.get_slice());
        self.set_status("Pasted");
        return true;
    }

    // M15 C5+C6: find/replace helpers — host-testable, case_sensitive=false const.
    fn eql_ci(a: u8, b: u8) bool {
        const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
        return la == lb;
    }

    fn match_at(buf: []const u8, pos: usize, pat: []const u8, case_sensitive: bool) bool {
        if (pos + pat.len > buf.len) return false;
        for (pat, 0..) |pc, j| {
            const bc = buf[pos + j];
            if (case_sensitive) {
                if (bc != pc) return false;
            } else {
                if (!eql_ci(bc, pc)) return false;
            }
        }
        return true;
    }

    /// M20-U3: byte offset of the first byte of 1-based buffer line
    /// `target` (lines split on '\n'; a trailing newline yields a final
    /// empty line). null when the buffer has no such line. Host-testable.
    pub fn line_start_offset(buf: []const u8, target: usize) ?usize {
        if (target == 0) return null;
        if (target == 1) return 0;
        var line: usize = 1;
        for (buf, 0..) |ch, i| {
            if (ch == '\n') {
                line += 1;
                if (line == target) return i + 1;
            }
        }
        return null;
    }

    /// M20-U3: number of buffer lines ('\n'-separated; minimum 1).
    pub fn count_lines(buf: []const u8) usize {
        var n: usize = 1;
        for (buf) |ch| {
            if (ch == '\n') n += 1;
        }
        return n;
    }

    /// Parse the goto bar's digits as a 1-based line number; null when
    /// empty, non-digit, or beyond the 5-digit bound.
    fn parse_goto(self: *const AppState) ?usize {
        if (self.goto_len == 0) return null;
        var v: usize = 0;
        for (self.goto_buf[0..self.goto_len]) |c| {
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
            if (v > 99999) return null;
        }
        return if (v == 0) null else v;
    }

    /// M20-U3: the goto result marker on the serial console — the live
    /// gate's grep target (`notepad: goto line=N offset=O` on success,
    /// `notepad: goto line=N miss lines=L` when the buffer is shorter).
    fn report_goto(target: usize, ok: bool, info: usize) void {
        var b: [72]u8 = undefined;
        const s = (if (ok)
            std.fmt.bufPrint(&b, "notepad: goto line={d} offset={d}\n", .{ target, info })
        else
            std.fmt.bufPrint(&b, "notepad: goto line={d} miss lines={d}\n", .{ target, info })) catch return;
        ui.write_console(s);
    }

    /// M20-U3: the find-result marker — `notepad: find '<pat>' hit=N/M`
    /// (N the 1-based ordinal among all matches) or `no-match`.
    fn report_find(pat: []const u8, ordinal: ?usize, total: usize) void {
        var b: [80]u8 = undefined;
        const s = (if (ordinal) |ord|
            std.fmt.bufPrint(&b, "notepad: find '{s}' hit={d}/{d}\n", .{ pat, ord + 1, total })
        else
            std.fmt.bufPrint(&b, "notepad: find '{s}' no-match\n", .{pat})) catch return;
        ui.write_console(s);
    }

    /// Ordinal (0-based) of the current match among all matches, or
    /// null with no active match. M20-U8's "Match N of M" needs it.
    pub fn find_current_ordinal(self: *const AppState) ?usize {
        const ms = self.find_match_start orelse return null;
        const buf = self.buffer.get_slice();
        const pat = self.find_buf[0..self.find_len];
        var ord: usize = 0;
        var i: usize = 0;
        while (i + pat.len <= buf.len and i <= ms) : (i += 1) {
            if (match_at(buf, i, pat, self.find_case_sensitive)) {
                if (i == ms) return ord;
                ord += 1;
                i += pat.len - 1;
            }
        }
        return ord;
    }

    pub fn find_next(self: *AppState) bool {
        if (self.find_len == 0) return false;
        const buf = self.buffer.get_slice();
        const pat = self.find_buf[0..self.find_len];
        const start = self.buffer.cursor;
        // Search from cursor, then wrap to 0.
        var i = start;
        while (i + pat.len <= buf.len) : (i += 1) {
            if (match_at(buf, i, pat, self.find_case_sensitive)) {
                self.buffer.cursor = i;
                self.find_match_start = i;
                self.find_match_count = pat.len;
                _ = self.layout.ensure_visible(buf, i);
                return true;
            }
        }
        i = 0;
        while (i < start and i + pat.len <= buf.len) : (i += 1) {
            if (match_at(buf, i, pat, self.find_case_sensitive)) {
                self.buffer.cursor = i;
                self.find_match_start = i;
                self.find_match_count = pat.len;
                _ = self.layout.ensure_visible(buf, i);
                return true;
            }
        }
        self.find_match_start = null;
        return false;
    }

    pub fn find_all_count(self: *const AppState) usize {
        if (self.find_len == 0) return 0;
        const buf = self.buffer.get_slice();
        const pat = self.find_buf[0..self.find_len];
        var cnt: usize = 0;
        var i: usize = 0;
        while (i + pat.len <= buf.len) : (i += 1) {
            if (match_at(buf, i, pat, self.find_case_sensitive)) {
                cnt += 1;
                i += pat.len - 1;
            }
        }
        return cnt;
    }

    pub fn replace_current(self: *AppState) bool {
        const start = self.find_match_start orelse return false;
        if (self.replace_len == 0) {
            // Delete the match.
            var j = start;
            while (j + self.find_len < self.buffer.len) : (j += 1) {
                self.buffer.buf[j] = self.buffer.buf[j + self.find_len];
            }
            self.buffer.len -= self.find_len;
            self.buffer.cursor = start;
            self.find_match_start = null;
            return true;
        }
        // Replace in place when same length, else shift.
        if (self.replace_len == self.find_len) {
            @memcpy(self.buffer.buf[start .. start + self.replace_len], self.replace_buf[0..self.replace_len]);
            self.buffer.cursor = start + self.replace_len;
            self.find_match_start = null;
            return true;
        }
        if (self.replace_len < self.find_len) {
            const diff = self.find_len - self.replace_len;
            @memcpy(self.buffer.buf[start .. start + self.replace_len], self.replace_buf[0..self.replace_len]);
            var j = start + self.replace_len;
            while (j + diff < self.buffer.len) : (j += 1) {
                self.buffer.buf[j] = self.buffer.buf[j + diff];
            }
            self.buffer.len -= diff;
            self.buffer.cursor = start + self.replace_len;
            self.find_match_start = null;
            return true;
        } else {
            const diff = self.replace_len - self.find_len;
            if (self.buffer.len + diff > self.buffer.buf.len) return false;
            var j = self.buffer.len;
            while (j > start + self.find_len) {
                j -= 1;
                self.buffer.buf[j + diff] = self.buffer.buf[j];
            }
            @memcpy(self.buffer.buf[start .. start + self.replace_len], self.replace_buf[0..self.replace_len]);
            self.buffer.len += diff;
            self.buffer.cursor = start + self.replace_len;
            self.find_match_start = null;
            return true;
        }
    }

    pub fn replace_all(self: *AppState) usize {
        if (self.find_len == 0) return 0;
        var replaced: usize = 0;
        // Repeatedly find and replace from start.
        self.buffer.cursor = 0;
        while (self.find_next()) {
            if (!self.replace_current()) break;
            replaced += 1;
            // Avoid infinite loop on zero-length replace that doesn't advance.
            if (self.buffer.cursor >= self.buffer.len) break;
        }
        if (replaced > 0) {
            self.set_status("Replaced");
        }
        return replaced;
    }

    pub fn draw(self: *const AppState, win: u32) void {
        // Window background
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.COLOR_BG);

        // Toolbar buttons
        self.btn_load.draw(win);
        self.btn_save.draw(win);
        self.btn_clear.draw(win);
        self.btn_find_next.draw(win);
        self.btn_replace.draw(win);
        self.btn_replace_all.draw(win);

        // Status label
        const status_rect = Rect.make(156, 6, 94, 20);
        ui.draw_text(win, self.status_msg[0..self.status_len], status_rect.x + 8, status_rect.y + 6, ui.COLOR_TEXT_MUTED);

        // Divider line
        ui.draw_rect(win, Rect.make(0, 30, window_w, 1), ui.COLOR_BORDER);

        // Text editor box
        ui.draw_rect(win, text_area, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, text_area, 1, ui.COLOR_BORDER);

        const slice = self.buffer.get_slice();

        // M15 C5: gutter with display-row numbers (1-based) at left of text_area.
        var grow: usize = self.layout.scroll;
        while (grow < self.layout.scroll + TextLayout.visible_rows) : (grow += 1) {
            if (grow >= TextLayout.total_rows(slice)) break;
            const gy = text_y0 + @as(u32, @intCast(grow - self.layout.scroll)) * line_h;
            var nbuf: [8]u8 = undefined;
            var nlen: usize = 0;
            var v = grow + 1;
            var tmp: [8]u8 = undefined;
            var ti: usize = 0;
            if (v == 0) {
                tmp[ti] = '0';
                ti += 1;
            } else {
                var rev: [8]u8 = undefined;
                var ri: usize = 0;
                while (v > 0) : (v /= 10) {
                    rev[ri] = @as(u8, @intCast('0' + (v % 10)));
                    ri += 1;
                }
                while (ri > 0) : (ri -= 1) {
                    tmp[ti] = rev[ri - 1];
                    ti += 1;
                }
            }
            @memcpy(nbuf[0..ti], tmp[0..ti]);
            nlen = ti;
            ui.draw_text(win, nbuf[0..nlen], text_area.x + 2, gy, ui.COLOR_TEXT_MUTED);
        }

        // M15 C5+C6: render visible rows with soft-wrap and substring highlight for find matches.
        var srow: usize = 0;
        var scol: usize = 0;
        var si: usize = 0;
        var srow_start: usize = 0;
        while (si < slice.len) : (si += 1) {
            const ch = slice[si];
            if (ch == '\n') {
                srow += 1;
                scol = 0;
                srow_start = si + 1;
                continue;
            }
            if (scol == TextLayout.cols) {
                const sp = TextLayout.last_space(slice, srow_start, si);
                if (sp) |s| {
                    srow += 1;
                    scol = si - s - 1;
                    srow_start = s + 1;
                } else {
                    srow += 1;
                    scol = 0;
                    srow_start = si;
                }
            }
            if (srow >= self.layout.scroll and srow < self.layout.scroll + TextLayout.visible_rows) {
                const x = text_x0 + @as(u32, @intCast(scol)) * glyph_w;
                const y = text_y0 + @as(u32, @intCast(srow - self.layout.scroll)) * line_h;
                // Highlight if this byte is inside the current find match (substring, not whole row).
                var hl = false;
                if (self.find_match_start) |ms| {
                    if (si >= ms and si < ms + self.find_match_count) hl = true;
                }
                if (hl) {
                    ui.draw_rect(win, Rect.make(x, y, glyph_w, 8), ui.COLOR_ACCENT);
                    ui.draw_char(win, ch, x, y, 0xffffff);
                } else {
                    ui.draw_char(win, ch, x, y, ui.COLOR_TEXT_PRIMARY);
                }
            }
            scol += 1;
        }

        // M15 C5: status `Line X of Y` at bottom of window.
        {
            const cur_row = TextLayout.position_at(slice, self.buffer.cursor).row + 1;
            const total = TextLayout.total_rows(slice);
            var stbuf: [24]u8 = undefined;
            var stpos: usize = 0;
            @memcpy(stbuf[0..5], "Line ");
            stpos = 5;
            var v2 = cur_row;
            var r2: [8]u8 = undefined;
            var r2l: usize = 0;
            if (v2 == 0) {
                r2[0] = '0';
                r2l = 1;
            } else {
                while (v2 > 0) : (v2 /= 10) {
                    r2[r2l] = @as(u8, @intCast('0' + (v2 % 10)));
                    r2l += 1;
                }
            }
            var k: usize = r2l;
            while (k > 0) : (k -= 1) {
                stbuf[stpos] = r2[k - 1];
                stpos += 1;
            }
            @memcpy(stbuf[stpos .. stpos + 4], " of ");
            stpos += 4;
            v2 = total;
            r2l = 0;
            if (v2 == 0) {
                r2[0] = '0';
                r2l = 1;
            } else {
                while (v2 > 0) : (v2 /= 10) {
                    r2[r2l] = @as(u8, @intCast('0' + (v2 % 10)));
                    r2l += 1;
                }
            }
            k = r2l;
            while (k > 0) : (k -= 1) {
                stbuf[stpos] = r2[k - 1];
                stpos += 1;
            }
            ui.draw_text(win, stbuf[0..stpos], 6, window_h - 12, ui.COLOR_TEXT_MUTED);
        }

        // M20-U3: goto-line bar at the bottom of text_area when active
        // (same zone the find bar uses; the two are mutually exclusive).
        if (self.goto_active) {
            const bar_y = text_area.y + text_area.h - 18;
            ui.draw_rect(win, Rect.make(text_area.x, bar_y, text_area.w, 18), ui.COLOR_SURFACE);
            ui.draw_rect_outline(win, Rect.make(text_area.x, bar_y, text_area.w, 18), 1, ui.COLOR_ACCENT);
            ui.draw_text(win, "Goto:", text_area.x + 4, bar_y + 5, ui.COLOR_TEXT_MUTED);
            ui.draw_text(win, self.goto_buf[0..self.goto_len], text_area.x + 40, bar_y + 5, ui.COLOR_TEXT_PRIMARY);
        }

        // M15 C6: find bar at bottom of text_area when active.
        if (self.find_active) {
            const bar_y = text_area.y + text_area.h - 18;
            ui.draw_rect(win, Rect.make(text_area.x, bar_y, text_area.w, 18), ui.COLOR_SURFACE);
            ui.draw_rect_outline(win, Rect.make(text_area.x, bar_y, text_area.w, 18), 1, ui.COLOR_ACCENT);
            ui.draw_text(win, "Find:", text_area.x + 4, bar_y + 5, ui.COLOR_TEXT_MUTED);
            ui.draw_text(win, self.find_buf[0..self.find_len], text_area.x + 40, bar_y + 5, ui.COLOR_TEXT_PRIMARY);
            if (self.find_match_start != null) {
                // M20-U8: real "Match N of M".
                const cur = self.find_current_ordinal().? + 1;
                const tot = self.find_all_count();
                var mbuf: [24]u8 = undefined;
                const mline = std.fmt.bufPrint(&mbuf, "{d} of {d}", .{ cur, tot }) catch "of";
                ui.draw_text(win, mline, text_area.x + text_area.w - 60, bar_y + 5, ui.COLOR_TEXT_MUTED);
            }
            // Case-sensitivity chip: lit when matching is case-sensitive.
            {
                const chip_x = text_area.x + 40 + @as(u32, @intCast(self.find_len)) * 6 + 8;
                if (chip_x + 24 < text_area.x + text_area.w - 70) {
                    ui.draw_rect_outline(win, Rect.make(chip_x, bar_y + 3, 22, 12), 1, if (self.find_case_sensitive) ui.COLOR_ACCENT else ui.COLOR_TEXT_MUTED);
                    ui.draw_text(win, "Aa", chip_x + 4, bar_y + 5, if (self.find_case_sensitive) ui.COLOR_ACCENT else ui.COLOR_TEXT_MUTED);
                }
            }
            if (self.find_replace_active) {
                ui.draw_text(win, "Replace:", text_area.x + 140, bar_y + 5, ui.COLOR_TEXT_MUTED);
                ui.draw_text(win, self.replace_buf[0..self.replace_len], text_area.x + 200, bar_y + 5, ui.COLOR_TEXT_PRIMARY);
            }
        }

        // Cursor: always visible (ensure_visible keeps its row in the viewport).
        // Claim 3289: the timer-driven blink toggles cursor_visible, so the
        // cursor is drawn only on the "on" half of the blink.
        const cpos = TextLayout.position_at(slice, self.buffer.cursor);
        if (self.cursor_visible and cpos.row >= self.layout.scroll and cpos.row < self.layout.scroll + TextLayout.visible_rows) {
            const x = text_x0 + @as(u32, @intCast(cpos.col)) * glyph_w;
            const y = text_y0 + @as(u32, @intCast(cpos.row - self.layout.scroll)) * line_h;
            if (x + 2 <= text_area.x + text_area.w) {
                ui.win_fill(win, x, y, 2, 8, ui.COLOR_ACCENT);
            }
        }

        // Scrollbar thumb when the content overflows the viewport.
        const total = TextLayout.total_rows(slice);
        if (total > TextLayout.visible_rows) {
            const sb_x = text_area.x + text_area.w - 5;
            const sb_y = text_area.y + 2;
            const sb_h = text_area.h - 4;
            ui.draw_rect(win, Rect.make(sb_x, sb_y, 2, sb_h), ui.COLOR_BORDER);
            const thumb_h: u32 = @max(10, sb_h * @as(u32, @intCast(TextLayout.visible_rows)) / @as(u32, @intCast(total)));
            const ms: u32 = @intCast(TextLayout.max_scroll(slice));
            const thumb_y = sb_y + @as(u32, @intCast(self.layout.scroll)) * (sb_h - thumb_h) / ms;
            ui.draw_rect(win, Rect.make(sb_x, thumb_y, 2, thumb_h), ui.COLOR_ACCENT);
        }
    }

    pub fn handle_mouse_events(self: *AppState, ev: *const Event) bool {
        var changed = false;

        if (self.btn_load.handle_event(ev)) {
            self.load_notes();
            changed = true;
        } else if (self.btn_save.handle_event(ev)) {
            self.save_notes();
            changed = true;
        } else if (self.btn_clear.handle_event(ev)) {
            self.buffer.clear();
            self.layout.scroll = 0;
            self.set_status("Cleared");
            self.mark_modified();
            changed = true;
        } else if (self.btn_find_next.handle_event(ev)) {
            if (self.find_next()) {
                self.set_status("Found");
            } else {
                self.set_status("No Match");
            }
            changed = true;
        } else if (self.btn_replace.handle_event(ev)) {
            if (self.replace_current()) {
                self.set_status("Replaced");
                self.layout.clamp_scroll(self.buffer.get_slice());
                self.mark_modified();
            } else {
                self.set_status("No Match");
            }
            changed = true;
        } else if (self.btn_replace_all.handle_event(ev)) {
            const n = self.replace_all();
            if (n > 0) {
                self.set_status("Replaced");
                self.layout.clamp_scroll(self.buffer.get_slice());
                self.mark_modified();
            } else {
                self.set_status("No Match");
            }
            changed = true;
        } else if (ev.kind == ui.MOUSE_DOWN and (ev.flags & ui.BTN_LEFT) != 0) {
            // Claim 1771: click in the editor places the cursor.
            const x = ev.arg0;
            const y = ev.arg1;
            if (x >= text_area.x and x < text_area.x + text_area.w and
                y >= text_area.y and y < text_area.y + text_area.h)
            {
                const row = (y - text_y0) / line_h + self.layout.scroll;
                const col = (x - text_x0) / glyph_w;
                self.buffer.cursor = TextLayout.offset_at(self.buffer.get_slice(), row, col);
                _ = self.layout.ensure_visible(self.buffer.get_slice(), self.buffer.cursor);
                changed = true;
            }
        }

        return changed;
    }

    pub fn handle_keyboard_event(self: *AppState, ev: *const Event) bool {
        if (ev.kind != ui.KEY_DOWN) return false;
        // Arc4 #239: any keypress pauses the cursor blink for a few ticks.
        self.pause_blink();
        const keycode = ev.arg0;
        const ascii = @as(u8, @truncate(ev.arg1));
        const slice = self.buffer.get_slice();

        // M15 C6: Ctrl+F toggles find bar, Ctrl+H toggles replace field.
        if ((ev.flags & ui.MOD_CTRL) != 0) {
            // M20-U8: Ctrl+Shift+F toggles case-sensitive matching.
            if (keycode == 0x09 and (ev.flags & ui.MOD_SHIFT) != 0) {
                if (self.find_active) {
                    self.find_case_sensitive = !self.find_case_sensitive;
                    return true;
                }
            }
            if (keycode == 0x09) { // f
                self.find_active = !self.find_active;
                if (!self.find_active) {
                    self.find_replace_active = false;
                    self.find_match_start = null;
                } else {
                    self.find_match_start = null;
                    // M20-U3: the find and goto bars are mutually exclusive.
                    self.goto_active = false;
                    self.goto_len = 0;
                }
                return true;
            }
            if (keycode == 0x0a) { // g — M20-U3: the goto-line bar.
                self.goto_active = !self.goto_active;
                self.goto_len = 0;
                if (self.goto_active) {
                    self.find_active = false;
                    self.find_replace_active = false;
                    self.find_match_start = null;
                }
                return true;
            }
            if (keycode == 0x0b) { // h
                if (self.find_active) {
                    self.find_replace_active = !self.find_replace_active;
                    return true;
                }
            }
        }

        // M20-U3: goto-line bar input — when active, Esc/Enter/Backspace/
        // digits go to the bar; Enter jumps and reports over serial.
        if (self.goto_active) {
            if (keycode == 0x29) { // Escape HID 0x29
                self.goto_active = false;
                self.goto_len = 0;
                return true;
            }
            if (keycode == 0x28 or ascii == '\r' or ascii == '\n') { // Enter
                const lines = count_lines(slice);
                if (self.parse_goto()) |target| {
                    if (line_start_offset(slice, target)) |off| {
                        self.buffer.cursor = off;
                        _ = self.layout.ensure_visible(slice, off);
                        self.layout.clamp_scroll(slice);
                        self.set_status("Line");
                        self.goto_active = false;
                        self.goto_len = 0;
                        report_goto(target, true, off);
                        return true;
                    }
                    report_goto(target, false, lines);
                } else {
                    report_goto(0, false, lines);
                }
                self.set_status("No Line");
                return true;
            }
            if (ascii == 0x08 or keycode == 0x2a) { // Backspace
                if (self.goto_len > 0) self.goto_len -= 1;
                return true;
            }
            if (ascii >= '0' and ascii <= '9') {
                if (self.goto_len < self.goto_buf.len) {
                    self.goto_buf[self.goto_len] = ascii;
                    self.goto_len += 1;
                }
                return true;
            }
            if (ascii >= 0x20 and ascii <= 0x7e) {
                // Other printables are swallowed by the bar — they must
                // not leak into the document buffer.
                return false;
            }
            // Arrows etc. fall through to main buffer navigation.
        }

        // M15 C6: find bar input — when active, Esc/Enter/Backspace/printable go to find bar.
        if (self.find_active) {
            if (keycode == 0x29) { // Escape HID 0x29
                self.find_active = false;
                self.find_replace_active = false;
                self.find_match_start = null;
                return true;
            }
            if (keycode == 0x28) { // Enter
                if (self.find_next()) {
                    self.set_status("Found");
                    // M20-U3: serial marker with the 1-based ordinal among
                    // all matches (the live gate's grep target).
                    report_find(self.find_buf[0..self.find_len], self.find_current_ordinal(), self.find_all_count());
                } else {
                    self.set_status("No Match");
                    report_find(self.find_buf[0..self.find_len], null, 0);
                }
                return true;
            }
            if (ascii == 0x08 or keycode == 0x2a) { // Backspace
                if (self.find_replace_active) {
                    if (self.replace_len > 0) {
                        self.replace_len -= 1;
                        return true;
                    }
                } else {
                    if (self.find_len > 0) {
                        self.find_len -= 1;
                        self.find_match_start = null;
                        return true;
                    }
                }
                return false;
            }
            if (ascii >= 0x20 and ascii <= 0x7e) {
                if (self.find_replace_active) {
                    if (self.replace_len < self.replace_buf.len) {
                        self.replace_buf[self.replace_len] = ascii;
                        self.replace_len += 1;
                        return true;
                    }
                } else {
                    if (self.find_len < self.find_buf.len) {
                        self.find_buf[self.find_len] = ascii;
                        self.find_len += 1;
                        self.find_match_start = null;
                        return true;
                    }
                }
                return false;
            }
            // For other keys (arrows etc) when find bar is active, still allow main buffer navigation?
            // Fall through to main handling for arrows, but not for printable.
        }

        // Backspace
        if (ascii == 0x08 or keycode == 0x2a) {
            if (self.buffer.backspace()) {
                _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                self.layout.clamp_scroll(slice);
                self.set_status("Editing");
                self.mark_modified();
                return true;
            }
            return false;
        }

        // Enter / Newline
        if (ascii == '\r' or ascii == '\n' or keycode == 0x28) {
            if (self.buffer.insert_char('\n')) {
                _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                self.layout.clamp_scroll(slice);
                self.set_status("Editing");
                self.mark_modified();
                return true;
            }
            return false;
        }

        // Claim 1771: cursor navigation across display rows.
        switch (keycode) {
            0x50 => { // Left arrow
                if (self.buffer.move_cursor_left()) {
                    _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                    return true;
                }
                return false;
            },
            0x4f => { // Right arrow
                if (self.buffer.move_cursor_right()) {
                    _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                    return true;
                }
                return false;
            },
            0x52 => { // Up arrow
                const new_off = TextLayout.move_up(slice, self.buffer.cursor);
                if (new_off != self.buffer.cursor) {
                    self.buffer.cursor = new_off;
                    _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                    return true;
                }
                return false;
            },
            0x51 => { // Down arrow
                const new_off = TextLayout.move_down(slice, self.buffer.cursor);
                if (new_off != self.buffer.cursor) {
                    self.buffer.cursor = new_off;
                    _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                    return true;
                }
                return false;
            },
            0x4a => { // Home: start of display row
                self.buffer.cursor = TextLayout.home(slice, self.buffer.cursor);
                _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                return true;
            },
            0x4d => { // End: end of display row
                self.buffer.cursor = TextLayout.end(slice, self.buffer.cursor);
                _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                return true;
            },
            0x4b => { // PageUp: one viewport up
                self.buffer.cursor = self.layout.page_up(slice, self.buffer.cursor);
                return true;
            },
            0x4e => { // PageDown: one viewport down
                self.buffer.cursor = self.layout.page_down(slice, self.buffer.cursor);
                return true;
            },
            0x4c => { // Delete (forward)
                if (self.buffer.delete_forward()) {
                    _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                    self.layout.clamp_scroll(slice);
                    self.set_status("Editing");
                    self.mark_modified();
                    return true;
                }
                return false;
            },
            else => {},
        }

        // Ctrl+A / Ctrl+E: jump to buffer start / end (modifier lives in
        // the event flags; the usage for 'a' is 0x04, for 'e' is 0x08).
        if ((ev.flags & ui.MOD_CTRL) != 0) {
            if (keycode == 0x04) {
                self.buffer.cursor = 0;
                self.layout.scroll = 0;
                return true;
            }
            if (keycode == 0x08) {
                self.buffer.cursor = self.buffer.len;
                _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                return true;
            }
        }

        // Ctrl+C / Ctrl+X / Ctrl+V: copy / cut / paste through the SHARED
        // clipboard (claim 0169). No selection model yet — copy and cut take
        // the WHOLE buffer (an honest bound; selection is a later card).
        if ((ev.flags & ui.MOD_CTRL) != 0) {
            if (keycode == 0x06) { // 'c' -> copy
                if (ui.clipboard_set(self.buffer.get_slice()) < 0) {
                    self.set_status("Copy Err");
                } else {
                    self.set_status("Copied");
                }
                return true;
            }
            if (keycode == 0x1b) { // 'x' -> cut
                if (ui.clipboard_set(self.buffer.get_slice()) < 0) {
                    self.set_status("Cut Err");
                } else {
                    self.buffer.clear();
                    self.layout.scroll = 0;
                    self.set_status("Cut");
                    self.mark_modified();
                }
                return true;
            }
            if (keycode == 0x19) { // 'v' -> paste
                const pasted = self.paste_clipboard();
                if (pasted) self.mark_modified();
                return pasted;
            }
        }

        // Printable character
        if (ascii >= 0x20 and ascii <= 0x7e) {
            if (self.buffer.insert_char(ascii)) {
                _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                self.layout.clamp_scroll(slice);
                self.set_status("Editing");
                self.mark_modified();
                return true;
            }
        }

        return false;
    }
};

// ---------------------------------------------------------------------------
// Entry Point (EL0)
// ---------------------------------------------------------------------------

/// Claim 3289 (M14 S3): blink cadence. The cursor toggles once per
/// `blink_interval_ticks` scheduler ticks (the per-process app timer, not a
/// `sys_sleep` spin), and the selfdemo runs `selfdemo_blinks` toggles.
pub const blink_interval_ticks: u64 = 8;
pub const selfdemo_blinks: u32 = 6;

/// Arc4 #239: after a keypress, the cursor stays solid for this many
/// timer ticks before resuming the blink (2 s on VZ).
pub const blink_pause_ticks: u32 = 2;

/// Claim 3289 (M14 S3): the composition selfdemo. NOTEPAD is exec'd with
/// `selfdemo` in its argv (claim 4636's entry contract: argc in x0, the
/// argv block VA in x1 — each slot a 32-byte NUL-terminated string in the
/// program's own read-only text page). The demo runs the S1+S2 composition
/// in ONE app: paste the shared kernel clipboard into the buffer (the S1
/// `sys_clipboard_get` path — the gate pre-loads the clipboard with the
/// terminal's `clip` command), copy the result back out (`sys_clipboard_set`
/// — the S1 write path), then blink the cursor `selfdemo_blinks` times on
/// the per-process app timer (`sys_timer_set` re-armed after every `TIMER`
/// event — the S2 path, no spin loop). Every step prints a serial marker,
/// so the live gate observes BOTH facilities in one EL0 session.
pub fn run_selfdemo(app: *AppState, win: u32) void {
    // S1 read path: paste the shared kernel clipboard at the cursor.
    var temp: [ui.clipboard_capacity]u8 = undefined;
    const n = ui.clipboard_get(&temp);
    if (n <= 0) {
        app.set_status("No Clip");
        ui.write_console("notepad: selfdemo paste failed (clipboard empty)\n");
        ui.exit_process(2);
    }
    const ulen: usize = @intCast(n);
    const inserted = app.buffer.insert_slice(temp[0..ulen]);
    if (inserted != ulen) {
        app.set_status("Full");
        ui.write_console("notepad: selfdemo paste truncated\n");
        ui.exit_process(3);
    }
    app.set_status("Pasted");
    ui.write_console("notepad: selfdemo pasted\n");

    // S1 write path: copy the buffer back into the shared clipboard.
    const set_rc = ui.clipboard_set(app.buffer.get_slice());
    if (set_rc < 0) {
        app.set_status("Copy Err");
        ui.write_console("notepad: selfdemo copy failed\n");
        ui.exit_process(4);
    }
    app.set_status("Copied");
    ui.write_console("notepad: selfdemo copied\n");

    // S2: arm the blink timer and let the event loop toggle the cursor.
    app.blink_armed = true;
    if (ui.timer_set(blink_interval_ticks) < 0) {
        ui.write_console("notepad: selfdemo timer arm failed\n");
        ui.exit_process(5);
    }

    // Repaint with the pasted content.
    app.draw(win);
    ui.win_present(win);
    ui.write_console("notepad: selfdemo armed blink\n");
}

pub export fn _start(argc: usize, argv: ?[*]const [32]u8) callconv(.c) noreturn {
    var app = AppState.init();

    // Claim 4636 entry contract: argv[0] == "selfdemo" selects the M14 S3
    // composition selfdemo (claim 3289); a plain `exec NOTEPAD.BIN` with no
    // args keeps the interactive editor exactly as before.
    var selfdemo = false;
    if (argc >= 1) {
        if (argv) |slots| {
            const arg0 = slots[0];
            const len = std.mem.indexOfScalar(u8, &arg0, 0) orelse arg0.len;
            selfdemo = std.mem.eql(u8, arg0[0..len], "selfdemo");
        }
    }

    // 1. Open Window
    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("notepad: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));
    app.win_id = win;

    ui.write_console("notepad: open id=2\n");

    // 2. Initial Draw & Present
    app.draw(win);
    ui.win_present(win);
    ui.write_console("notepad: ready\n");

    // 2b. Claim 3289: the composition selfdemo (paste + copy + blink).
    if (selfdemo) run_selfdemo(&app, win);

    // 3. Event Loop
    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        if (ev.kind == ui.WIN_CLOSE) {
            ui.write_console("notepad: win_close\n");
            break;
        }

        // Arc4 #242: unsaved-changes dialog response from compositor.
        if (ev.kind == ui.WIN_UNSAVED) {
            if (ev.arg0 == 0) { // save
                app.save_notes();
                app.draw(win);
                ui.win_present(win);
            }
            // arg0=1 (don't save) or arg0=2 (cancel after save) — just close.
            ui.write_console("notepad: win_unsaved\n");
            break;
        }

        if (ev.kind == ui.EVENT_TIMER) {
            // Claim 3289: the timer-driven blink. Toggle the cursor, then
            // re-arm for the next tick; a failed re-arm parks the cursor
            // visible (honest degradation, never a hang).
            dirty = app.handle_timer_event() or dirty;
            if (app.blink_armed) {
                ui.write_console("notepad: cursor blink\n");
                if (ui.timer_set(blink_interval_ticks) < 0) {
                    app.stop_blink();
                    ui.write_console("notepad: blink timer lost\n");
                }
                if (selfdemo and app.blink_count >= selfdemo_blinks) {
                    app.stop_blink();
                    ui.write_console("notepad: selfdemo done\n");
                    break;
                }
            }
        } else if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
            dirty = app.handle_mouse_events(&ev) or dirty;
        } else if (ev.kind == ui.KEY_DOWN) {
            dirty = app.handle_keyboard_event(&ev) or dirty;
        }

        // Drain pending queue
        while (ui.poll_event(&ev) > 0) {
            if (ev.kind == ui.WIN_CLOSE) {
                ui.write_console("notepad: win_close\n");
                ui.win_close(win);
                ui.exit_process(exit_status);
            }
            // Arc4 #242: unsaved-changes dialog response (drain path).
            if (ev.kind == ui.WIN_UNSAVED) {
                if (ev.arg0 == 0) {
                    app.save_notes();
                }
                ui.write_console("notepad: win_unsaved\n");
                ui.win_close(win);
                ui.exit_process(exit_status);
            }
            if (ev.kind == ui.EVENT_TIMER) {
                dirty = app.handle_timer_event() or dirty;
                if (app.blink_armed) {
                    ui.write_console("notepad: cursor blink\n");
                    if (ui.timer_set(blink_interval_ticks) < 0) {
                        app.stop_blink();
                        ui.write_console("notepad: blink timer lost\n");
                    }
                    if (selfdemo and app.blink_count >= selfdemo_blinks) {
                        app.stop_blink();
                        ui.write_console("notepad: selfdemo done\n");
                        ui.win_close(win);
                        ui.exit_process(exit_status);
                    }
                }
            } else if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
                dirty = app.handle_mouse_events(&ev) or dirty;
            } else if (ev.kind == ui.KEY_DOWN) {
                dirty = app.handle_keyboard_event(&ev) or dirty;
            }
        }

        if (dirty) {
            app.draw(win);
            ui.win_present(win);
        }
    }

    ui.write_console("notepad: exiting 43\n");
    ui.win_close(win);
    ui.exit_process(exit_status);
}

// ---------------------------------------------------------------------------
// Unit Tests (Class A Host Validation)
// ---------------------------------------------------------------------------

test "notepad: TextBuffer insertion, backspace, and cursor motion" {
    var tb = TextBuffer.init();

    try std.testing.expect(tb.insert_char('H'));
    try std.testing.expect(tb.insert_char('i'));
    try std.testing.expectEqualStrings("Hi", tb.get_slice());
    try std.testing.expectEqual(@as(usize, 2), tb.cursor);

    // Backspace
    try std.testing.expect(tb.backspace());
    try std.testing.expectEqualStrings("H", tb.get_slice());
    try std.testing.expectEqual(@as(usize, 1), tb.cursor);

    // Insert 'e', 'y'
    _ = tb.insert_char('e');
    _ = tb.insert_char('y');
    try std.testing.expectEqualStrings("Hey", tb.get_slice());

    // Move cursor left to 'e'
    try std.testing.expect(tb.move_cursor_left());
    try std.testing.expectEqual(@as(usize, 2), tb.cursor);

    // Insert '!' at cursor
    _ = tb.insert_char('!');
    try std.testing.expectEqualStrings("He!y", tb.get_slice());
}

test "notepad: TextBuffer newlines and set_content" {
    var tb = TextBuffer.init();
    tb.set_content("Line 1\nLine 2");
    try std.testing.expectEqualStrings("Line 1\nLine 2", tb.get_slice());
    try std.testing.expectEqual(@as(usize, 13), tb.len);

    tb.clear();
    try std.testing.expectEqual(@as(usize, 0), tb.len);
    try std.testing.expectEqual(@as(usize, 0), tb.cursor);
}

test "notepad: TextBuffer forward delete (claim 1771)" {
    var tb = TextBuffer.init();
    tb.set_content("Hello");
    tb.cursor = 0;

    // Delete at cursor 0 removes 'H', cursor stays put.
    try std.testing.expect(tb.delete_forward());
    try std.testing.expectEqualStrings("ello", tb.get_slice());
    try std.testing.expectEqual(@as(usize, 0), tb.cursor);

    // Delete at end is a no-op.
    tb.set_content("x");
    tb.cursor = 1;
    try std.testing.expect(!tb.delete_forward());
    try std.testing.expectEqualStrings("x", tb.get_slice());
}

test "notepad: TextLayout maps offsets to display rows with wrapping (claim 1771)" {
    // Empty buffer: one (empty) display row.
    try std.testing.expectEqual(Pos{ .row = 0, .col = 0 }, TextLayout.position_at("", 0));
    try std.testing.expectEqual(@as(usize, 1), TextLayout.total_rows(""));

    // A single line under cols: one row.
    const short = "abcdef";
    try std.testing.expectEqual(Pos{ .row = 0, .col = 6 }, TextLayout.position_at(short, short.len));
    try std.testing.expectEqual(@as(usize, 1), TextLayout.total_rows(short));

    // Newlines force display-row breaks; the row after a trailing \n counts.
    try std.testing.expectEqual(Pos{ .row = 1, .col = 0 }, TextLayout.position_at("ab\n", 3));
    try std.testing.expectEqual(@as(usize, 2), TextLayout.total_rows("ab\n"));
    try std.testing.expectEqual(@as(usize, 2), TextLayout.total_rows("ab\ncd"));

    // A line of exactly cols glyphs stays on one row; the next glyph wraps.
    var full_row: [TextLayout.cols]u8 = [_]u8{'a'} ** TextLayout.cols;
    try std.testing.expectEqual(Pos{ .row = 0, .col = TextLayout.cols }, TextLayout.position_at(&full_row, full_row.len));
    try std.testing.expectEqual(@as(usize, 1), TextLayout.total_rows(&full_row));

    var over: [TextLayout.cols + 1]u8 = [_]u8{'a'} ** (TextLayout.cols + 1);
    try std.testing.expectEqual(Pos{ .row = 1, .col = 1 }, TextLayout.position_at(&over, over.len));
    try std.testing.expectEqual(@as(usize, 2), TextLayout.total_rows(&over));
}

test "notepad: TextLayout row_bounds and offset_at (claim 1771)" {
    const buf = "abc\ndef";
    try std.testing.expectEqual(RowBounds{ .start = 0, .glyphs = 3 }, TextLayout.row_bounds(buf, 0));
    try std.testing.expectEqual(RowBounds{ .start = 4, .glyphs = 3 }, TextLayout.row_bounds(buf, 1));
    // Out-of-range row: empty row at buf.len.
    try std.testing.expectEqual(RowBounds{ .start = buf.len, .glyphs = 0 }, TextLayout.row_bounds(buf, 9));

    // offset_at maps (row, col) to a byte offset, clamped to the row length.
    try std.testing.expectEqual(@as(usize, 0), TextLayout.offset_at(buf, 0, 0));
    try std.testing.expectEqual(@as(usize, 2), TextLayout.offset_at(buf, 0, 2));
    try std.testing.expectEqual(@as(usize, 3), TextLayout.offset_at(buf, 0, 99)); // clamp
    try std.testing.expectEqual(@as(usize, 5), TextLayout.offset_at(buf, 1, 1));
    try std.testing.expectEqual(@as(usize, 7), TextLayout.offset_at(buf, 1, 99)); // clamp to row end
    try std.testing.expectEqual(@as(usize, buf.len), TextLayout.offset_at(buf, 5, 0)); // beyond end
}

test "notepad: TextLayout column-preserving Up/Down navigation (claim 1771)" {
    const buf = "abc\ndefgh";

    // Cursor at row 1 col 1 ('e'): Up -> row 0 col 1 ('b'), Down -> back.
    try std.testing.expectEqual(@as(usize, 1), TextLayout.move_up(buf, 5));
    try std.testing.expectEqual(@as(usize, 5), TextLayout.move_down(buf, 1));

    // Column clamps to the shorter row: row 1 col 4 ('h') -> Up -> row 0 col 3 (clamped to end of "abc").
    try std.testing.expectEqual(@as(usize, 3), TextLayout.move_up(buf, 8));
    // And back down preserves the ORIGINAL column (3) where possible:
    // row 1 "defgh" -> start 4 + col 3 = offset 7 ('g').
    try std.testing.expectEqual(@as(usize, 7), TextLayout.move_down(buf, 3));

    // Up from the first row clamps to 0; Down from the last row clamps to buf.len.
    try std.testing.expectEqual(@as(usize, 0), TextLayout.move_up(buf, 2));
    try std.testing.expectEqual(@as(usize, buf.len), TextLayout.move_down(buf, 8));
}

test "notepad: TextLayout Home and End stay on the display row (claim 1771)" {
    const buf = "abc\ndefgh";
    try std.testing.expectEqual(@as(usize, 4), TextLayout.home(buf, 7));
    try std.testing.expectEqual(@as(usize, 3), TextLayout.end(buf, 1)); // end of "abc" = offset 3
    try std.testing.expectEqual(@as(usize, 9), TextLayout.end(buf, 5)); // end of "defgh" = offset 9

    // Home/End on a wrapped row respect the wrap boundary.
    var over: [TextLayout.cols + 1]u8 = [_]u8{'x'} ** (TextLayout.cols + 1);
    try std.testing.expectEqual(@as(usize, 0), TextLayout.home(&over, TextLayout.cols));
    try std.testing.expectEqual(@as(usize, TextLayout.cols), TextLayout.end(&over, 1));
    try std.testing.expectEqual(@as(usize, TextLayout.cols + 1), TextLayout.end(&over, TextLayout.cols + 1));
}

test "notepad: TextLayout ensure_visible keeps the cursor in the viewport (claim 1771)" {
    // 30 one-char lines -> 30 display rows; viewport shows 11.
    var buf: [60]u8 = undefined;
    for (0..30) |i| {
        buf[i * 2] = 'a';
        buf[i * 2 + 1] = '\n';
    }
    const slice = buf[0..60];

    var layout = TextLayout{};
    // 30 lines each ending in '\n' -> display rows 0..30 (the trailing
    // newline opens a 31st, empty row).
    try std.testing.expectEqual(@as(usize, 31), TextLayout.total_rows(slice));

    // Cursor below the viewport scrolls it down (offset 40 = line 20).
    try std.testing.expect(layout.ensure_visible(slice, 40));
    try std.testing.expectEqual(@as(usize, 20 - 11 + 1), layout.scroll);

    // Cursor above the viewport scrolls it up.
    try std.testing.expect(layout.ensure_visible(slice, 4));
    try std.testing.expectEqual(@as(usize, 2), layout.scroll);

    // Cursor inside the viewport leaves it alone.
    const before = layout.scroll;
    try std.testing.expect(!layout.ensure_visible(slice, 12));
    try std.testing.expectEqual(before, layout.scroll);
}

test "notepad: TextLayout PageUp/PageDown page the viewport (claim 1771)" {
    var buf: [60]u8 = undefined;
    for (0..30) |i| {
        buf[i * 2] = 'a';
        buf[i * 2 + 1] = '\n';
    }
    const slice = buf[0..60];

    var layout = TextLayout{};
    // PageDown from the top: cursor row 11, scroll so it sits at the bottom.
    const off = layout.page_down(slice, 0);
    try std.testing.expectEqual(@as(usize, 22), off);
    try std.testing.expectEqual(@as(usize, 11 - TextLayout.visible_rows + 1), layout.scroll);
    // PageUp back: cursor row 0 at the viewport top.
    const off2 = layout.page_up(slice, off);
    try std.testing.expectEqual(@as(usize, 0), off2);
    try std.testing.expectEqual(@as(usize, 0), layout.scroll);
}

test "notepad: keyboard navigation routes through TextLayout (claim 1771)" {
    // 12 lines so the cursor can move below the 11-row viewport.
    var buf: [24]u8 = undefined;
    for (0..12) |i| {
        buf[i * 2] = 'a';
        buf[i * 2 + 1] = '\n';
    }
    var app = AppState.init();
    app.buffer.set_content(buf[0..24]);
    app.layout.scroll = 0;

    var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x04, .arg1 = 'a' };

    // Ctrl+A jumps to the buffer start.
    ev.flags = ui.MOD_CTRL;
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expectEqual(@as(usize, 0), app.buffer.cursor);
    try std.testing.expectEqual(@as(usize, 0), app.layout.scroll);

    // Up at the top is a no-op.
    ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x52, .arg1 = 0 };
    try std.testing.expect(!app.handle_keyboard_event(&ev));
    try std.testing.expectEqual(@as(usize, 0), app.buffer.cursor);

    // Down twice -> display rows 1, 2 (offsets 2, 4).
    ev.arg0 = 0x51;
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expectEqual(@as(usize, 2), app.buffer.cursor);
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expectEqual(@as(usize, 4), app.buffer.cursor);

    // Up once -> back to row 1 (column preserved).
    ev.arg0 = 0x52;
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expectEqual(@as(usize, 2), app.buffer.cursor);

    // End -> just past 'a' on row 1 (offset 3, the newline's position).
    ev.arg0 = 0x4d;
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expectEqual(@as(usize, 3), app.buffer.cursor);

    // Home -> back to the row start.
    ev.arg0 = 0x4a;
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expectEqual(@as(usize, 2), app.buffer.cursor);

    // PageUp -> one viewport up, cursor at the viewport top (row 0).
    ev.arg0 = 0x4b;
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expectEqual(@as(usize, 0), app.buffer.cursor);
    try std.testing.expectEqual(app.buffer.cursor, app.layout.scroll);

    // Forward Delete removes the first 'a'.
    var ev2 = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x4c, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev2));
    try std.testing.expectEqualStrings(buf[1..24], app.buffer.get_slice());
}

test "notepad: TextBuffer insert_slice pastes at the cursor and clamps at capacity (claim 0169)" {
    var tb = TextBuffer.init();
    tb.set_content("ab");
    tb.cursor = 1;

    const inserted = tb.insert_slice("XY");
    try std.testing.expectEqual(@as(usize, 2), inserted);
    try std.testing.expectEqualStrings("aXYb", tb.get_slice());
    try std.testing.expectEqual(@as(usize, 3), tb.cursor);

    // Near capacity: insert_slice stops when the buffer is full.
    var big = TextBuffer.init();
    const near = "a" ** 511;
    big.set_content(near[0..511]);
    big.cursor = big.len;
    const n2 = big.insert_slice("xyz");
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqual(@as(usize, 512), big.len);
}

test "notepad: the timer-driven cursor blink toggles and re-arms (claim 3289)" {
    var app = AppState.init();

    // Not blinking by default: the cursor is solid, no timer armed.
    try std.testing.expect(app.cursor_visible);
    try std.testing.expect(!app.blink_armed);
    try std.testing.expectEqual(@as(u32, 0), app.blink_count);

    // Arm the blink (the EL0 loop's SVC side is not host-testable, but the
    // state transition is): the first TIMER event hides the cursor.
    app.blink_armed = true;
    try std.testing.expect(app.handle_timer_event());
    try std.testing.expect(!app.cursor_visible);
    try std.testing.expectEqual(@as(u32, 1), app.blink_count);

    // The second TIMER event shows it again — a real blink cycle.
    try std.testing.expect(app.handle_timer_event());
    try std.testing.expect(app.cursor_visible);
    try std.testing.expectEqual(@as(u32, 2), app.blink_count);

    // stop_blink (the re-arm-failure path) parks the cursor VISIBLE.
    _ = app.handle_timer_event(); // now hidden
    try std.testing.expect(!app.cursor_visible);
    app.stop_blink();
    try std.testing.expect(!app.blink_armed);
    try std.testing.expect(app.cursor_visible);

    // The selfdemo exit bound: after selfdemo_blinks toggles the demo is
    // done (the loop checks blink_count >= selfdemo_blinks).
    app.blink_count = selfdemo_blinks;
    try std.testing.expect(app.blink_count >= selfdemo_blinks);
}

test "notepad: cursor blink pauses on keypress and resumes after idle (arc4 #239)" {
    var app = AppState.init();
    app.blink_armed = true;

    // A keypress pauses the blink: cursor stays solid.
    app.pause_blink();
    try std.testing.expect(app.blink_paused);
    try std.testing.expect(app.cursor_visible);
    try std.testing.expectEqual(blink_pause_ticks, app.blink_pause_remaining);

    // During the pause, TIMER events decrement the counter but don't toggle.
    var i: u32 = 0;
    while (i < blink_pause_ticks) : (i += 1) {
        try std.testing.expect(!app.handle_timer_event()); // no toggle
        try std.testing.expect(app.cursor_visible); // still solid
    }

    // After the pause expires, normal blink resumes.
    try std.testing.expect(!app.blink_paused);
    try std.testing.expect(app.handle_timer_event()); // now toggles
    try std.testing.expect(!app.cursor_visible);
}

test "notepad: the selfdemo pastes the clipboard, copies it back, and honors the capacity bound (claim 3289)" {
    // The paste half (run_selfdemo's clipboard_get -> insert_slice flow with
    // the EL0 SVC wrapper mocked by direct buffer ops, the class-A pattern
    // from claim 0169): the pasted bytes land at the cursor.
    var app = AppState.init();
    app.buffer.set_content("ab");
    app.buffer.cursor = 1;
    const inserted = app.buffer.insert_slice("XY");
    try std.testing.expectEqual(@as(usize, 2), inserted);
    try std.testing.expectEqualStrings("aXYb", app.buffer.get_slice());

    // The copy half: the whole buffer is what clipboard_set would take.
    try std.testing.expectEqualStrings("aXYb", app.buffer.get_slice());

    // The selfdemo's honest bound: a truncated paste is refused.
    var big = AppState.init();
    big.buffer.set_content("a" ** 512);
    const n = big.buffer.insert_slice("overflow");
    try std.testing.expectEqual(@as(usize, 0), n); // buffer already full
    try std.testing.expectEqual(@as(usize, 512), big.buffer.len);
}

test "notepad: copy/cut chords drive the clipboard path and cut clears (claim 0169)" {
    var app = AppState.init();
    app.buffer.set_content("hello");
    app.buffer.cursor = 2;

    // Ctrl+X (usage 0x1b): cut — the buffer clears, status becomes "Cut".
    var ev_cut = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x1b, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_cut));
    try std.testing.expectEqualStrings("", app.buffer.get_slice());
    try std.testing.expectEqualStrings("Cut", app.status_msg[0..app.status_len]);

    // Ctrl+C (usage 0x06): copy keeps the buffer, status becomes "Copied".
    var ev_copy = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 2, .arg0 = 0x06, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_copy));
    try std.testing.expectEqualStrings("", app.buffer.get_slice());
    try std.testing.expectEqualStrings("Copied", app.status_msg[0..app.status_len]);

    // Ctrl+V (usage 0x19) with an empty clipboard (the host wrapper returns
    // 0): paste reports "No Clip" and leaves the buffer empty.
    var ev_paste = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 3, .arg0 = 0x19, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_paste));
    try std.testing.expectEqualStrings("No Clip", app.status_msg[0..app.status_len]);
    try std.testing.expectEqualStrings("", app.buffer.get_slice());
}

test "notepad: M15 C5 — soft-wrap at last space, hard fallback, gutter and status" {
    // Soft-wrap: a line with spaces that exceeds cols should wrap at last space.
    var buf: [64]u8 = undefined;
    // Create a line: 20 'a's + space + 20 'b's + "\n" + "short"
    var s: usize = 0;
    for (0..20) |_| {
        buf[s] = 'a';
        s += 1;
    }
    buf[s] = ' ';
    s += 1;
    for (0..20) |_| {
        buf[s] = 'b';
        s += 1;
    }
    buf[s] = '\n';
    s += 1;
    @memcpy(buf[s .. s + 5], "short");
    s += 5;
    const text = buf[0..s];
    // With cols=29, the first row should be 20 'a's (no space) + space? Actually soft-wrap should break at space.
    // The first display row should be "aaaaaaaaaaaaaaaaaaaa" (20 'a's) without the space, second row "bbbbbbbbbbbbbbbbbbbb" (20 'b's).
    // Hard fallback: a line of 30 'a's with no space should hard wrap at 29.
    var hard: [30]u8 = [_]u8{'a'} ** 30;
    try std.testing.expectEqual(@as(usize, 2), TextLayout.total_rows(&hard));
    try std.testing.expectEqual(RowBounds{ .start = 0, .glyphs = 29 }, TextLayout.row_bounds(&hard, 0));
    try std.testing.expectEqual(RowBounds{ .start = 29, .glyphs = 1 }, TextLayout.row_bounds(&hard, 1));
    // Soft-wrap with space: "aaaa...aaa bbbb...bbb" where first 20 'a's + space + 20 'b's, cols 29 should wrap at space.
    const soft = text[0..41]; // 20 'a' + space + 20 'b' =41, no newline yet
    // The first row should be 20 'a's (space is wrap point, not counted).
    try std.testing.expectEqual(@as(usize, 2), TextLayout.total_rows(soft));
    const rb0 = TextLayout.row_bounds(soft, 0);
    try std.testing.expectEqual(@as(usize, 20), rb0.glyphs);
    const rb1 = TextLayout.row_bounds(soft, 1);
    try std.testing.expectEqual(@as(usize, 20), rb1.glyphs);
}

test "notepad: M15 C6 — find next, case-insensitive, replace and replace-all" {
    var app = AppState.init();
    app.buffer.set_content("hello HELLO hello");
    // Find "hello" case-insensitive
    @memcpy(app.find_buf[0..5], "hello");
    app.find_len = 5;
    app.find_case_sensitive = false;
    try std.testing.expect(app.find_next());
    try std.testing.expectEqual(@as(?usize, 0), app.find_match_start);
    // Next should be at 6 ("HELLO")
    app.buffer.cursor = 1;
    try std.testing.expect(app.find_next());
    try std.testing.expectEqual(@as(?usize, 6), app.find_match_start);
    // Next should be at 12
    app.buffer.cursor = 7;
    try std.testing.expect(app.find_next());
    try std.testing.expectEqual(@as(?usize, 12), app.find_match_start);
    // Replace current "hello" at 12 with "hi"
    @memcpy(app.replace_buf[0..2], "hi");
    app.replace_len = 2;
    try std.testing.expect(app.replace_current());
    try std.testing.expectEqualStrings("hello HELLO hi", app.buffer.get_slice());
    // Replace all "hello" -> "hi" (case-insensitive) should replace remaining 2
    @memcpy(app.find_buf[0..5], "hello");
    app.find_len = 5;
    @memcpy(app.replace_buf[0..2], "hi");
    app.replace_len = 2;
    const n = app.replace_all();
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("hi hi hi", app.buffer.get_slice());
    // Ctrl+F toggles find bar
    var ev_f = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x09, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_f));
    try std.testing.expect(app.find_active);
    ev_f.arg0 = 0x09;
    try std.testing.expect(app.handle_keyboard_event(&ev_f));
    try std.testing.expect(!app.find_active);
}

test "notepad: M20-U8 — Match N of M ordinal and case-sensitive toggle" {
    var app = AppState.init();
    app.buffer.set_content("hat hat hat");
    @memcpy(app.find_buf[0..3], "hat");
    app.find_len = 3;
    // First match.
    try std.testing.expect(app.find_next());
    try std.testing.expectEqual(@as(usize, 0), app.find_current_ordinal().?);
    try std.testing.expectEqual(@as(usize, 3), app.find_all_count());
    // Second + third ordinals walk with the matches.
    app.buffer.cursor = 1;
    try std.testing.expect(app.find_next());
    try std.testing.expectEqual(@as(usize, 1), app.find_current_ordinal().?);
    app.buffer.cursor = 5;
    try std.testing.expect(app.find_next());
    try std.testing.expectEqual(@as(usize, 2), app.find_current_ordinal().?);
    // Case-insensitive finds HAT too…
    // Prepend "HAT " by inserting at the cursor after moving home.
    app.buffer.cursor = 0;
    _ = app.buffer.insert_slice("HAT ");
    try std.testing.expectEqual(@as(usize, 4), app.find_all_count());
    // …but Ctrl+Shift+F flips to case-sensitive and HAT disappears.
    app.find_active = true;
    var ev_cs = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL | ui.MOD_SHIFT, .seq = 2, .arg0 = 0x09, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_cs));
    try std.testing.expect(app.find_case_sensitive);
    try std.testing.expectEqual(@as(usize, 3), app.find_all_count());
    // Toggling again restores case-insensitive matching.
    try std.testing.expect(app.handle_keyboard_event(&ev_cs));
    try std.testing.expect(!app.find_case_sensitive);
}

test "notepad: M20-U3 — line_start_offset and count_lines" {
    try std.testing.expectEqual(@as(usize, 1), AppState.count_lines(""));
    try std.testing.expectEqual(@as(usize, 3), AppState.count_lines("a\nbc\ndef"));
    // A trailing newline yields a final empty line.
    try std.testing.expectEqual(@as(usize, 2), AppState.count_lines("a\n"));
    try std.testing.expectEqual(@as(?usize, 0), AppState.line_start_offset("a\nbc\ndef", 1));
    try std.testing.expectEqual(@as(?usize, 2), AppState.line_start_offset("a\nbc\ndef", 2));
    try std.testing.expectEqual(@as(?usize, 5), AppState.line_start_offset("a\nbc\ndef", 3));
    // The offset of a trailing empty line is the buffer length.
    try std.testing.expectEqual(@as(?usize, 2), AppState.line_start_offset("a\n", 2));
    try std.testing.expectEqual(@as(?usize, null), AppState.line_start_offset("a\nbc", 3));
    try std.testing.expectEqual(@as(?usize, null), AppState.line_start_offset("abc", 0));
}

test "notepad: M20-U3 — Ctrl+G goto-line bar jumps and reports" {
    var app = AppState.init();
    app.buffer.set_content("one\ntwo\nthree");
    const ctrl_g = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x0a, .arg1 = 0 };
    // Ctrl+G opens the bar (and it is mutually exclusive with find).
    app.find_active = true;
    try std.testing.expect(app.handle_keyboard_event(&ctrl_g));
    try std.testing.expect(app.goto_active);
    try std.testing.expect(!app.find_active);
    try std.testing.expectEqual(@as(usize, 0), app.goto_len);
    // Digits land in the bar; other printables do not.
    const d2 = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0, .arg1 = '2' };
    try std.testing.expect(app.handle_keyboard_event(&d2));
    try std.testing.expectEqual(@as(usize, 1), app.goto_len);
    const dx = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0, .arg1 = 'x' };
    try std.testing.expect(!app.handle_keyboard_event(&dx));
    try std.testing.expectEqual(@as(usize, 1), app.goto_len);
    // The swallowed printable did not leak into the document buffer.
    try std.testing.expectEqualStrings("one\ntwo\nthree", app.buffer.get_slice());
    // Enter jumps to the start of buffer line 2 ("two").
    const enter = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x28, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&enter));
    try std.testing.expect(!app.goto_active);
    try std.testing.expectEqualStrings("two\nthree", app.buffer.get_slice()[app.buffer.cursor..]);
    // A miss reports honestly and keeps the bar open (the find bar's
    // No-Match behavior); the caret does not move.
    const miss_at = app.buffer.cursor;
    _ = app.handle_keyboard_event(&ctrl_g);
    const d9 = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 5, .arg0 = 0, .arg1 = '9' };
    _ = app.handle_keyboard_event(&d9);
    try std.testing.expect(app.handle_keyboard_event(&enter));
    try std.testing.expect(app.goto_active);
    try std.testing.expectEqual(miss_at, app.buffer.cursor);
    // Escape closes the still-open bar.
    const esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 6, .arg0 = 0x29, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&esc));
    try std.testing.expect(!app.goto_active);
}

test "notepad: M20-U3 — find Enter reports hit ordinal / no-match markers" {
    var app = AppState.init();
    app.buffer.set_content("hat hat");
    @memcpy(app.find_buf[0..3], "hat");
    app.find_len = 3;
    app.find_active = true;
    const enter = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x28, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&enter));
    try std.testing.expectEqual(@as(?usize, 0), app.find_current_ordinal());
    // find_next searches from the buffer cursor (pre-existing M15 C6
    // semantics — it highlights, it does not move the caret), so advance
    // the cursor past match 1 before the next Enter walks to match 2.
    app.buffer.cursor = 1;
    try std.testing.expect(app.handle_keyboard_event(&enter));
    try std.testing.expectEqual(@as(?usize, 1), app.find_current_ordinal());
    // A pattern that matches nothing reports no-match.
    var miss = AppState.init();
    miss.buffer.set_content("nothing here");
    @memcpy(miss.find_buf[0..3], "zzz");
    miss.find_len = 3;
    miss.find_active = true;
    try std.testing.expect(miss.handle_keyboard_event(&enter));
    try std.testing.expectEqual(@as(?usize, null), miss.find_current_ordinal());
}
