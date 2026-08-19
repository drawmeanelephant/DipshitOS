//! DipshitOS fifteenth ESP user program — NOTEPAD.BIN (Milestone 11, Card A3).
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
pub const window_w: u32 = 256;
pub const window_h: u32 = 192;

pub const exit_status: u32 = 43;
pub const notes_path: []const u8 = "/data/notes.txt";

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

    /// Byte offset just past the previous '\n' — the start of the logical
    /// line containing `offset`. (The clipboard's line copy/cut uses
    /// logical lines, independent of the display-row wrap model.)
    pub fn line_start(self: *const TextBuffer, offset: usize) usize {
        var i = @min(offset, self.len);
        while (i > 0 and self.buf[i - 1] != '\n') : (i -= 1) {}
        return i;
    }

    /// Byte offset of the next '\n' at/after `offset` (exclusive), or
    /// `len` at EOF — the end of the logical line containing `offset`.
    pub fn line_end(self: *const TextBuffer, offset: usize) usize {
        var i = @min(offset, self.len);
        while (i < self.len and self.buf[i] != '\n') : (i += 1) {}
        return i;
    }

    /// The logical line containing the cursor, newline excluded.
    pub fn current_line(self: *const TextBuffer) []const u8 {
        const s = self.buf[0..self.len];
        const start = self.line_start(self.cursor);
        const end = self.line_end(self.cursor);
        return s[start..end];
    }

    /// Insert `text` at the cursor; false (nothing changed) when it would
    /// overflow the buffer.
    pub fn insert_text(self: *TextBuffer, text: []const u8) bool {
        if (text.len == 0) return true;
        if (self.len + text.len > self.buf.len) return false;
        var src: usize = self.len;
        while (src > self.cursor) : (src -= 1) {
            self.buf[src - 1 + text.len] = self.buf[src - 1];
        }
        @memcpy(self.buf[self.cursor .. self.cursor + text.len], text);
        self.len += text.len;
        self.cursor += text.len;
        return true;
    }

    /// Delete [start, end) (clamped); false when empty/out-of-range. The
    /// cursor lands at `start` when it was inside the removed range.
    pub fn delete_range(self: *TextBuffer, start: usize, end: usize) bool {
        if (start >= end or end > self.len) return false;
        const n = end - start;
        var i = start;
        while (i < self.len - n) : (i += 1) {
            self.buf[i] = self.buf[i + n];
        }
        self.len -= n;
        if (self.cursor >= end) {
            self.cursor -= n;
        } else if (self.cursor > start) {
            self.cursor = start;
        }
        return true;
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

    pub fn position_at(buf: []const u8, offset: usize) Pos {
        var row: usize = 0;
        var col: usize = 0;
        var i: usize = 0;
        while (i < offset and i < buf.len) : (i += 1) {
            const b = buf[i];
            if (b == '\n') {
                row += 1;
                col = 0;
            } else {
                if (col == cols) {
                    row += 1;
                    col = 0;
                }
                col += 1;
            }
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
        var col: usize = 0;
        var i: usize = 0;
        while (i < buf.len) : (i += 1) {
            if (row == target_row) {
                const start = i;
                var count: usize = 0;
                while (i < buf.len) {
                    const b = buf[i];
                    if (b == '\n') break;
                    if (count == cols) break;
                    count += 1;
                    i += 1;
                }
                return .{ .start = start, .glyphs = count };
            }
            const b = buf[i];
            if (b == '\n') {
                row += 1;
                col = 0;
            } else {
                if (col == cols) {
                    row += 1;
                    col = 0;
                }
                col += 1;
            }
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

    btn_load: Button = Button.init(Rect.make(6, 6, 44, 20), "Load"),
    btn_save: Button = Button.init(Rect.make(54, 6, 44, 20), "Save"),
    btn_clear: Button = Button.init(Rect.make(102, 6, 48, 20), "Clear"),

    pub fn init() AppState {
        var s = AppState{};
        s.btn_save.bg_color = ui.COLOR_ACCENT;
        s.btn_clear.bg_color = ui.COLOR_DANGER;
        return s;
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
        } else {
            self.set_status("Save Err");
            ui.write_console("notepad: write failed\n");
        }
    }

    pub fn draw(self: *const AppState, win: u32) void {
        // Window background
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.COLOR_BG);

        // Toolbar buttons
        self.btn_load.draw(win);
        self.btn_save.draw(win);
        self.btn_clear.draw(win);

        // Status label
        const status_rect = Rect.make(156, 6, 94, 20);
        ui.draw_text(win, self.status_msg[0..self.status_len], status_rect.x + 8, status_rect.y + 6, ui.COLOR_TEXT_MUTED);

        // Divider line
        ui.draw_rect(win, Rect.make(0, 30, window_w, 1), ui.COLOR_BORDER);

        // Text editor box
        ui.draw_rect(win, text_area, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, text_area, 1, ui.COLOR_BORDER);

        const slice = self.buffer.get_slice();

        // Render only the visible rows [scroll, scroll + visible_rows), walking
        // the buffer with the exact wrap rule TextLayout.position_at uses.
        var row: usize = 0;
        var col: usize = 0;
        var i: usize = 0;
        while (i < slice.len) : (i += 1) {
            const ch = slice[i];
            if (ch == '\n') {
                row += 1;
                col = 0;
                continue;
            }
            if (col == TextLayout.cols) {
                row += 1;
                col = 0;
            }
            if (row >= self.layout.scroll and row < self.layout.scroll + TextLayout.visible_rows) {
                const x = text_x0 + @as(u32, @intCast(col)) * glyph_w;
                const y = text_y0 + @as(u32, @intCast(row - self.layout.scroll)) * line_h;
                ui.draw_char(win, ch, x, y, ui.COLOR_TEXT_PRIMARY);
            }
            col += 1;
        }

        // Cursor: always visible (ensure_visible keeps its row in the viewport).
        const cpos = TextLayout.position_at(slice, self.buffer.cursor);
        if (cpos.row >= self.layout.scroll and cpos.row < self.layout.scroll + TextLayout.visible_rows) {
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
        const keycode = ev.arg0;
        const ascii = @as(u8, @truncate(ev.arg1));
        const slice = self.buffer.get_slice();

        // Backspace
        if (ascii == 0x08 or keycode == 0x2a) {
            if (self.buffer.backspace()) {
                _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                self.layout.clamp_scroll(slice);
                self.set_status("Editing");
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
                    return true;
                }
                return false;
            },
            else => {},
        }

        // Ctrl chords (modifier lives in the event flags; HID usages:
        // 'a' = 0x04, 'c' = 0x06, 'e' = 0x08, 'v' = 0x19, 'x' = 0x1b).
        if ((ev.flags & ui.MOD_CTRL) != 0) {
            if (keycode == 0x04) { // Ctrl+A: jump to buffer start
                self.buffer.cursor = 0;
                self.layout.scroll = 0;
                return true;
            }
            if (keycode == 0x08) { // Ctrl+E: jump to buffer end
                self.buffer.cursor = self.buffer.len;
                _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                return true;
            }
            // Claim 2611 (M14 S1): copy/cut/paste via the shared clipboard.
            if (keycode == 0x06) return self.copy_line(); // Ctrl+C
            if (keycode == 0x1b) return self.cut_line(); // Ctrl+X
            if (keycode == 0x19) return self.paste_clipboard(); // Ctrl+V
        }

        // Printable character
        if (ascii >= 0x20 and ascii <= 0x7e) {
            if (self.buffer.insert_char(ascii)) {
                _ = self.layout.ensure_visible(slice, self.buffer.cursor);
                self.layout.clamp_scroll(slice);
                self.set_status("Editing");
                return true;
            }
        }

        return false;
    }

    /// Copy the current logical line into the shared clipboard (slot 38).
    pub fn copy_line(self: *AppState) bool {
        const line = self.buffer.current_line();
        if (ui.clipboard_set(line) < 0) {
            self.set_status("Copy Err");
            return false;
        }
        self.set_status("Copied");
        return true;
    }

    /// Cut: copy the current line, then delete it (and its trailing
    /// newline, if any) from the buffer (slot 38).
    pub fn cut_line(self: *AppState) bool {
        const line = self.buffer.current_line();
        if (ui.clipboard_set(line) < 0) {
            self.set_status("Cut Err");
            return false;
        }
        const start = self.buffer.line_start(self.buffer.cursor);
        const end = self.buffer.line_end(self.buffer.cursor);
        const del_end = if (end < self.buffer.len and self.buffer.buf[end] == '\n') end + 1 else end;
        _ = self.buffer.delete_range(start, del_end);
        self.layout.clamp_scroll(self.buffer.get_slice());
        self.set_status("Cut");
        return true;
    }

    /// Paste the clipboard at the cursor (slot 39); refuses when it would
    /// overflow the buffer.
    pub fn paste_clipboard(self: *AppState) bool {
        var clip: [ui.clipboard_max]u8 = [_]u8{0} ** ui.clipboard_max;
        const rc = ui.clipboard_get(&clip);
        if (rc <= 0) {
            self.set_status("Empty");
            return false;
        }
        const n: usize = @intCast(rc);
        if (!self.buffer.insert_text(clip[0..n])) {
            self.set_status("Too Big");
            return false;
        }
        _ = self.layout.ensure_visible(self.buffer.get_slice(), self.buffer.cursor);
        self.layout.clamp_scroll(self.buffer.get_slice());
        self.set_status("Pasted");
        return true;
    }
};

// ---------------------------------------------------------------------------
// Entry Point (EL0)
// ---------------------------------------------------------------------------

pub export fn _start() callconv(.c) noreturn {
    var app = AppState.init();

    // 1. Open Window
    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("notepad: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));

    ui.write_console("notepad: open id=2\n");

    // 2. Initial Draw & Present
    app.draw(win);
    ui.win_present(win);
    ui.write_console("notepad: ready\n");

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

        if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
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
            if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
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

test "notepad: TextBuffer logical-line bounds and current_line (claim 2611)" {
    var tb = TextBuffer.init();
    tb.set_content("abc\ndef\n");

    // Cursor mid-line "def": the line is [4, 7).
    tb.cursor = 5;
    try std.testing.expectEqual(@as(usize, 4), tb.line_start(tb.cursor));
    try std.testing.expectEqual(@as(usize, 7), tb.line_end(tb.cursor));
    try std.testing.expectEqualStrings("def", tb.current_line());

    // The trailing newline opens an empty last line.
    tb.cursor = 8;
    try std.testing.expectEqual(@as(usize, 8), tb.line_start(tb.cursor));
    try std.testing.expectEqual(@as(usize, 8), tb.line_end(tb.cursor));
    try std.testing.expectEqualStrings("", tb.current_line());
}

test "notepad: TextBuffer insert_text and delete_range (claim 2611)" {
    var tb = TextBuffer.init();
    tb.set_content("ac");

    // Insert "b" at cursor 1 -> "abc".
    tb.cursor = 1;
    try std.testing.expect(tb.insert_text("b"));
    try std.testing.expectEqualStrings("abc", tb.get_slice());
    try std.testing.expectEqual(@as(usize, 2), tb.cursor);

    // Overflow is refused with nothing changed.
    var big: [512]u8 = [_]u8{'x'} ** 512;
    try std.testing.expect(!tb.insert_text(&big));
    try std.testing.expectEqualStrings("abc", tb.get_slice());

    // delete_range removes [1, 2) and parks the cursor at the start.
    tb.cursor = 2;
    try std.testing.expect(tb.delete_range(1, 2));
    try std.testing.expectEqualStrings("ac", tb.get_slice());
    try std.testing.expectEqual(@as(usize, 1), tb.cursor);
}

test "notepad: cut_line deletes the current line (host — the syscall is a no-op)" {
    var app = AppState.init();
    app.buffer.set_content("abc\ndef\n");

    // Cut the second line ("def") with the cursor inside it: the line and
    // its trailing newline vanish.
    app.buffer.cursor = 5;
    try std.testing.expect(app.cut_line());
    try std.testing.expectEqualStrings("abc\n", app.buffer.get_slice());
    try std.testing.expectEqualStrings("Cut", app.status_msg[0..3]);

    // Paste is refused on a host (the syscall seam returns 0/empty there).
    try std.testing.expect(!app.paste_clipboard());
    try std.testing.expectEqualStrings("Empty", app.status_msg[0..5]);
}
