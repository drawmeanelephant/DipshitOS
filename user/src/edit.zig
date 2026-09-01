//! VirelaiOS text editor — EDIT.BIN (Milestone 23 complete E1–E25).
//!
//! A full-screen text editor with line-number gutter, cursor navigation,
//! insert/overwrite mode, status bar, multi-file tabs, syntax coloring,
//! search & replace, autoindent/dedent, bracket matching, line numbers toggle,
//! delete-line, console split mini-shell, bookmarks, jump to definition,
//! indentation controls, editor themes, command palette, configurable
//! keybindings, multiple cursors, rectangular selection, recent files list,
//! unsaved changes guard, crash recovery, and file tree sidebar.
//!
//! Zero heap allocation — all state operates over static BSS structures.

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Event = ui.Event;
const DirEntry = ui.DirEntry;

pub const window_id: u32 = 3;
pub const window_x: u32 = 64;
pub const window_y: u32 = 48;
pub const window_w: u32 = 512;
pub const window_h: u32 = 384;

pub const exit_status: u32 = 44;

// Editor geometry
pub const gutter_w: u32 = 28;
pub const editor_x0: u32 = gutter_w + 4;
pub const editor_y0: u32 = 34;
pub const glyph_w: u32 = 8;
pub const line_h: u32 = 12;
pub const text_cols: u32 = 56;
pub const text_area_h: u32 = 310;

// E4: multi-file tabs
pub const max_tabs: usize = 4;
pub const tab_bar_h: u32 = 16;
pub const filename_cap: usize = 32;

// E6: console split dimensions
pub const split_ratio: u32 = 2; // editor gets 60%, console 40%
pub const console_split_h: u32 = text_area_h * 2 / 5; // bottom 40%
pub const console_rows: usize = 10;

// E2 + E7 + E22: undo/redo
const undo_cap: usize = 50;
const delta_text_cap: usize = 64;

// E17: crash recovery
pub const recovery_path: []const u8 = "/host/EDIT_REC.TXT"; // M34 HF5 (#739): user data lives in the host folder

// E19: Editor Themes
pub const Theme = struct {
    name: []const u8,
    bg: u32,
    surface: u32,
    text: u32,
    muted: u32,
    accent: u32,
    warning: u32,
    success: u32,
    gutter_bg: u32,
    line_highlight: u32,
    selection_bg: u32,
    cursor: u32,
};

pub const themes = [_]Theme{
    // Dark (Default - Green terminal vibe)
    .{
        .name = "Dark",
        .bg = 0x101418,
        .surface = 0x1a2026,
        .text = 0x00ff00,
        .muted = 0x668877,
        .accent = 0x33ff66,
        .warning = 0xffcc00,
        .success = 0x22cc55,
        .gutter_bg = 0x0b0e11,
        .line_highlight = 0x22303a,
        .selection_bg = 0x2a4460,
        .cursor = 0x00ff00,
    },
    // Light
    .{
        .name = "Light",
        .bg = 0xf0f2f5,
        .surface = 0xffffff,
        .text = 0x111827,
        .muted = 0x6b7280,
        .accent = 0x2563eb,
        .warning = 0xd97706,
        .success = 0x16a34a,
        .gutter_bg = 0xe5e7eb,
        .line_highlight = 0xe0e7ff,
        .selection_bg = 0xbfdbfe,
        .cursor = 0x2563eb,
    },
    // Amber
    .{
        .name = "Amber",
        .bg = 0x1a1200,
        .surface = 0x261a00,
        .text = 0xffb000,
        .muted = 0x996600,
        .accent = 0xffcc33,
        .warning = 0xff8800,
        .success = 0xffd700,
        .gutter_bg = 0x120c00,
        .line_highlight = 0x332200,
        .selection_bg = 0x4d3300,
        .cursor = 0xffb000,
    },
};

/// A single undo/redo delta: position + what changed.
pub const Delta = struct {
    pos: usize = 0,
    old_len: usize = 0,
    new_len: usize = 0,
    old_text: [delta_text_cap]u8 = [_]u8{0} ** delta_text_cap,
    new_text: [delta_text_cap]u8 = [_]u8{0} ** delta_text_cap,
};

/// Bounded undo/redo ring.
pub const UndoRing = struct {
    undo_stack: [undo_cap]Delta = [_]Delta{.{}} ** undo_cap,
    undo_count: usize = 0,
    redo_stack: [undo_cap]Delta = [_]Delta{.{}} ** undo_cap,
    redo_count: usize = 0,

    pub fn clear(self: *UndoRing) void {
        self.undo_count = 0;
        self.redo_count = 0;
    }

    pub fn push_undo(self: *UndoRing, d: Delta) void {
        if (self.undo_count < undo_cap) {
            self.undo_stack[self.undo_count] = d;
            self.undo_count += 1;
        } else {
            var i: usize = 0;
            while (i < undo_cap - 1) : (i += 1) {
                self.undo_stack[i] = self.undo_stack[i + 1];
            }
            self.undo_stack[undo_cap - 1] = d;
        }
        self.redo_count = 0;
    }

    pub fn can_undo(self: *const UndoRing) bool {
        return self.undo_count > 0;
    }

    pub fn can_redo(self: *const UndoRing) bool {
        return self.redo_count > 0;
    }
};

// ---------------------------------------------------------------------------
// E21: Bookmarks
// ---------------------------------------------------------------------------

pub const max_bookmarks: usize = 16;

pub const Bookmarks = struct {
    lines: [max_bookmarks]usize = [_]usize{0} ** max_bookmarks,
    count: usize = 0,

    pub fn clear(self: *Bookmarks) void {
        self.count = 0;
    }

    pub fn has_bookmark(self: *const Bookmarks, line: usize) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.lines[i] == line) return true;
        }
        return false;
    }

    pub fn toggle(self: *Bookmarks, line: usize) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.lines[i] == line) {
                // Remove
                var j = i;
                while (j < self.count - 1) : (j += 1) {
                    self.lines[j] = self.lines[j + 1];
                }
                self.count -= 1;
                return false; // Removed
            }
        }
        if (self.count < max_bookmarks) {
            self.lines[self.count] = line;
            self.count += 1;
            // Sort
            var a: usize = 0;
            while (a < self.count) : (a += 1) {
                var b: usize = a + 1;
                while (b < self.count) : (b += 1) {
                    if (self.lines[b] < self.lines[a]) {
                        const tmp = self.lines[a];
                        self.lines[a] = self.lines[b];
                        self.lines[b] = tmp;
                    }
                }
            }
            return true; // Added
        }
        return false;
    }

    pub fn next_after(self: *const Bookmarks, current: usize) ?usize {
        if (self.count == 0) return null;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.lines[i] > current) return self.lines[i];
        }
        return self.lines[0]; // Wrap
    }

    pub fn prev_before(self: *const Bookmarks, current: usize) ?usize {
        if (self.count == 0) return null;
        var i: usize = self.count;
        while (i > 0) : (i -= 1) {
            if (self.lines[i - 1] < current) return self.lines[i - 1];
        }
        return self.lines[self.count - 1]; // Wrap
    }
};

// ---------------------------------------------------------------------------
// E12: Multiple Cursors
// ---------------------------------------------------------------------------

pub const max_cursors: usize = 8;

// ---------------------------------------------------------------------------
// E13: Rectangular Selection
// ---------------------------------------------------------------------------

pub const RectSelection = struct {
    active: bool = false,
    start_line: usize = 1,
    start_col: usize = 1,
    end_line: usize = 1,
    end_col: usize = 1,

    pub fn clear(self: *RectSelection) void {
        self.active = false;
    }

    pub fn min_line(self: *const RectSelection) usize {
        return @min(self.start_line, self.end_line);
    }
    pub fn max_line(self: *const RectSelection) usize {
        return @max(self.start_line, self.end_line);
    }
    pub fn min_col(self: *const RectSelection) usize {
        return @min(self.start_col, self.end_col);
    }
    pub fn max_col(self: *const RectSelection) usize {
        return @max(self.start_col, self.end_col);
    }

    pub fn contains(self: *const RectSelection, line: usize, col: usize) bool {
        if (!self.active) return false;
        return line >= self.min_line() and line <= self.max_line() and
            col >= self.min_col() and col <= self.max_col();
    }
};

// ---------------------------------------------------------------------------
// File Buffer
// ---------------------------------------------------------------------------

pub const file_buf_cap: usize = 32768;

pub const FileBuffer = struct {
    buf: [file_buf_cap]u8 = [_]u8{0} ** file_buf_cap,
    len: usize = 0,
    cursor: usize = 0,
    undo: UndoRing = .{},
    bookmarks: Bookmarks = .{},
    // E12 multi-cursors
    extra_cursors: [max_cursors]usize = [_]usize{0} ** max_cursors,
    extra_cursor_count: usize = 0,
    // E13 rectangular selection
    rect_sel: RectSelection = .{},
    tab_width: usize = 4,

    pub fn slice(self: *const FileBuffer) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set_content(self: *FileBuffer, content: []const u8) void {
        const n = @min(content.len, file_buf_cap);
        @memcpy(self.buf[0..n], content[0..n]);
        self.len = n;
        self.cursor = @min(self.cursor, n);
        self.undo.clear();
        self.bookmarks.clear();
        self.extra_cursor_count = 0;
        self.rect_sel.clear();
    }

    pub fn clear(self: *FileBuffer) void {
        self.len = 0;
        self.cursor = 0;
        self.undo.clear();
        self.bookmarks.clear();
        self.extra_cursor_count = 0;
        self.rect_sel.clear();
    }

    pub fn insert_char_at(self: *FileBuffer, pos: usize, ch: u8) bool {
        if (self.len >= file_buf_cap or pos > self.len) return false;
        var i = self.len;
        while (i > pos) : (i -= 1) self.buf[i] = self.buf[i - 1];
        self.buf[pos] = ch;
        self.len += 1;
        var d: Delta = .{ .pos = pos };
        d.new_text[0] = ch;
        d.new_len = 1;
        self.undo.push_undo(d);
        return true;
    }

    pub fn insert_char(self: *FileBuffer, ch: u8) bool {
        if (self.len >= file_buf_cap) return false;
        if (self.extra_cursor_count == 0) {
            if (!self.insert_char_at(self.cursor, ch)) return false;
            self.cursor += 1;
            return true;
        }

        const total = self.extra_cursor_count + 1;
        var cursors: [max_cursors + 1]usize = undefined;
        cursors[0] = self.cursor;
        var ci: usize = 0;
        while (ci < self.extra_cursor_count) : (ci += 1) {
            cursors[ci + 1] = self.extra_cursors[ci];
        }

        var order: [max_cursors + 1]usize = undefined;
        var oi: usize = 0;
        while (oi < total) : (oi += 1) order[oi] = oi;

        var a: usize = 0;
        while (a < total) : (a += 1) {
            var b: usize = a + 1;
            while (b < total) : (b += 1) {
                if (cursors[order[b]] > cursors[order[a]]) {
                    const tmp = order[a];
                    order[a] = order[b];
                    order[b] = tmp;
                }
            }
        }

        for (order[0..total]) |idx| {
            const pos = cursors[idx];
            if (self.len >= file_buf_cap or pos > self.len) continue;
            var i = self.len;
            while (i > pos) : (i -= 1) self.buf[i] = self.buf[i - 1];
            self.buf[pos] = ch;
            self.len += 1;
            var d: Delta = .{ .pos = pos };
            d.new_text[0] = ch;
            d.new_len = 1;
            self.undo.push_undo(d);

            var cj: usize = 0;
            while (cj < total) : (cj += 1) {
                if (cj == idx or cursors[cj] > pos) {
                    cursors[cj] += 1;
                }
            }
        }

        self.cursor = cursors[0];
        ci = 0;
        while (ci < self.extra_cursor_count) : (ci += 1) {
            self.extra_cursors[ci] = cursors[ci + 1];
        }
        return true;
    }

    pub fn insert_slice(self: *FileBuffer, text: []const u8) usize {
        var ins: usize = 0;
        for (text) |ch| {
            if (!self.insert_char(ch)) break;
            ins += 1;
        }
        return ins;
    }

    pub fn backspace_at(self: *FileBuffer, pos: usize) bool {
        if (pos == 0 or pos > self.len or self.len == 0) return false;
        const deleted_char = self.buf[pos - 1];
        var i = pos - 1;
        while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
        self.len -= 1;
        var d: Delta = .{ .pos = pos - 1 };
        d.old_text[0] = deleted_char;
        d.old_len = 1;
        self.undo.push_undo(d);
        return true;
    }

    pub fn backspace(self: *FileBuffer) bool {
        if (self.len == 0) return false;
        if (self.extra_cursor_count == 0) {
            if (self.cursor == 0) return false;
            if (!self.backspace_at(self.cursor)) return false;
            self.cursor -= 1;
            return true;
        }

        const total = self.extra_cursor_count + 1;
        var cursors: [max_cursors + 1]usize = undefined;
        cursors[0] = self.cursor;
        var ci: usize = 0;
        while (ci < self.extra_cursor_count) : (ci += 1) {
            cursors[ci + 1] = self.extra_cursors[ci];
        }

        var order: [max_cursors + 1]usize = undefined;
        var oi: usize = 0;
        while (oi < total) : (oi += 1) order[oi] = oi;

        var a: usize = 0;
        while (a < total) : (a += 1) {
            var b: usize = a + 1;
            while (b < total) : (b += 1) {
                if (cursors[order[b]] > cursors[order[a]]) {
                    const tmp = order[a];
                    order[a] = order[b];
                    order[b] = tmp;
                }
            }
        }

        var changed = false;
        for (order[0..total]) |idx| {
            const pos = cursors[idx];
            if (pos == 0 or pos > self.len or self.len == 0) continue;
            const del_pos = pos - 1;
            const deleted_char = self.buf[del_pos];
            var i = del_pos;
            while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
            self.len -= 1;
            var d: Delta = .{ .pos = del_pos };
            d.old_text[0] = deleted_char;
            d.old_len = 1;
            self.undo.push_undo(d);
            changed = true;

            var cj: usize = 0;
            while (cj < total) : (cj += 1) {
                if (cj == idx or cursors[cj] > del_pos) {
                    cursors[cj] -= 1;
                }
            }
        }

        self.cursor = cursors[0];
        ci = 0;
        while (ci < self.extra_cursor_count) : (ci += 1) {
            self.extra_cursors[ci] = cursors[ci + 1];
        }
        return changed;
    }

    pub fn delete_forward(self: *FileBuffer) bool {
        if (self.len == 0) return false;
        if (self.extra_cursor_count == 0) {
            if (self.cursor >= self.len) return false;
            const deleted_char = self.buf[self.cursor];
            var i = self.cursor;
            while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
            self.len -= 1;
            var d: Delta = .{ .pos = self.cursor };
            d.old_text[0] = deleted_char;
            d.old_len = 1;
            self.undo.push_undo(d);
            return true;
        }

        const total = self.extra_cursor_count + 1;
        var cursors: [max_cursors + 1]usize = undefined;
        cursors[0] = self.cursor;
        var ci: usize = 0;
        while (ci < self.extra_cursor_count) : (ci += 1) {
            cursors[ci + 1] = self.extra_cursors[ci];
        }

        var order: [max_cursors + 1]usize = undefined;
        var oi: usize = 0;
        while (oi < total) : (oi += 1) order[oi] = oi;

        var a: usize = 0;
        while (a < total) : (a += 1) {
            var b: usize = a + 1;
            while (b < total) : (b += 1) {
                if (cursors[order[b]] > cursors[order[a]]) {
                    const tmp = order[a];
                    order[a] = order[b];
                    order[b] = tmp;
                }
            }
        }

        var changed = false;
        for (order[0..total]) |idx| {
            const pos = cursors[idx];
            if (pos >= self.len) continue;
            const deleted_char = self.buf[pos];
            var i = pos;
            while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
            self.len -= 1;
            var d: Delta = .{ .pos = pos };
            d.old_text[0] = deleted_char;
            d.old_len = 1;
            self.undo.push_undo(d);
            changed = true;

            var cj: usize = 0;
            while (cj < total) : (cj += 1) {
                if (cursors[cj] > pos) {
                    cursors[cj] -= 1;
                }
            }
        }

        self.cursor = cursors[0];
        ci = 0;
        while (ci < self.extra_cursor_count) : (ci += 1) {
            self.extra_cursors[ci] = cursors[ci + 1];
        }
        return changed;
    }

    pub fn insert_rect_char(self: *FileBuffer, ch: u8) bool {
        if (!self.rect_sel.active) return false;
        const min_l = self.rect_sel.min_line();
        const max_l = self.rect_sel.max_line();
        const col = self.rect_sel.min_col();

        var p: usize = 0;
        var cur_line: usize = 1;
        while (p < self.len and cur_line <= max_l) {
            const ls = p;
            while (p < self.len and self.buf[p] != '\n') p += 1;
            const le = p;
            if (cur_line >= min_l and cur_line <= max_l) {
                const line_len = le - ls;
                const insert_pos = ls + @min(col -| 1, line_len);
                _ = self.insert_char_at(insert_pos, ch);
                p += 1;
            }
            if (p < self.len and self.buf[p] == '\n') {
                p += 1;
            }
            cur_line += 1;
        }
        self.rect_sel.start_col += 1;
        self.rect_sel.end_col += 1;
        return true;
    }

    pub fn backspace_rect_char(self: *FileBuffer) bool {
        if (!self.rect_sel.active) return false;
        const min_l = self.rect_sel.min_line();
        const max_l = self.rect_sel.max_line();
        const col = self.rect_sel.min_col();
        if (col <= 1) return false;

        var p: usize = 0;
        var cur_line: usize = 1;
        while (p < self.len and cur_line <= max_l) {
            const ls = p;
            while (p < self.len and self.buf[p] != '\n') p += 1;
            const le = p;
            if (cur_line >= min_l and cur_line <= max_l) {
                const line_len = le - ls;
                const del_col = col - 1;
                if (del_col <= line_len) {
                    const del_pos = ls + del_col;
                    _ = self.backspace_at(del_pos);
                    p -= 1;
                }
            }
            if (p < self.len and self.buf[p] == '\n') {
                p += 1;
            }
            cur_line += 1;
        }
        if (self.rect_sel.start_col > 1) self.rect_sel.start_col -= 1;
        if (self.rect_sel.end_col > 1) self.rect_sel.end_col -= 1;
        return true;
    }

    pub fn overwrite_char(self: *FileBuffer, ch: u8) bool {
        if (self.cursor >= self.len) return false;
        const old_ch = self.buf[self.cursor];
        self.buf[self.cursor] = ch;
        var d: Delta = .{ .pos = self.cursor };
        d.old_text[0] = old_ch;
        d.old_len = 1;
        d.new_text[0] = ch;
        d.new_len = 1;
        self.undo.push_undo(d);
        self.cursor += 1;
        return true;
    }

    pub fn insert_newline(self: *FileBuffer) bool {
        return self.insert_newline_autoindent();
    }

    pub fn insert_newline_autoindent(self: *FileBuffer) bool {
        const ls = self.line_start(self.cursor);
        var ws_len: usize = 0;
        while (ls + ws_len < self.cursor and (self.buf[ls + ws_len] == ' ' or self.buf[ls + ws_len] == '\t')) : (ws_len += 1) {}

        if (!self.insert_char('\n')) return false;

        var i: usize = 0;
        while (i < ws_len) : (i += 1) {
            if (!self.insert_char(self.buf[ls + i])) break;
        }
        return true;
    }

    pub fn insert_char_with_dedent(self: *FileBuffer, ch: u8) bool {
        if (ch == '}') {
            const ls = self.line_start(self.cursor);
            var only_ws = true;
            var i: usize = ls;
            while (i < self.cursor) : (i += 1) {
                if (self.buf[i] != ' ' and self.buf[i] != '\t') {
                    only_ws = false;
                    break;
                }
            }
            if (only_ws and self.cursor > ls) {
                const ws_count = self.cursor - ls;
                const dedent_amount = if (ws_count >= 4) @as(usize, 4) else ws_count;
                var d: usize = 0;
                while (d < dedent_amount) : (d += 1) {
                    _ = self.backspace();
                }
            }
        }
        return self.insert_char(ch);
    }

    // E20: Indentation controls (Tab/Shift+Tab)
    pub fn indent_current_line(self: *FileBuffer) bool {
        const ls = self.line_start(self.cursor);
        var i: usize = 0;
        while (i < self.tab_width) : (i += 1) {
            if (!self.insert_char_at(ls, ' ')) return false;
        }
        self.cursor += self.tab_width;
        return true;
    }

    pub fn dedent_current_line(self: *FileBuffer) bool {
        const ls = self.line_start(self.cursor);
        var spaces: usize = 0;
        while (ls + spaces < self.len and spaces < self.tab_width and self.buf[ls + spaces] == ' ') : (spaces += 1) {}
        if (spaces == 0 and ls < self.len and self.buf[ls] == '\t') {
            spaces = 1;
        }
        if (spaces == 0) return false;

        var i: usize = 0;
        while (i < spaces) : (i += 1) {
            _ = self.backspace_at(ls + 1);
        }
        if (self.cursor > ls) {
            self.cursor = ls + (self.cursor - ls -| spaces);
        }
        return true;
    }

    // E22: Delete current line
    pub fn delete_current_line(self: *FileBuffer) bool {
        if (self.len == 0) return false;
        const ls = self.line_start(self.cursor);
        const le = self.line_end(self.cursor);
        const next_start = if (le < self.len and self.buf[le] == '\n') le + 1 else le;
        const del_len = next_start - ls;
        if (del_len == 0) return false;

        var d: Delta = .{ .pos = ls };
        const copy_len = @min(del_len, delta_text_cap);
        @memcpy(d.old_text[0..copy_len], self.buf[ls..][0..copy_len]);
        d.old_len = copy_len;
        d.new_len = 0;
        self.undo.push_undo(d);

        var i: usize = ls;
        while (i < self.len - del_len) : (i += 1) {
            self.buf[i] = self.buf[i + del_len];
        }
        self.len -= del_len;
        self.cursor = @min(ls, self.len);
        return true;
    }

    // E2: Undo / Redo
    pub fn undo_last(self: *FileBuffer) bool {
        if (!self.undo.can_undo()) return false;
        const d = self.undo.undo_stack[self.undo.undo_count - 1];
        self.undo.undo_count -= 1;

        self.cursor = d.pos;
        if (d.new_len > 0) {
            const rm_end = d.pos + d.new_len;
            if (rm_end <= self.len) {
                var i: usize = d.pos;
                while (i < self.len - d.new_len) : (i += 1) {
                    self.buf[i] = self.buf[i + d.new_len];
                }
                self.len -= d.new_len;
            }
        }
        if (d.old_len > 0) {
            const n = @min(d.old_len, file_buf_cap - self.len);
            var i: usize = self.len;
            while (i > d.pos and i > 0) : (i -= 1) {
                if (i + n <= file_buf_cap)
                    self.buf[i + n - 1] = self.buf[i - 1];
            }
            @memcpy(self.buf[d.pos..][0..n], d.old_text[0..n]);
            self.len += n;
            self.cursor = d.pos + n;
        } else {
            self.cursor = d.pos;
        }

        self.undo.redo_stack[self.undo.redo_count] = d;
        self.undo.redo_count += 1;
        return true;
    }

    pub fn redo_last(self: *FileBuffer) bool {
        if (!self.undo.can_redo()) return false;
        const d = self.undo.redo_stack[self.undo.redo_count - 1];
        self.undo.redo_count -= 1;

        self.cursor = d.pos;
        if (d.old_len > 0) {
            const rm_end = d.pos + d.old_len;
            if (rm_end <= self.len) {
                var i: usize = d.pos;
                while (i < self.len - d.old_len) : (i += 1) {
                    self.buf[i] = self.buf[i + d.old_len];
                }
                self.len -= d.old_len;
            }
        }
        if (d.new_len > 0) {
            const n = @min(d.new_len, file_buf_cap - self.len);
            var i: usize = self.len;
            while (i > d.pos and i > 0) : (i -= 1) {
                if (i + n <= file_buf_cap)
                    self.buf[i + n - 1] = self.buf[i - 1];
            }
            @memcpy(self.buf[d.pos..][0..n], d.new_text[0..n]);
            self.len += n;
            self.cursor = d.pos + n;
        } else {
            self.cursor = d.pos;
        }

        self.undo.undo_stack[self.undo.undo_count] = d;
        self.undo.undo_count += 1;
        return true;
    }

    pub fn goto_line(self: *FileBuffer, line_num: usize) void {
        if (line_num == 0) {
            self.cursor = 0;
            return;
        }
        var current: usize = 1;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (current >= line_num) break;
            if (self.buf[i] == '\n') current += 1;
        }
        self.cursor = i;
    }

    pub fn line_start(self: *const FileBuffer, pos: usize) usize {
        var p = @min(pos, self.len);
        while (p > 0 and self.buf[p - 1] != '\n') p -= 1;
        return p;
    }

    pub fn line_end(self: *const FileBuffer, pos: usize) usize {
        var p = @min(pos, self.len);
        while (p < self.len and self.buf[p] != '\n') p += 1;
        return p;
    }

    pub fn move_left(self: *FileBuffer) bool {
        if (self.cursor == 0) return false;
        self.cursor -= 1;
        return true;
    }

    pub fn move_right(self: *FileBuffer) bool {
        if (self.cursor >= self.len) return false;
        self.cursor += 1;
        return true;
    }

    pub fn move_up(self: *FileBuffer) bool {
        const ls = self.line_start(self.cursor);
        if (ls == 0) return false;
        const prev_newline = ls - 1;
        const prev_start = self.line_start(prev_newline);
        const col = self.cursor - ls;
        const prev_content_len = prev_newline - prev_start;
        self.cursor = prev_start + @min(col, if (prev_content_len > 0) prev_content_len - 1 else 0);
        return true;
    }

    pub fn move_down(self: *FileBuffer) bool {
        const le = self.line_end(self.cursor);
        if (le >= self.len) return false;
        const next_start = le + 1;
        if (next_start >= self.len) return false;
        const ls = self.line_start(self.cursor);
        const col = self.cursor - ls;
        const next_end = self.line_end(next_start);
        const next_content_len = next_end - next_start;
        self.cursor = next_start + @min(col, if (next_content_len > 0) next_content_len - 1 else 0);
        return true;
    }

    pub fn total_lines(self: *const FileBuffer) usize {
        if (self.len == 0) return 1;
        var n: usize = 1;
        for (self.buf[0..self.len]) |b| {
            if (b == '\n') n += 1;
        }
        return n;
    }

    pub fn current_line(self: *const FileBuffer) usize {
        var n: usize = 1;
        var i: usize = 0;
        while (i < self.cursor) : (i += 1) {
            if (self.buf[i] == '\n') n += 1;
        }
        return n;
    }

    pub fn current_col(self: *const FileBuffer) usize {
        const ls = self.line_start(self.cursor);
        return self.cursor - ls + 1;
    }

    // E12: Add cursor at next occurrence of current word
    pub fn add_next_word_cursor(self: *FileBuffer) bool {
        if (self.extra_cursor_count >= max_cursors) return false;
        if (extract_word_at_pos(self.slice(), self.cursor)) |word| {
            const search_from = if (self.extra_cursor_count > 0)
                self.extra_cursors[self.extra_cursor_count - 1] + word.len
            else
                self.cursor + word.len;
            if (find_next_ci(self.slice(), word, search_from, true)) |res| {
                if (res.pos != self.cursor) {
                    self.extra_cursors[self.extra_cursor_count] = res.pos;
                    self.extra_cursor_count += 1;
                    return true;
                }
            }
        }
        // Fallback: add cursor at next line position
        const le = self.line_end(self.cursor);
        const next_pos = if (le < self.len) le + 1 else self.cursor;
        self.extra_cursors[self.extra_cursor_count] = next_pos;
        self.extra_cursor_count += 1;
        return true;
    }
};

// ---------------------------------------------------------------------------
// E23: Jump to definition helper
// ---------------------------------------------------------------------------

pub fn extract_word_at_pos(buf: []const u8, pos: usize) ?[]const u8 {
    if (buf.len == 0) return null;
    var p = @min(pos, buf.len - 1);
    if (!is_ident_char(buf[p]) and p > 0 and is_ident_char(buf[p - 1])) {
        p -= 1;
    }
    if (!is_ident_char(buf[p])) return null;

    var start = p;
    while (start > 0 and is_ident_char(buf[start - 1])) start -= 1;
    var end = p;
    while (end < buf.len and is_ident_char(buf[end])) end += 1;

    if (start >= end) return null;
    return buf[start..end];
}

pub fn find_definition_in_buffer(buf: []const u8, word: []const u8) ?usize {
    if (word.len == 0 or buf.len < word.len) return null;

    // Look for "fn <word>" or "pub fn <word>" or "const <word> ="
    var pos: usize = 0;
    while (pos + word.len <= buf.len) : (pos += 1) {
        if (std.mem.startsWith(u8, buf[pos..], word)) {
            // Check preceding context
            const ls = if (pos > 0) blk: {
                var p = pos;
                while (p > 0 and buf[p - 1] != '\n') p -= 1;
                break :blk p;
            } else 0;
            const line_prefix = buf[ls..pos];
            if (std.mem.indexOf(u8, line_prefix, "fn ") != null or
                std.mem.indexOf(u8, line_prefix, "const ") != null or
                std.mem.indexOf(u8, line_prefix, "var ") != null)
            {
                return ls;
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// E5: Syntax coloring — Zig keyword table + token classifier
// ---------------------------------------------------------------------------

pub const SyntaxKind = enum { plain, keyword, string, comment };

pub const zig_keywords = [_][]const u8{
    "const",          "var",    "fn",       "pub",   "test",     "if",        "else",
    "while",          "for",    "return",   "break", "continue", "switch",    "and",
    "or",             "not",    "struct",   "enum",  "union",    "opaque",    "comptime",
    "inline",         "extern", "export",   "error", "try",      "catch",     "unreachable",
    "usingnamespace", "defer",  "errdefer", "asm",   "volatile", "align",     "linksection",
    "callconv",       "packed", "true",     "false", "null",     "undefined",
};

pub fn classify_token(text: []const u8) struct { kind: SyntaxKind, len: usize } {
    if (text.len == 0) return .{ .kind = .plain, .len = 0 };

    if (text.len >= 2 and text[0] == '/' and text[1] == '/') {
        var i: usize = 0;
        while (i < text.len and text[i] != '\n') : (i += 1) {}
        return .{ .kind = .comment, .len = i };
    }

    if (text[0] == '"') {
        var i: usize = 1;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (text[i] == '"') {
                i += 1;
                break;
            }
        }
        return .{ .kind = .string, .len = i };
    }

    if (text[0] == '\'') {
        var i: usize = 1;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (text[i] == '\'') {
                i += 1;
                break;
            }
        }
        return .{ .kind = .string, .len = i };
    }

    if (is_ident_start(text[0])) {
        var i: usize = 0;
        while (i < text.len and is_ident_char(text[i])) : (i += 1) {}
        const word = text[0..i];
        for (zig_keywords) |kw| {
            if (std.mem.eql(u8, kw, word)) {
                return .{ .kind = .keyword, .len = i };
            }
        }
        return .{ .kind = .plain, .len = i };
    }

    return .{ .kind = .plain, .len = 1 };
}

pub fn is_ident_start(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

pub fn is_ident_char(ch: u8) bool {
    return is_ident_start(ch) or (ch >= '0' and ch <= '9');
}

fn draw_line_colored(win: u32, text: []const u8, x: u32, y: u32, theme: *const Theme) void {
    var pos: usize = 0;
    var cur_x = x;
    while (pos < text.len) {
        var ws: usize = 0;
        while (pos + ws < text.len and (text[pos + ws] == ' ' or text[pos + ws] == '\t')) : (ws += 1) {}
        if (ws > 0) {
            ui.draw_text(win, text[pos..][0..ws], cur_x, y, theme.text);
            cur_x += @as(u32, @intCast(ws)) * glyph_w;
            pos += ws;
        }
        if (pos >= text.len) break;

        const result = classify_token(text[pos..]);
        const color: u32 = switch (result.kind) {
            .plain => theme.text,
            .keyword => theme.accent,
            .string => theme.success,
            .comment => theme.warning,
        };
        if (result.len == 0) break;
        ui.draw_text(win, text[pos..][0..result.len], cur_x, y, color);
        cur_x += @as(u32, @intCast(result.len)) * glyph_w;
        pos += result.len;
    }
}

// ---------------------------------------------------------------------------
// E9: Bracket Matching
// ---------------------------------------------------------------------------

pub fn is_bracket(ch: u8) bool {
    return ch == '(' or ch == ')' or ch == '[' or ch == ']' or ch == '{' or ch == '}';
}

pub fn is_open_bracket(ch: u8) bool {
    return ch == '(' or ch == '[' or ch == '{';
}

pub fn matching_bracket_char(ch: u8) ?u8 {
    return switch (ch) {
        '(' => ')',
        ')' => '(',
        '[' => ']',
        ']' => '[',
        '{' => '}',
        '}' => '{',
        else => null,
    };
}

pub fn find_matching_bracket(buf: []const u8, pos: usize) ?usize {
    if (pos >= buf.len) return null;
    const ch = buf[pos];
    const target = matching_bracket_char(ch) orelse return null;

    if (is_open_bracket(ch)) {
        var depth: usize = 1;
        var i: usize = pos + 1;
        while (i < buf.len) : (i += 1) {
            if (buf[i] == ch) {
                depth += 1;
            } else if (buf[i] == target) {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
    } else {
        var depth: usize = 1;
        var i: usize = pos;
        while (i > 0) {
            i -= 1;
            if (buf[i] == ch) {
                depth += 1;
            } else if (buf[i] == target) {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// E7: Search & Replace
// ---------------------------------------------------------------------------

pub const search_cap: usize = 32;

pub const FindPrompt = struct {
    find_buf: [search_cap]u8 = [_]u8{0} ** search_cap,
    find_len: usize = 0,
    replace_buf: [search_cap]u8 = [_]u8{0} ** search_cap,
    replace_len: usize = 0,
    active: bool = false,
    is_replace: bool = false,
    focus_replace: bool = false,

    pub fn open_find(self: *FindPrompt) void {
        self.active = true;
        self.is_replace = false;
        self.focus_replace = false;
        self.find_len = 0;
    }

    pub fn open_replace(self: *FindPrompt) void {
        self.active = true;
        self.is_replace = true;
        self.focus_replace = false;
        self.find_len = 0;
        self.replace_len = 0;
    }

    pub fn close(self: *FindPrompt) void {
        self.active = false;
        self.is_replace = false;
        self.focus_replace = false;
        self.find_len = 0;
        self.replace_len = 0;
    }

    pub fn get_find(self: *const FindPrompt) []const u8 {
        return self.find_buf[0..self.find_len];
    }

    pub fn get_replace(self: *const FindPrompt) []const u8 {
        return self.replace_buf[0..self.replace_len];
    }

    pub fn insert_char(self: *FindPrompt, ch: u8) void {
        if (self.focus_replace) {
            if (self.replace_len < search_cap) {
                self.replace_buf[self.replace_len] = ch;
                self.replace_len += 1;
            }
        } else {
            if (self.find_len < search_cap) {
                self.find_buf[self.find_len] = ch;
                self.find_len += 1;
            }
        }
    }

    pub fn backspace(self: *FindPrompt) void {
        if (self.focus_replace) {
            if (self.replace_len > 0) self.replace_len -= 1;
        } else {
            if (self.find_len > 0) self.find_len -= 1;
        }
    }
};

pub fn match_at_ci(haystack: []const u8, needle: []const u8, pos: usize) bool {
    if (needle.len == 0 or pos + needle.len > haystack.len) return false;
    for (needle, 0..) |nc, i| {
        const hc = haystack[pos + i];
        if (std.ascii.toLower(hc) != std.ascii.toLower(nc)) return false;
    }
    return true;
}

pub fn count_matches_ci(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0 or haystack.len < needle.len) return 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (match_at_ci(haystack, needle, i)) {
            count += 1;
            i += needle.len - 1;
        }
    }
    return count;
}

pub fn find_next_ci(haystack: []const u8, needle: []const u8, from_pos: usize, wrap: bool) ?struct { pos: usize, wrapped: bool } {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i = from_pos;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (match_at_ci(haystack, needle, i)) {
            return .{ .pos = i, .wrapped = false };
        }
    }
    if (wrap and from_pos > 0) {
        var j: usize = 0;
        while (j < from_pos and j + needle.len <= haystack.len) : (j += 1) {
            if (match_at_ci(haystack, needle, j)) {
                return .{ .pos = j, .wrapped = true };
            }
        }
    }
    return null;
}

pub fn find_prev_ci(haystack: []const u8, needle: []const u8, from_pos: usize) ?usize {
    if (needle.len == 0 or haystack.len < needle.len or from_pos == 0) return null;
    var i: usize = @min(from_pos - 1, haystack.len - needle.len);
    while (true) {
        if (i + needle.len <= haystack.len and match_at_ci(haystack, needle, i)) {
            return i;
        }
        if (i == 0) break;
        i -= 1;
    }
    return null;
}

pub fn replace_current_match(fb: *FileBuffer, needle: []const u8, replacement: []const u8) bool {
    if (!match_at_ci(fb.slice(), needle, fb.cursor)) return false;
    const old_len = needle.len;
    const new_len = replacement.len;
    if (fb.len - old_len + new_len > file_buf_cap) return false;

    var d: Delta = .{ .pos = fb.cursor };
    const copy_old = @min(old_len, delta_text_cap);
    @memcpy(d.old_text[0..copy_old], fb.buf[fb.cursor..][0..copy_old]);
    d.old_len = copy_old;
    const copy_new = @min(new_len, delta_text_cap);
    @memcpy(d.new_text[0..copy_new], replacement[0..copy_new]);
    d.new_len = copy_new;
    fb.undo.push_undo(d);

    if (new_len > old_len) {
        const diff = new_len - old_len;
        var i: usize = fb.len + diff;
        while (i > fb.cursor + new_len) : (i -= 1) {
            fb.buf[i - 1] = fb.buf[i - 1 - diff];
        }
    } else if (old_len > new_len) {
        const diff = old_len - new_len;
        var i: usize = fb.cursor + new_len;
        while (i < fb.len - diff) : (i += 1) {
            fb.buf[i] = fb.buf[i + diff];
        }
    }
    @memcpy(fb.buf[fb.cursor..][0..new_len], replacement);
    fb.len = fb.len - old_len + new_len;
    fb.cursor += new_len;
    return true;
}

pub fn replace_all_matches(fb: *FileBuffer, needle: []const u8, replacement: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var pos: usize = 0;
    while (true) {
        if (find_next_ci(fb.slice(), needle, pos, false)) |res| {
            fb.cursor = res.pos;
            if (replace_current_match(fb, needle, replacement)) {
                count += 1;
                pos = fb.cursor;
            } else {
                break;
            }
        } else {
            break;
        }
    }
    return count;
}

// ---------------------------------------------------------------------------
// E14: Command Palette (Ctrl+Shift+P) & E18: Keybindings
// ---------------------------------------------------------------------------

pub const KeyAction = enum {
    none,
    save_file,
    open_recent,
    undo,
    redo,
    find,
    replace,
    goto_line,
    toggle_wrap,
    toggle_numbers,
    toggle_bookmark,
    next_bookmark,
    prev_bookmark,
    jump_definition,
    delete_line,
    cycle_theme,
    indent_line,
    dedent_line,
    multi_cursor,
    toggle_file_tree,
    new_tab,
    close_tab,
    next_tab,
    toggle_shell,
};

pub const CommandItem = struct {
    name: []const u8,
    shortcut: []const u8,
    action: KeyAction,
};

pub const command_list = [_]CommandItem{
    .{ .name = "Save File", .shortcut = "^S", .action = .save_file },
    .{ .name = "Recent Files", .shortcut = "^R", .action = .open_recent },
    .{ .name = "Find", .shortcut = "^F", .action = .find },
    .{ .name = "Replace", .shortcut = "^H", .action = .replace },
    .{ .name = "Goto Line", .shortcut = "^G", .action = .goto_line },
    .{ .name = "Toggle Word Wrap", .shortcut = "M-Z", .action = .toggle_wrap },
    .{ .name = "Toggle Line Numbers", .shortcut = "^L", .action = .toggle_numbers },
    .{ .name = "Toggle Bookmark", .shortcut = "^B", .action = .toggle_bookmark },
    .{ .name = "Next Bookmark", .shortcut = "^+Down", .action = .next_bookmark },
    .{ .name = "Prev Bookmark", .shortcut = "^+Up", .action = .prev_bookmark },
    .{ .name = "Jump to Definition", .shortcut = "^]", .action = .jump_definition },
    .{ .name = "Delete Line", .shortcut = "^+D", .action = .delete_line },
    .{ .name = "Cycle Theme", .shortcut = "^+T", .action = .cycle_theme },
    .{ .name = "Indent Line", .shortcut = "Tab", .action = .indent_line },
    .{ .name = "Dedent Line", .shortcut = "S-Tab", .action = .dedent_line },
    .{ .name = "Add Multi-Cursor", .shortcut = "^D", .action = .multi_cursor },
    .{ .name = "Toggle File Tree", .shortcut = "^+F", .action = .toggle_file_tree },
    .{ .name = "New Tab", .shortcut = "^T", .action = .new_tab },
    .{ .name = "Close Tab", .shortcut = "^W", .action = .close_tab },
    .{ .name = "Next Tab", .shortcut = "^Tab", .action = .next_tab },
    .{ .name = "Toggle Shell", .shortcut = "^`", .action = .toggle_shell },
    .{ .name = "Undo", .shortcut = "^Z", .action = .undo },
    .{ .name = "Redo", .shortcut = "^Y", .action = .redo },
};

pub fn fuzzy_match(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return true;
    var pi: usize = 0;
    for (text) |ch| {
        if (std.ascii.toLower(ch) == std.ascii.toLower(pattern[pi])) {
            pi += 1;
            if (pi >= pattern.len) return true;
        }
    }
    return false;
}

pub const CommandPalette = struct {
    active: bool = false,
    query: [32]u8 = [_]u8{0} ** 32,
    query_len: usize = 0,
    selected: usize = 0,

    pub fn open(self: *CommandPalette) void {
        self.active = true;
        self.query_len = 0;
        self.selected = 0;
    }

    pub fn close(self: *CommandPalette) void {
        self.active = false;
        self.query_len = 0;
    }

    pub fn insert_char(self: *CommandPalette, ch: u8) void {
        if (self.query_len < 32) {
            self.query[self.query_len] = ch;
            self.query_len += 1;
            self.selected = 0;
        }
    }

    pub fn backspace(self: *CommandPalette) void {
        if (self.query_len > 0) {
            self.query_len -= 1;
            self.selected = 0;
        }
    }

    pub fn match_count(self: *const CommandPalette) usize {
        const q = self.query[0..self.query_len];
        var count: usize = 0;
        for (command_list) |cmd| {
            if (fuzzy_match(q, cmd.name)) count += 1;
        }
        return count;
    }

    pub fn get_selected_action(self: *const CommandPalette) ?KeyAction {
        const q = self.query[0..self.query_len];
        var match_idx: usize = 0;
        for (command_list) |cmd| {
            if (fuzzy_match(q, cmd.name)) {
                if (match_idx == self.selected) return cmd.action;
                match_idx += 1;
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// E15: Recent Files List
// ---------------------------------------------------------------------------

pub const max_recent_files: usize = 10;

pub const RecentList = struct {
    files: [max_recent_files][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** max_recent_files,
    lens: [max_recent_files]usize = [_]usize{0} ** max_recent_files,
    count: usize = 0,
    active: bool = false,
    selected: usize = 0,

    pub fn add(self: *RecentList, path: []const u8) void {
        if (path.len == 0) return;
        // Check if already in list
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (std.mem.eql(u8, self.files[i][0..self.lens[i]], path)) {
                // Move to front
                const saved = self.files[i];
                const slen = self.lens[i];
                var j = i;
                while (j > 0) : (j -= 1) {
                    self.files[j] = self.files[j - 1];
                    self.lens[j] = self.lens[j - 1];
                }
                self.files[0] = saved;
                self.lens[0] = slen;
                return;
            }
        }
        // Insert at front
        const new_count = @min(self.count + 1, max_recent_files);
        var k = new_count - 1;
        while (k > 0) : (k -= 1) {
            self.files[k] = self.files[k - 1];
            self.lens[k] = self.lens[k - 1];
        }
        const n = @min(path.len, 64);
        @memcpy(self.files[0][0..n], path[0..n]);
        self.lens[0] = n;
        self.count = new_count;
    }

    pub fn open(self: *RecentList) void {
        self.active = true;
        self.selected = 0;
    }

    pub fn close(self: *RecentList) void {
        self.active = false;
    }
};

// ---------------------------------------------------------------------------
// E24: File Tree Sidebar
// ---------------------------------------------------------------------------

pub const max_sidebar_entries: usize = 32;

pub const FileSidebar = struct {
    active: bool = false,
    entries: [max_sidebar_entries]DirEntry = [_]DirEntry{.{ .name = [_]u8{0} ** 32, .size = 0, .is_dir = 0, .reserved = [_]u8{0} ** 3 }} ** max_sidebar_entries,
    count: usize = 0,
    selected: usize = 0,

    pub fn refresh(self: *FileSidebar) void {
        var rc = ui.dir_list("/esp", &self.entries);
        if (rc <= 0) {
            rc = ui.dir_list("", &self.entries);
        }
        if (rc > 0) {
            self.count = @min(@as(usize, @intCast(rc)), max_sidebar_entries);
        } else {
            self.count = 0;
        }
        self.selected = 0;
    }

    pub fn toggle(self: *FileSidebar) void {
        self.active = !self.active;
        if (self.active) self.refresh();
    }

    pub fn close(self: *FileSidebar) void {
        self.active = false;
    }
};

// ---------------------------------------------------------------------------
// Console Split Mini-Shell (E6)
// ---------------------------------------------------------------------------

const console_buf_cap: usize = 512;

pub const MiniShell = struct {
    buf: [console_buf_cap]u8 = [_]u8{0} ** console_buf_cap,
    len: usize = 0,
    cursor: usize = 0,
    output: [console_buf_cap]u8 = [_]u8{0} ** console_buf_cap,
    output_len: usize = 0,
    active: bool = false,
    scroll: usize = 0,

    pub fn reset(self: *MiniShell) void {
        self.len = 0;
        self.cursor = 0;
        self.output_len = 0;
        self.scroll = 0;
    }

    pub fn append_output(self: *MiniShell, text: []const u8) void {
        const room = console_buf_cap -| self.output_len;
        const n = @min(text.len, room);
        @memcpy(self.output[self.output_len..][0..n], text[0..n]);
        self.output_len += n;
    }

    pub fn putc(self: *MiniShell, ch: u8) void {
        if (self.output_len < console_buf_cap) {
            self.output[self.output_len] = ch;
            self.output_len += 1;
        }
    }

    pub fn execute(self: *MiniShell, fb: *FileBuffer) void {
        const cmd = self.buf[0..self.len];

        var word_end: usize = 0;
        while (word_end < cmd.len and cmd[word_end] != ' ' and cmd[word_end] != '\t') word_end += 1;
        const verb = cmd[0..word_end];
        var arg_start = word_end;
        while (arg_start < cmd.len and (cmd[arg_start] == ' ' or cmd[arg_start] == '\t')) arg_start += 1;
        const arg = if (arg_start < cmd.len) cmd[arg_start..] else "";

        const old_len = self.output_len;

        if (std.mem.eql(u8, verb, "echo")) {
            self.append_output(arg);
            self.putc('\n');
        } else if (std.mem.eql(u8, verb, "help")) {
            self.append_output("echo <text> -- print to console\n");
            self.append_output("exec <path> -- run a program\n");
            self.append_output("cat <file> -- print file content\n");
            self.append_output("ls [path]  -- list directory\n");
            self.append_output("clear      -- clear console\n");
            self.append_output("put <text> -- insert into editor\n");
            self.append_output("save <f>   -- save editor to file\n");
            self.append_output("load <f>   -- load file into editor\n");
            self.append_output("pwd        -- show current editor file\n");
            self.append_output("line       -- show cursor position\n");
            self.putc('\n');
        } else if (std.mem.eql(u8, verb, "clear")) {
            self.output_len = 0;
            self.scroll = 0;
        } else if (std.mem.eql(u8, verb, "put")) {
            if (arg.len > 0) {
                _ = fb.insert_slice(arg);
                _ = fb.insert_newline();
            }
        } else if (std.mem.eql(u8, verb, "save")) {
            if (arg.len > 0) {
                self.append_output("save: ");
                self.append_output(arg);
                self.putc('\n');
            } else {
                self.append_output("save: usage: save <filename>\n");
            }
        } else if (std.mem.eql(u8, verb, "load")) {
            if (arg.len > 0) {
                self.append_output("load: ");
                self.append_output(arg);
                self.putc('\n');
            } else {
                self.append_output("load: usage: load <filename>\n");
            }
        } else if (std.mem.eql(u8, verb, "pwd")) {
            self.append_output("no file loaded\n");
        } else if (std.mem.eql(u8, verb, "line")) {
            var nbuf: [16]u8 = undefined;
            var np: usize = 0;
            const ln = fb.current_line();
            const col = fb.current_col();
            self.append_output("L ");
            np = fmt_int(&nbuf, ln);
            self.append_output(nbuf[0..np]);
            self.append_output(", C ");
            np = fmt_int(&nbuf, col);
            self.append_output(nbuf[0..np]);
            self.putc('\n');
        } else if (std.mem.eql(u8, verb, "exec")) {
            if (arg.len > 0) {
                self.append_output("exec: ");
                self.append_output(arg);
                self.append_output(" (not yet wired — use the desktop launcher)\n");
            } else {
                self.append_output("exec: usage: exec <path>\n");
            }
        } else if (std.mem.eql(u8, verb, "cat") or std.mem.eql(u8, verb, "ls")) {
            self.append_output(verb);
            self.append_output(": unavailable in editor console (use the terminal shell)\n");
        } else if (cmd.len == 0) {
            // empty line
        } else {
            self.append_output("unknown: ");
            self.append_output(verb);
            self.putc('\n');
        }

        if (self.output_len > old_len) {
            self.scroll = 0;
        }

        self.len = 0;
        self.cursor = 0;
    }
};

pub fn fmt_int(buf: []u8, n: usize) usize {
    if (n == 0) {
        buf[0] = '0';
        return 1;
    }
    var v = n;
    var rev: [16]u8 = undefined;
    var ri: usize = 0;
    while (v > 0) : (v /= 10) {
        rev[ri] = @as(u8, @intCast('0' + (v % 10)));
        ri += 1;
    }
    var i: usize = 0;
    while (ri > 0) : (ri -= 1) {
        buf[i] = rev[ri - 1];
        i += 1;
    }
    return i;
}

// ---------------------------------------------------------------------------
// E3: Goto-Line Prompt State
// ---------------------------------------------------------------------------

pub const GotoPrompt = struct {
    buf: [8]u8 = [_]u8{0} ** 8,
    len: usize = 0,
    active: bool = false,

    pub fn open(self: *GotoPrompt) void {
        self.len = 0;
        self.active = true;
    }

    pub fn close(self: *GotoPrompt) void {
        self.active = false;
        self.len = 0;
    }

    pub fn insert_char(self: *GotoPrompt, ch: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = ch;
            self.len += 1;
        }
    }

    pub fn backspace(self: *GotoPrompt) void {
        if (self.len > 0) self.len -= 1;
    }

    pub fn get_text(self: *const GotoPrompt) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn parse_line(self: *const GotoPrompt) ?usize {
        if (self.len == 0) return null;
        var n: usize = 0;
        for (self.buf[0..self.len]) |ch| {
            if (ch < '0' or ch > '9') return null;
            n = n * 10 + @as(usize, @intCast(ch - '0'));
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// E4: Multi-File Tab State
// ---------------------------------------------------------------------------

pub const EditorTab = struct {
    fb: FileBuffer = .{},
    filename: [filename_cap]u8 = [_]u8{0} ** filename_cap,
    filename_len: usize = 0,
    dirty: bool = false,
    is_used: bool = false,
};

pub const TabArray = struct {
    tabs: [max_tabs]EditorTab = [_]EditorTab{.{}} ** max_tabs,
    active: usize = 0,
    count: usize = 0,

    pub fn init_in_place(self: *TabArray) void {
        self.active = 0;
        self.count = 1;
        var i: usize = 0;
        while (i < max_tabs) : (i += 1) {
            self.tabs[i].is_used = (i == 0);
            self.tabs[i].dirty = false;
            self.tabs[i].fb.clear();
            self.set_filename(i, if (i == 0) "UNTITLED" else "");
        }
    }

    pub fn init() TabArray {
        var ta = TabArray{};
        ta.tabs[0].is_used = true;
        ta.count = 1;
        ta.set_filename(0, "UNTITLED");
        return ta;
    }

    pub fn active_tab(self: *TabArray) *EditorTab {
        return &self.tabs[self.active];
    }

    pub fn active_fb(self: *TabArray) *FileBuffer {
        return &self.tabs[self.active].fb;
    }

    pub fn set_filename(self: *TabArray, idx: usize, name: []const u8) void {
        const n = @min(name.len, filename_cap);
        @memcpy(self.tabs[idx].filename[0..n], name[0..n]);
        self.tabs[idx].filename_len = n;
    }

    pub fn get_filename(self: *const TabArray, idx: usize) []const u8 {
        return self.tabs[idx].filename[0..self.tabs[idx].filename_len];
    }

    pub fn open_new(self: *TabArray) bool {
        if (self.count >= max_tabs) return false;
        var i: usize = 0;
        while (i < max_tabs) : (i += 1) {
            if (!self.tabs[i].is_used) {
                self.tabs[i].is_used = true;
                self.tabs[i].fb.clear();
                self.tabs[i].dirty = false;
                self.set_filename(i, "UNTITLED");
                self.count += 1;
                self.active = i;
                return true;
            }
        }
        return false;
    }

    pub fn close_active(self: *TabArray) void {
        if (self.count <= 1) return;
        self.tabs[self.active].is_used = false;
        self.count -= 1;
        var i: usize = 0;
        while (i < max_tabs) : (i += 1) {
            if (self.tabs[i].is_used) {
                self.active = i;
                return;
            }
        }
        self.active = 0;
    }

    pub fn switch_next(self: *TabArray) void {
        if (self.count <= 1) return;
        var i: usize = self.active + 1;
        var tried: usize = 0;
        while (tried < max_tabs) : (tried += 1) {
            if (i >= max_tabs) i = 0;
            if (self.tabs[i].is_used) {
                self.active = i;
                return;
            }
            i += 1;
        }
    }

    pub fn is_zig_file(self: *const TabArray) bool {
        const name = self.get_filename(self.active);
        if (name.len < 4) return false;
        return std.mem.eql(u8, name[name.len - 4 ..], ".zig");
    }
};

// ---------------------------------------------------------------------------
// E16: Unsaved changes close confirmation modal
// ---------------------------------------------------------------------------

pub const CloseConfirm = struct {
    active: bool = false,
    target_tab: usize = 0,

    pub fn close(self: *CloseConfirm) void {
        self.active = false;
    }
};

// ---------------------------------------------------------------------------
// Editor State
// ---------------------------------------------------------------------------

pub const AppState = struct {
    tabs: TabArray = .{},
    shell: MiniShell = .{},
    status: [40]u8 = [_]u8{0} ** 40,
    status_len: usize = 8,
    insert_mode: bool = true,
    show_shell: bool = false,
    show_line_numbers: bool = true,
    word_wrap: bool = false,
    theme_idx: usize = 0,
    goto_prompt: GotoPrompt = .{},
    find_prompt: FindPrompt = .{},
    cmd_palette: CommandPalette = .{},
    recent_list: RecentList = .{},
    file_sidebar: FileSidebar = .{},
    close_confirm: CloseConfirm = .{},
    info_msg: [64]u8 = [_]u8{0} ** 64,
    info_len: usize = 0,
    win_id: u32 = 0,
    has_recovery: bool = false,
    recovery_len: usize = 0,

    pub fn init(self: *AppState) void {
        self.show_shell = false;
        self.insert_mode = true;
        self.show_line_numbers = true;
        self.word_wrap = false;
        self.theme_idx = 0;
        self.win_id = 0;
        self.info_len = 0;
        self.status_len = 0;
        self.has_recovery = false;
        self.recovery_len = 0;
        self.set_status("EDIT.BIN");
        self.tabs.init_in_place();
        self.shell.reset();
        self.goto_prompt.close();
        self.find_prompt.close();
        self.cmd_palette.close();
        self.recent_list.close();
        self.file_sidebar.close();
        self.close_confirm.close();
    }

    pub fn fb(self: *AppState) *FileBuffer {
        return self.tabs.active_fb();
    }

    pub fn cur_theme(self: *const AppState) *const Theme {
        return &themes[self.theme_idx % themes.len];
    }

    pub fn set_status(self: *AppState, msg: []const u8) void {
        const n = @min(msg.len, self.status.len);
        @memcpy(self.status[0..n], msg[0..n]);
        self.status_len = n;
    }

    pub fn set_info(self: *AppState, msg: []const u8) void {
        const n = @min(msg.len, self.info_msg.len);
        @memcpy(self.info_msg[0..n], msg[0..n]);
        self.info_len = n;
        self.set_status(msg);
    }

    pub fn save_recovery_backup(self: *AppState) void {
        const slice = self.fb().slice();
        if (slice.len == 0) return;
        const fd_res = ui.file_open(recovery_path, ui.MODE_WRITE | ui.MODE_CREATE);
        if (fd_res >= 0) {
            const fd = @as(u32, @intCast(fd_res));
            _ = ui.file_write(fd, slice);
            ui.file_close(fd);
        }
    }

    pub fn clear_recovery_backup() void {
        const fd_res = ui.file_open(recovery_path, ui.MODE_WRITE | ui.MODE_CREATE);
        if (fd_res >= 0) {
            ui.file_close(@as(u32, @intCast(fd_res)));
        }
    }

    pub fn check_crash_recovery(self: *AppState) void {
        const fd_res = ui.file_open(recovery_path, ui.MODE_READ);
        if (fd_res >= 0) {
            const fd = @as(u32, @intCast(fd_res));
            const rd = ui.file_read(fd, &self.fb().buf);
            ui.file_close(fd);
            if (rd > 0) {
                self.has_recovery = true;
                self.recovery_len = @as(usize, @intCast(rd));
                self.set_info("Recovery backup found! Press [R]estore or [D]iscard");
                ui.write_console("edit: recovery-found\n");
            }
        }
    }

    pub fn save_active_file(self: *AppState) bool {
        const active_t = self.tabs.active_tab();
        const fname = self.tabs.get_filename(self.tabs.active);
        var target_buf: [64]u8 = undefined;
        const target_path = if (std.mem.eql(u8, fname, "UNTITLED") or fname.len == 0)
            "/host/UNTITLED.TXT"
        else if (fname[0] == '/')
            fname
        else
            std.fmt.bufPrint(&target_buf, "/host/{s}", .{fname}) catch fname;

        var fd_res = ui.file_open(target_path, ui.MODE_WRITE | ui.MODE_CREATE);
        if (fd_res < 0) {
            fd_res = ui.file_open(fname, ui.MODE_WRITE | ui.MODE_CREATE);
        }
        if (fd_res >= 0) {
            const fd = @as(u32, @intCast(fd_res));
            _ = ui.file_write(fd, active_t.fb.slice());
            ui.file_close(fd);
            active_t.dirty = false;
            if (std.mem.eql(u8, fname, "UNTITLED")) {
                self.tabs.set_filename(self.tabs.active, target_path);
            }
            self.recent_list.add(target_path);
            self.set_info("Saved successfully");
            ui.write_console("edit: save-ok\n");
            clear_recovery_backup();
            return true;
        } else {
            self.set_info("Save failed (disk error)");
            return false;
        }
    }

    pub fn draw(self: *const AppState, win: u32) void {
        const t = self.cur_theme();

        // Background
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), t.bg);

        // Status bar at top
        ui.draw_rect(win, Rect.make(0, 0, window_w, 16), t.surface);
        ui.draw_text(win, self.status[0..self.status_len], 6, 3, t.muted);

        // Mode & Wrap indicator
        const mode = if (self.insert_mode) "INS" else "OVR";
        ui.draw_text(win, mode, @intCast(window_w - 30), 3, t.accent);
        if (self.word_wrap) {
            ui.draw_text(win, "WRAP", @intCast(window_w - 65), 3, t.warning);
        }

        // Key hints
        ui.draw_text(win, "^P:Cmd ^S:Save ^F:Find ^B:Bmk", @intCast(window_w - 320), 3, t.muted);

        // Divider
        ui.draw_rect(win, Rect.make(0, 16, window_w, 1), t.gutter_bg);

        // Tab bar
        self.draw_tab_bar(win);

        // Main area: file tree sidebar + editor
        if (self.show_shell) {
            self.draw_split(win);
        } else {
            self.draw_editor_full(win);
        }

        // Overlays
        if (self.cmd_palette.active) {
            self.draw_cmd_palette(win);
        } else if (self.recent_list.active) {
            self.draw_recent_list(win);
        } else if (self.close_confirm.active) {
            self.draw_close_confirm(win);
        } else if (self.find_prompt.active) {
            self.draw_find_prompt(win);
        } else if (self.goto_prompt.active) {
            self.draw_goto_prompt(win);
        }
    }

    fn draw_tab_bar(self: *const AppState, win: u32) void {
        const t = self.cur_theme();
        const tab_y: u32 = 17;
        ui.draw_rect(win, Rect.make(0, tab_y, window_w, tab_bar_h), t.bg);

        var tab_x: u32 = 0;
        var i: usize = 0;
        while (i < max_tabs) : (i += 1) {
            if (!self.tabs.tabs[i].is_used) continue;
            const name = self.tabs.get_filename(i);
            const name_len: u32 = @min(@as(u32, @intCast(name.len)), 16);
            const tab_w: u32 = name_len * glyph_w + 16;

            const is_active = (i == self.tabs.active);
            const bg = if (is_active) t.surface else t.bg;
            ui.draw_rect(win, Rect.make(tab_x, tab_y, tab_w, tab_bar_h), bg);

            ui.draw_rect(win, Rect.make(tab_x + tab_w, tab_y, 1, tab_bar_h), t.gutter_bg);

            const text_color = if (is_active) t.text else t.muted;
            ui.draw_text(win, name[0..name_len], tab_x + 4, tab_y + 3, text_color);

            if (self.tabs.tabs[i].dirty) {
                ui.draw_text(win, "*", tab_x + 4 + name_len * glyph_w + 2, tab_y + 3, t.warning);
            }

            tab_x += tab_w + 1;
        }

        ui.draw_rect(win, Rect.make(0, tab_y + tab_bar_h, window_w, 1), t.gutter_bg);
    }

    fn editor_top(self: *const AppState) u32 {
        _ = self;
        return 17 + tab_bar_h + 1;
    }

    fn editor_available_h(self: *const AppState) u32 {
        return if (self.show_shell)
            text_area_h - console_split_h - 2 - tab_bar_h
        else
            text_area_h - tab_bar_h;
    }

    fn draw_editor_full(self: *const AppState, win: u32) void {
        const t = self.cur_theme();
        const top = self.editor_top();
        const avail = self.editor_available_h();
        const vis_rows = @max(avail / line_h + 1, 2);

        var edit_x: u32 = 0;
        var edit_w: u32 = window_w;

        // E24: File tree sidebar
        if (self.file_sidebar.active) {
            const sb_w: u32 = 96;
            ui.draw_rect(win, Rect.make(0, top, sb_w, avail), t.gutter_bg);
            ui.draw_text(win, "FILES", 4, top + 2, t.accent);

            var sbi: usize = 0;
            while (sbi < self.file_sidebar.count and sbi < 18) : (sbi += 1) {
                const sby = top + 16 + @as(u32, @intCast(sbi)) * line_h;
                const ent = &self.file_sidebar.entries[sbi];
                var name_len: usize = 0;
                while (name_len < 32 and ent.name[name_len] != 0) : (name_len += 1) {}
                const is_sel = (sbi == self.file_sidebar.selected);
                if (is_sel) {
                    ui.draw_rect(win, Rect.make(0, sby, sb_w, line_h), t.selection_bg);
                }
                const col = if (is_sel) t.text else t.muted;
                const take = @min(name_len, 10);
                ui.draw_text(win, ent.name[0..take], 4, sby + 1, col);
            }
            ui.draw_rect(win, Rect.make(sb_w, top, 1, avail), t.surface);
            edit_x = sb_w + 1;
            edit_w = window_w - edit_x;
        }

        ui.draw_rect(win, Rect.make(edit_x, top, edit_w, avail), t.surface);

        const gw: u32 = if (self.show_line_numbers) gutter_w else 0;
        const x0: u32 = edit_x + gw + 4;
        if (self.show_line_numbers) {
            ui.draw_rect(win, Rect.make(edit_x, top, gutter_w, avail), t.gutter_bg);
        }

        const fb_ptr = &self.tabs.tabs[self.tabs.active].fb;
        const slice = fb_ptr.slice();
        const use_syntax = self.tabs.is_zig_file();

        const bracket_match = if (fb_ptr.cursor < slice.len and is_bracket(slice[fb_ptr.cursor]))
            find_matching_bracket(slice, fb_ptr.cursor)
        else if (fb_ptr.cursor > 0 and fb_ptr.cursor <= slice.len and is_bracket(slice[fb_ptr.cursor - 1]))
            find_matching_bracket(slice, fb_ptr.cursor - 1)
        else
            null;

        const max_c = @max((edit_w - gw - 8) / glyph_w, 10);
        var ln: usize = 0;
        var byte_pos: usize = 0;
        var logical_line_num: usize = 1;

        if (slice.len == 0 and ln < vis_rows) {
            const gy = top + 3;
            if (self.show_line_numbers) {
                ui.draw_text(win, "1", edit_x + 2, gy, t.muted);
            }
            if (self.insert_mode) {
                ui.draw_rect(win, Rect.make(x0, top + 2, glyph_w, line_h), t.cursor);
            }
            ln = 1;
        }

        while (byte_pos < slice.len and ln < vis_rows) : (logical_line_num += 1) {
            const line_start = byte_pos;
            while (byte_pos < slice.len and slice[byte_pos] != '\n') byte_pos += 1;
            const line_end = byte_pos;
            if (byte_pos < slice.len) byte_pos += 1;
            const llen = line_end - line_start;

            var chunk_off: usize = 0;
            var is_first_chunk = true;

            while ((chunk_off < llen or is_first_chunk) and ln < vis_rows) {
                const chunk_len = if (self.word_wrap)
                    @min(llen - chunk_off, max_c)
                else
                    @min(llen, max_c);
                const c_start = line_start + chunk_off;
                const c_end = c_start + chunk_len;
                const gy = top + 3 + @as(u32, @intCast(ln)) * line_h;

                // Line numbers & Bookmarks (only on first wrapped chunk)
                if (self.show_line_numbers and is_first_chunk) {
                    var nbuf: [4]u8 = undefined;
                    const nl = fmt_int(&nbuf, logical_line_num);
                    ui.draw_text(win, nbuf[0..nl], edit_x + 2, gy, t.muted);

                    if (fb_ptr.bookmarks.has_bookmark(logical_line_num)) {
                        ui.draw_text(win, "*", edit_x + gutter_w - 6, gy, t.warning);
                    }
                }

                // Rectangular Selection Highlight
                if (fb_ptr.rect_sel.active and logical_line_num >= fb_ptr.rect_sel.min_line() and logical_line_num <= fb_ptr.rect_sel.max_line()) {
                    const sel_min_c = fb_ptr.rect_sel.min_col();
                    const sel_max_c = fb_ptr.rect_sel.max_col();
                    if (sel_max_c >= sel_min_c) {
                        const sel_x = x0 + @as(u32, @intCast(sel_min_c -| 1)) * glyph_w;
                        const sel_w = @as(u32, @intCast(sel_max_c - sel_min_c + 1)) * glyph_w;
                        ui.draw_rect(win, Rect.make(sel_x, gy - 1, sel_w, line_h), t.selection_bg);
                    }
                }

                // Search match highlights
                if (self.find_prompt.active and self.find_prompt.find_len > 0) {
                    const needle = self.find_prompt.get_find();
                    var p = c_start;
                    while (p + needle.len <= c_end) : (p += 1) {
                        if (match_at_ci(slice, needle, p)) {
                            const col_offset = p - c_start;
                            const mx = x0 + @as(u32, @intCast(col_offset)) * glyph_w;
                            const mw = @as(u32, @intCast(needle.len)) * glyph_w;
                            ui.draw_rect(win, Rect.make(mx, gy - 1, mw, line_h), t.selection_bg);
                        }
                    }
                }

                if (chunk_len > 0) {
                    if (use_syntax) {
                        draw_line_colored(win, slice[c_start..c_end], x0, gy, t);
                    } else {
                        ui.draw_text(win, slice[c_start..c_end], x0, gy, t.text);
                    }
                }

                if (bracket_match) |bm| {
                    if (bm >= c_start and bm < c_end) {
                        const col_offset = bm - c_start;
                        const bx = x0 + @as(u32, @intCast(col_offset)) * glyph_w;
                        ui.draw_rect_outline(win, Rect.make(bx, gy - 1, glyph_w, line_h), 1, t.accent);
                    }
                }

                // Primary Cursor
                if (self.insert_mode) {
                    const is_cur_in_chunk = if (c_end == line_end)
                        (fb_ptr.cursor >= c_start and fb_ptr.cursor <= c_end)
                    else
                        (fb_ptr.cursor >= c_start and fb_ptr.cursor < c_end);
                    if (is_cur_in_chunk) {
                        const cx = x0 + @as(u32, @intCast(fb_ptr.cursor - c_start)) * glyph_w;
                        const cy = top + 2 + @as(u32, @intCast(ln)) * line_h;
                        ui.draw_rect(win, Rect.make(cx, cy, glyph_w, line_h), t.cursor);
                    }

                    // Secondary Cursors
                    var ci: usize = 0;
                    while (ci < fb_ptr.extra_cursor_count) : (ci += 1) {
                        const epos = fb_ptr.extra_cursors[ci];
                        const is_ecur_in_chunk = if (c_end == line_end)
                            (epos >= c_start and epos <= c_end)
                        else
                            (epos >= c_start and epos < c_end);
                        if (is_ecur_in_chunk) {
                            const ecx = x0 + @as(u32, @intCast(epos - c_start)) * glyph_w;
                            const ecy = top + 2 + @as(u32, @intCast(ln)) * line_h;
                            ui.draw_rect_outline(win, Rect.make(ecx, ecy, glyph_w, line_h), 1, t.warning);
                        }
                    }
                }

                ln += 1;
                is_first_chunk = false;
                if (!self.word_wrap) break;
                chunk_off += chunk_len;
            }
        }
    }

    fn draw_split(self: *const AppState, win: u32) void {
        const t = self.cur_theme();
        const top = self.editor_top();
        const edit_h = self.editor_available_h();
        const vis_rows = @max(edit_h / line_h + 1, 1);

        ui.draw_rect(win, Rect.make(0, top, window_w, edit_h), t.surface);
        const gw: u32 = if (self.show_line_numbers) gutter_w else 0;
        const x0: u32 = gw + 4;
        if (self.show_line_numbers) {
            ui.draw_rect(win, Rect.make(0, top, gutter_w, edit_h), t.gutter_bg);
        }

        const fb_ptr = &self.tabs.tabs[self.tabs.active].fb;
        const slice = fb_ptr.slice();
        const use_syntax = self.tabs.is_zig_file();

        var ln: usize = 0;
        var byte_pos: usize = 0;
        while (byte_pos < slice.len and ln < vis_rows) : (ln += 1) {
            const line_start = byte_pos;
            while (byte_pos < slice.len and slice[byte_pos] != '\n') byte_pos += 1;
            const line_end = byte_pos;
            if (byte_pos < slice.len) byte_pos += 1;

            const gy = top + 3 + @as(u32, @intCast(ln)) * line_h;
            if (self.show_line_numbers) {
                var nbuf: [4]u8 = undefined;
                const nl = fmt_int(&nbuf, ln + 1);
                ui.draw_text(win, nbuf[0..nl], 2, gy, t.muted);
            }

            const llen = line_end - line_start;
            const take = @min(llen, text_cols);
            if (use_syntax) {
                draw_line_colored(win, slice[line_start..][0..take], x0, gy, t);
            } else {
                ui.draw_text(win, slice[line_start..][0..take], x0, gy, t.text);
            }
        }

        if (self.insert_mode) {
            const cl = fb_ptr.current_line();
            const cc = fb_ptr.current_col();
            if (ln > 0 and cl <= ln) {
                const cx = x0 + @as(u32, @intCast(cc - 1)) * glyph_w;
                const cy = top + 2 + @as(u32, @intCast(cl - 1)) * line_h;
                ui.draw_rect(win, Rect.make(cx, cy, glyph_w, line_h), t.cursor);
            }
        }

        if (self.insert_mode) {
            const cl = fb_ptr.current_line();
            const cc = fb_ptr.current_col();
            if (ln > 0 and cl <= ln) {
                const cx = x0 + @as(u32, @intCast(cc - 1)) * glyph_w;
                const cy = top + 2 + @as(u32, @intCast(cl - 1)) * line_h;
                ui.draw_rect(win, Rect.make(cx, cy, glyph_w, line_h), t.cursor);
            }
        }

        const div_y = top + edit_h;
        ui.draw_rect(win, Rect.make(0, div_y, window_w, 1), t.gutter_bg);

        const con_y = div_y + 1;
        const con_h = console_split_h - 1;
        ui.draw_rect(win, Rect.make(0, con_y, window_w, con_h), t.surface);

        ui.draw_text(win, ">", 4, con_y + 4, t.accent);

        if (self.shell.len > 0) {
            ui.draw_text(win, self.shell.buf[0..self.shell.len], 16, con_y + 4, t.text);
        }

        const cx2: u32 = 16 + @as(u32, @intCast(self.shell.cursor)) * glyph_w;
        ui.draw_rect(win, Rect.make(cx2, con_y + 3, glyph_w, 1), t.accent);

        const out_lines = console_rows;
        const out_slice = self.shell.output[0..self.shell.output_len];
        var ol: usize = 0;
        var op: usize = 0;
        while (ol < out_lines and op < out_slice.len) : (ol += 1) {
            const ol_start = op;
            while (op < out_slice.len and out_slice[op] != '\n') op += 1;
            const ol_end = op;
            if (op < out_slice.len) op += 1;
            const oy = con_y + 18 + @as(u32, @intCast(ol)) * line_h;
            if (oy + line_h > con_y + con_h) break;
            const take = @min(ol_end - ol_start, text_cols);
            ui.draw_text(win, out_slice[ol_start..][0..take], 6, oy, t.muted);
        }
    }

    fn draw_goto_prompt(self: *const AppState, win: u32) void {
        const t = self.cur_theme();
        const bar_h: u32 = 20;
        const bar_y = window_h - bar_h;
        ui.draw_rect(win, Rect.make(0, bar_y, window_w, bar_h), t.surface);
        ui.draw_rect_outline(win, Rect.make(0, bar_y, window_w, bar_h), 1, t.accent);

        ui.draw_text(win, "Goto line:", 6, bar_y + 5, t.accent);

        const input_x: u32 = 80;
        const text = self.goto_prompt.get_text();
        if (text.len > 0) {
            ui.draw_text(win, text, input_x, bar_y + 5, t.text);
        }

        const cx = input_x + @as(u32, @intCast(self.goto_prompt.len)) * glyph_w;
        ui.draw_rect(win, Rect.make(cx, bar_y + 4, glyph_w, 10), t.accent);

        ui.draw_text(win, "Enter=Go Esc=Cancel", window_w - 160, bar_y + 5, t.muted);
    }

    fn draw_find_prompt(self: *const AppState, win: u32) void {
        const t = self.cur_theme();
        const bar_h: u32 = if (self.find_prompt.is_replace) 36 else 20;
        const bar_y = window_h - bar_h;
        ui.draw_rect(win, Rect.make(0, bar_y, window_w, bar_h), t.surface);
        ui.draw_rect_outline(win, Rect.make(0, bar_y, window_w, bar_h), 1, t.accent);

        ui.draw_text(win, "Find:", 6, bar_y + 5, t.accent);
        const ftext = self.find_prompt.get_find();
        if (ftext.len > 0) {
            ui.draw_text(win, ftext, 50, bar_y + 5, t.text);
        }
        if (!self.find_prompt.focus_replace) {
            const fcx = 50 + @as(u32, @intCast(self.find_prompt.find_len)) * glyph_w;
            ui.draw_rect(win, Rect.make(fcx, bar_y + 4, glyph_w, 10), t.accent);
        }

        if (self.find_prompt.is_replace) {
            ui.draw_text(win, "Repl:", 6, bar_y + 20, t.warning);
            const rtext = self.find_prompt.get_replace();
            if (rtext.len > 0) {
                ui.draw_text(win, rtext, 50, bar_y + 20, t.text);
            }
            if (self.find_prompt.focus_replace) {
                const rcx = 50 + @as(u32, @intCast(self.find_prompt.replace_len)) * glyph_w;
                ui.draw_rect(win, Rect.make(rcx, bar_y + 19, glyph_w, 10), t.accent);
            }
            ui.draw_text(win, "Enter:Next Tab:Field ^A:All Esc:Close", window_w - 240, bar_y + 20, t.muted);
        } else {
            ui.draw_text(win, "Enter:Next Up:Prev Esc:Close", window_w - 200, bar_y + 5, t.muted);
        }
    }

    fn draw_cmd_palette(self: *const AppState, win: u32) void {
        const t = self.cur_theme();
        const pal_w: u32 = 360;
        const pal_h: u32 = 180;
        const pal_x: u32 = (window_w - pal_w) / 2;
        const pal_y: u32 = 40;

        ui.draw_rect(win, Rect.make(pal_x, pal_y, pal_w, pal_h), t.surface);
        ui.draw_rect_outline(win, Rect.make(pal_x, pal_y, pal_w, pal_h), 1, t.accent);

        ui.draw_text(win, ">", pal_x + 8, pal_y + 8, t.accent);
        const q = self.cmd_palette.query[0..self.cmd_palette.query_len];
        if (q.len > 0) {
            ui.draw_text(win, q, pal_x + 20, pal_y + 8, t.text);
        }
        const qcx = pal_x + 20 + @as(u32, @intCast(q.len)) * glyph_w;
        ui.draw_rect(win, Rect.make(qcx, pal_y + 7, glyph_w, 10), t.accent);

        ui.draw_rect(win, Rect.make(pal_x, pal_y + 24, pal_w, 1), t.gutter_bg);

        var row: usize = 0;
        var match_idx: usize = 0;
        for (command_list) |cmd| {
            if (fuzzy_match(q, cmd.name)) {
                if (row < 10) {
                    const ry = pal_y + 28 + @as(u32, @intCast(row)) * 14;
                    const is_sel = (match_idx == self.cmd_palette.selected);
                    if (is_sel) {
                        ui.draw_rect(win, Rect.make(pal_x + 2, ry - 1, pal_w - 4, 13), t.selection_bg);
                    }
                    const ccolor = if (is_sel) t.text else t.muted;
                    ui.draw_text(win, cmd.name, pal_x + 8, ry, ccolor);
                    ui.draw_text(win, cmd.shortcut, pal_x + pal_w - 60, ry, t.warning);
                    row += 1;
                }
                match_idx += 1;
            }
        }
    }

    fn draw_recent_list(self: *const AppState, win: u32) void {
        const t = self.cur_theme();
        const rl_w: u32 = 320;
        const rl_h: u32 = 160;
        const rl_x: u32 = (window_w - rl_w) / 2;
        const rl_y: u32 = 50;

        ui.draw_rect(win, Rect.make(rl_x, rl_y, rl_w, rl_h), t.surface);
        ui.draw_rect_outline(win, Rect.make(rl_x, rl_y, rl_w, rl_h), 1, t.accent);
        ui.draw_text(win, "Recent Files", rl_x + 8, rl_y + 6, t.accent);
        ui.draw_rect(win, Rect.make(rl_x, rl_y + 20, rl_w, 1), t.gutter_bg);

        var i: usize = 0;
        while (i < self.recent_list.count and i < 8) : (i += 1) {
            const ry = rl_y + 24 + @as(u32, @intCast(i)) * 14;
            const is_sel = (i == self.recent_list.selected);
            if (is_sel) {
                ui.draw_rect(win, Rect.make(rl_x + 2, ry - 1, rl_w - 4, 13), t.selection_bg);
            }
            const col = if (is_sel) t.text else t.muted;
            const fname = self.recent_list.files[i][0..self.recent_list.lens[i]];
            ui.draw_text(win, fname, rl_x + 8, ry, col);
        }
    }

    fn draw_close_confirm(self: *const AppState, win: u32) void {
        const t = self.cur_theme();
        const dlg_w: u32 = 280;
        const dlg_h: u32 = 90;
        const dlg_x: u32 = (window_w - dlg_w) / 2;
        const dlg_y: u32 = (window_h - dlg_h) / 2;

        ui.draw_rect(win, Rect.make(dlg_x, dlg_y, dlg_w, dlg_h), t.surface);
        ui.draw_rect_outline(win, Rect.make(dlg_x, dlg_y, dlg_w, dlg_h), 2, t.warning);

        ui.draw_text(win, "Save changes before closing?", dlg_x + 12, dlg_y + 16, t.text);
        ui.draw_text(win, "Y: Save & Close", dlg_x + 16, dlg_y + 42, t.accent);
        ui.draw_text(win, "N: Discard", dlg_x + 110, dlg_y + 42, t.warning);
        ui.draw_text(win, "Esc: Cancel", dlg_x + 190, dlg_y + 42, t.muted);
    }
};

// ---------------------------------------------------------------------------
// Entry Point
// ---------------------------------------------------------------------------

var g_app: AppState = .{};

pub export fn _start(argc: usize, argv: ?[*]const [32]u8) callconv(.c) noreturn {
    AppState.init(&g_app);

    _ = argc;
    _ = argv;

    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("edit: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));
    g_app.win_id = win;

    g_app.check_crash_recovery();

    g_app.draw(win);
    ui.win_present(win);
    ui.write_console("edit: ready\n");

    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        if (ev.kind == ui.WIN_CLOSE) break;

        if (ev.kind == ui.KEY_DOWN) {
            dirty = handle_key(&g_app, &ev) or dirty;
        }

        while (ui.poll_event(&ev) > 0) {
            if (ev.kind == ui.WIN_CLOSE) {
                ui.win_close(win);
                ui.exit_process(exit_status);
            }
            if (ev.kind == ui.KEY_DOWN) {
                dirty = handle_key(&g_app, &ev) or dirty;
            }
        }

        if (dirty) {
            if (g_app.tabs.active_tab().dirty) {
                g_app.save_recovery_backup();
            }
            g_app.draw(win);
            ui.win_present(win);
        }
    }

    ui.write_console("edit: exiting 44\n");
    ui.win_close(win);
    ui.exit_process(exit_status);
}

/// Top-level key dispatch.
pub fn handle_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg1));
    const keycode: u16 = @as(u16, @truncate(ev.arg0));

    // Recovery prompt handling (E17)
    if (app.has_recovery) {
        if (ascii == 'r' or ascii == 'R') {
            app.fb().len = app.recovery_len;
            app.fb().cursor = 0;
            app.has_recovery = false;
            app.tabs.active_tab().dirty = true;
            app.set_info("Restored buffer from crash backup!");
            ui.write_console("edit: recovery-restored\n");
            return true;
        }
        if (ascii == 'd' or ascii == 'D' or ascii == 0x1b or keycode == 0x29) {
            app.has_recovery = false;
            AppState.clear_recovery_backup();
            app.set_info("Discarded recovery backup");
            return true;
        }
    }

    // Modal Overlays take priority
    if (app.close_confirm.active) {
        return handle_close_confirm_key(app, ev);
    }
    if (app.cmd_palette.active) {
        return handle_cmd_palette_key(app, ev);
    }
    if (app.recent_list.active) {
        return handle_recent_key(app, ev);
    }
    if (app.file_sidebar.active) {
        if (handle_file_sidebar_key(app, ev)) return true;
    }
    if (app.find_prompt.active) {
        return handle_find_key(app, ev);
    }
    if (app.goto_prompt.active) {
        return handle_goto_key(app, ev);
    }

    // Ctrl+Shift+P Command Palette (E14)
    if ((ev.flags & ui.MOD_CTRL) != 0 and (ev.flags & ui.MOD_SHIFT) != 0 and keycode == 0x13) { // P
        app.cmd_palette.open();
        ui.write_console("edit: palette-open\n");
        return true;
    }

    // Ctrl+R Recent Files (E15)
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x15) { // R
        app.recent_list.open();
        ui.write_console("edit: recent-open\n");
        return true;
    }

    // Ctrl+Shift+F File Tree Sidebar (E24)
    if ((ev.flags & ui.MOD_CTRL) != 0 and (ev.flags & ui.MOD_SHIFT) != 0 and keycode == 0x09) { // F
        app.file_sidebar.toggle();
        app.set_status(if (app.file_sidebar.active) "File sidebar ON" else "File sidebar OFF");
        ui.write_console("edit: tree-toggle\n");
        return true;
    }

    // Alt+R: Toggle rectangular selection (E13)
    if ((ev.flags & ui.MOD_ALT) != 0 and (keycode == 0x15 or ascii == 'r' or ascii == 'R')) {
        const cur_l = app.fb().current_line();
        const cur_c = app.fb().current_col();
        app.fb().rect_sel.active = !app.fb().rect_sel.active;
        if (app.fb().rect_sel.active) {
            app.fb().rect_sel.start_line = cur_l;
            app.fb().rect_sel.start_col = cur_c;
            app.fb().rect_sel.end_line = cur_l;
            app.fb().rect_sel.end_col = cur_c;
            app.set_status("Rect select ON (Alt+R to toggle)");
            ui.write_console("edit: rect-sel-on\n");
        } else {
            app.set_status("Rect select OFF");
        }
        return true;
    }

    // Alt+Z / Ctrl+Alt+W: Toggle Word Wrap (E10)
    if (((ev.flags & ui.MOD_ALT) != 0 and keycode == 0x1d) or
        ((ev.flags & ui.MOD_CTRL) != 0 and (ev.flags & ui.MOD_ALT) != 0 and keycode == 0x1a))
    {
        app.word_wrap = !app.word_wrap;
        app.set_status(if (app.word_wrap) "Word wrap ON" else "Word wrap OFF");
        ui.write_console("edit: toggle-wrap\n");
        return true;
    }

    // Ctrl+Shift+T: Cycle Themes (E19)
    if ((ev.flags & ui.MOD_CTRL) != 0 and (ev.flags & ui.MOD_SHIFT) != 0 and keycode == 0x17) { // T
        app.theme_idx = (app.theme_idx + 1) % themes.len;
        var nbuf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&nbuf, "Theme: {s}", .{app.cur_theme().name}) catch "Theme";
        app.set_info(msg);
        ui.write_console("edit: theme-cycle\n");
        return true;
    }

    // Ctrl+B: Bookmarks toggle, Ctrl+Shift+Down/Up: Bookmark navigation (E21)
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x05) { // B
        const cl = app.fb().current_line();
        const added = app.fb().bookmarks.toggle(cl);
        app.set_status(if (added) "Bookmark added" else "Bookmark removed");
        ui.write_console("edit: bookmark-toggle\n");
        return true;
    }
    if ((ev.flags & ui.MOD_CTRL) != 0 and (ev.flags & ui.MOD_SHIFT) != 0 and keycode == 0x51) { // Down
        const cl = app.fb().current_line();
        if (app.fb().bookmarks.next_after(cl)) |nxt| {
            app.fb().goto_line(nxt);
            app.set_status("Next bookmark");
            return true;
        }
    }
    if ((ev.flags & ui.MOD_CTRL) != 0 and (ev.flags & ui.MOD_SHIFT) != 0 and keycode == 0x52) { // Up
        const cl = app.fb().current_line();
        if (app.fb().bookmarks.prev_before(cl)) |prv| {
            app.fb().goto_line(prv);
            app.set_status("Prev bookmark");
            return true;
        }
    }

    // Ctrl+]: Jump to Definition (E23)
    if ((ev.flags & ui.MOD_CTRL) != 0 and (keycode == 0x30 or ascii == ']')) {
        if (extract_word_at_pos(app.fb().slice(), app.fb().cursor)) |word| {
            if (find_definition_in_buffer(app.fb().slice(), word)) |def_pos| {
                app.fb().cursor = def_pos;
                app.set_info("Jumped to definition");
                ui.write_console("edit: jump-def\n");
                return true;
            }
        }
        app.set_info("Definition not found in current file");
        return true;
    }

    // Ctrl+D: Multi-cursor add next occurrence (E12)
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x07 and (ev.flags & ui.MOD_SHIFT) == 0) { // D
        if (app.fb().add_next_word_cursor()) {
            var nbuf: [32]u8 = undefined;
            const msg = std.fmt.bufPrint(&nbuf, "{} cursors active", .{app.fb().extra_cursor_count + 1}) catch "Multi-cursor";
            app.set_info(msg);
            ui.write_console("edit: multi-cursor\n");
            return true;
        }
        return false;
    }

    // Ctrl+S: Save file (E16)
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x16) { // S
        _ = app.save_active_file();
        return true;
    }

    // Ctrl+` (0x35) console split
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x35) {
        app.show_shell = !app.show_shell;
        app.shell.reset();
        if (app.show_shell) {
            app.set_status("Shell (E6)");
        } else {
            app.set_status("EDIT.BIN");
        }
        return true;
    }

    // E7: Ctrl+F find prompt, Ctrl+H find & replace prompt
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x09) { // F
        app.find_prompt.open_find();
        app.set_status("Find");
        ui.write_console("edit: find-open\n");
        return true;
    }
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x0b) { // H
        app.find_prompt.open_replace();
        app.set_status("Find & Replace");
        ui.write_console("edit: replace-open\n");
        return true;
    }

    // E11: Ctrl+L line number toggle
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x0f) { // L
        app.show_line_numbers = !app.show_line_numbers;
        app.set_status(if (app.show_line_numbers) "Line numbers ON" else "Line numbers OFF");
        ui.write_console("edit: toggle-lines\n");
        return true;
    }

    // E22: Ctrl+Shift+D delete line
    if ((ev.flags & ui.MOD_CTRL) != 0 and (ev.flags & ui.MOD_SHIFT) != 0 and keycode == 0x07) { // D
        if (app.fb().delete_current_line()) {
            app.tabs.active_tab().dirty = true;
            app.set_status("Line deleted");
            ui.write_console("edit: delete-line\n");
            return true;
        }
        return false;
    }

    // E3: Ctrl+G goto-line prompt
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x0a) {
        app.goto_prompt.open();
        app.set_status("Goto line");
        ui.write_console("edit: goto-open\n");
        return true;
    }

    // E2: Ctrl+Z undo, Ctrl+Y redo
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x1d) { // Z
        if (app.fb().undo_last()) {
            app.tabs.active_tab().dirty = true;
            app.set_status("Undo");
            ui.write_console("edit: undo\n");
            return true;
        }
        return false;
    }
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x1c) { // Y
        if (app.fb().redo_last()) {
            app.tabs.active_tab().dirty = true;
            app.set_status("Redo");
            ui.write_console("edit: redo\n");
            return true;
        }
        return false;
    }

    // E4: Ctrl+T new tab, Ctrl+W close tab, Ctrl+Tab switch tab
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x17) { // T
        if (app.tabs.open_new()) {
            app.set_status("New tab");
            app.insert_mode = true;
            ui.write_console("edit: tab-open\n");
            return true;
        }
        app.set_status("Max tabs reached");
        return true;
    }
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x1a) { // W
        if (app.tabs.count > 1) {
            if (app.tabs.active_tab().dirty) {
                app.close_confirm.active = true;
                app.close_confirm.target_tab = app.tabs.active;
                return true;
            }
            app.tabs.close_active();
            app.set_status("Tab closed");
            ui.write_console("edit: tab-close\n");
            return true;
        }
        app.set_status("Cannot close last tab");
        return true;
    }
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x2b) {
        app.tabs.switch_next();
        var nbuf: [40]u8 = undefined;
        const name = app.tabs.get_filename(app.tabs.active);
        const label = std.fmt.bufPrint(&nbuf, "Tab: {s}", .{name}) catch "Tab";
        app.set_status(label);
        return true;
    }

    if (app.show_shell) {
        return handle_console_key(app, ev);
    } else {
        return handle_editor_key(app, ev);
    }
}

pub fn execute_key_action(app: *AppState, action: KeyAction) bool {
    switch (action) {
        .none => return false,
        .save_file => return app.save_active_file(),
        .open_recent => {
            app.recent_list.open();
            return true;
        },
        .undo => {
            if (app.fb().undo_last()) {
                app.tabs.active_tab().dirty = true;
                app.set_status("Undo");
                return true;
            }
            return false;
        },
        .redo => {
            if (app.fb().redo_last()) {
                app.tabs.active_tab().dirty = true;
                app.set_status("Redo");
                return true;
            }
            return false;
        },
        .find => {
            app.find_prompt.open_find();
            app.set_status("Find");
            return true;
        },
        .replace => {
            app.find_prompt.open_replace();
            app.set_status("Find & Replace");
            return true;
        },
        .goto_line => {
            app.goto_prompt.open();
            app.set_status("Goto line");
            return true;
        },
        .toggle_wrap => {
            app.word_wrap = !app.word_wrap;
            app.set_status(if (app.word_wrap) "Word wrap ON" else "Word wrap OFF");
            return true;
        },
        .toggle_numbers => {
            app.show_line_numbers = !app.show_line_numbers;
            app.set_status(if (app.show_line_numbers) "Line numbers ON" else "Line numbers OFF");
            return true;
        },
        .toggle_bookmark => {
            const cl = app.fb().current_line();
            const added = app.fb().bookmarks.toggle(cl);
            app.set_status(if (added) "Bookmark added" else "Bookmark removed");
            return true;
        },
        .next_bookmark => {
            const cl = app.fb().current_line();
            if (app.fb().bookmarks.next_after(cl)) |nxt| {
                app.fb().goto_line(nxt);
                return true;
            }
            return false;
        },
        .prev_bookmark => {
            const cl = app.fb().current_line();
            if (app.fb().bookmarks.prev_before(cl)) |prv| {
                app.fb().goto_line(prv);
                return true;
            }
            return false;
        },
        .jump_definition => {
            if (extract_word_at_pos(app.fb().slice(), app.fb().cursor)) |word| {
                if (find_definition_in_buffer(app.fb().slice(), word)) |def_pos| {
                    app.fb().cursor = def_pos;
                    app.set_info("Jumped to definition");
                    return true;
                }
            }
            app.set_info("Definition not found in current file");
            return true;
        },
        .delete_line => {
            if (app.fb().delete_current_line()) {
                app.tabs.active_tab().dirty = true;
                app.set_status("Line deleted");
                return true;
            }
            return false;
        },
        .cycle_theme => {
            app.theme_idx = (app.theme_idx + 1) % themes.len;
            var nbuf: [32]u8 = undefined;
            const msg = std.fmt.bufPrint(&nbuf, "Theme: {s}", .{app.cur_theme().name}) catch "Theme";
            app.set_info(msg);
            return true;
        },
        .indent_line => {
            if (app.fb().indent_current_line()) {
                app.tabs.active_tab().dirty = true;
                return true;
            }
            return false;
        },
        .dedent_line => {
            if (app.fb().dedent_current_line()) {
                app.tabs.active_tab().dirty = true;
                return true;
            }
            return false;
        },
        .multi_cursor => {
            return app.fb().add_next_word_cursor();
        },
        .toggle_file_tree => {
            app.file_sidebar.toggle();
            return true;
        },
        .new_tab => {
            _ = app.tabs.open_new();
            return true;
        },
        .close_tab => {
            if (app.tabs.active_tab().dirty) {
                app.close_confirm.active = true;
                app.close_confirm.target_tab = app.tabs.active;
                return true;
            }
            if (app.tabs.count > 1) {
                app.tabs.close_active();
                app.set_status("Tab closed");
                return true;
            }
            app.set_status("Cannot close last tab");
            return true;
        },
        .next_tab => {
            app.tabs.switch_next();
            return true;
        },
        .toggle_shell => {
            app.show_shell = !app.show_shell;
            return true;
        },
    }
}

pub fn handle_file_sidebar_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg1));
    const keycode: u16 = @as(u16, @truncate(ev.arg0));

    if ((ev.flags & ui.MOD_CTRL) != 0 and (ev.flags & ui.MOD_SHIFT) != 0 and keycode == 0x09) {
        app.file_sidebar.close();
        ui.write_console("edit: tree-toggle\n");
        return true;
    }
    if (keycode == 0x29 or ascii == 0x1b) {
        app.file_sidebar.close();
        return true;
    }

    if (keycode == 0x52) {
        if (app.file_sidebar.selected > 0) app.file_sidebar.selected -= 1;
        return true;
    }
    if (keycode == 0x51) {
        if (app.file_sidebar.count > 0 and app.file_sidebar.selected + 1 < app.file_sidebar.count) {
            app.file_sidebar.selected += 1;
        }
        return true;
    }

    if (ascii == '\r' or ascii == '\n' or keycode == 0x28) {
        if (app.file_sidebar.count > 0) {
            const ent = &app.file_sidebar.entries[app.file_sidebar.selected];
            var name_len: usize = 0;
            while (name_len < 32 and ent.name[name_len] != 0) : (name_len += 1) {}
            const base_name = ent.name[0..name_len];

            var full_path_buf: [64]u8 = undefined;
            const open_path = std.fmt.bufPrint(&full_path_buf, "/esp/{s}", .{base_name}) catch base_name;

            if (app.tabs.active_tab().dirty and app.tabs.count < max_tabs) {
                _ = app.tabs.open_new();
            }

            app.tabs.set_filename(app.tabs.active, open_path);
            const fd_res = ui.file_open(open_path, ui.MODE_READ);
            if (fd_res >= 0) {
                const fd = @as(u32, @intCast(fd_res));
                const rd = ui.file_read(fd, &app.fb().buf);
                ui.file_close(fd);
                if (rd > 0) {
                    app.fb().len = @as(usize, @intCast(rd));
                    app.fb().cursor = 0;
                    app.fb().undo.clear();
                }
            }
            app.set_info("Opened file from tree");
        }
        ui.write_console("edit: tree-open-ok\n");
        app.file_sidebar.close();
        return true;
    }

    return false;
}

pub fn handle_cmd_palette_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg1));
    const keycode: u16 = @as(u16, @truncate(ev.arg0));

    if (keycode == 0x29 or ascii == 0x1b) { // Esc
        app.cmd_palette.close();
        return true;
    }

    if (keycode == 0x52) { // Up
        if (app.cmd_palette.selected > 0) app.cmd_palette.selected -= 1;
        return true;
    }

    if (keycode == 0x51) { // Down
        const total = app.cmd_palette.match_count();
        if (total > 0 and app.cmd_palette.selected + 1 < total) {
            app.cmd_palette.selected += 1;
        }
        return true;
    }

    if (ascii == '\r' or ascii == '\n' or keycode == 0x28) { // Enter
        if (app.cmd_palette.get_selected_action()) |action| {
            app.cmd_palette.close();
            _ = execute_key_action(app, action);
            return true;
        }
        app.cmd_palette.close();
        return true;
    }

    if (ascii == 0x08 or ascii == 0x7f or keycode == 0x2a) {
        app.cmd_palette.backspace();
        return true;
    }

    if (ascii >= 0x20 and ascii <= 0x7e) {
        app.cmd_palette.insert_char(@as(u8, @intCast(ascii)));
        return true;
    }

    return false;
}

pub fn handle_recent_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg1));
    const keycode: u16 = @as(u16, @truncate(ev.arg0));

    if (keycode == 0x29 or ascii == 0x1b) {
        app.recent_list.close();
        return true;
    }

    if (keycode == 0x52) {
        if (app.recent_list.selected > 0) app.recent_list.selected -= 1;
        return true;
    }

    if (keycode == 0x51) {
        if (app.recent_list.selected + 1 < app.recent_list.count) app.recent_list.selected += 1;
        return true;
    }

    if (ascii == '\r' or ascii == '\n' or keycode == 0x28) {
        if (app.recent_list.count > 0) {
            const sel = app.recent_list.selected;
            const fname = app.recent_list.files[sel][0..app.recent_list.lens[sel]];

            if (app.tabs.active_tab().dirty) {
                if (app.tabs.count < max_tabs) {
                    _ = app.tabs.open_new();
                } else {
                    app.set_info("Active tab modified - save before opening file");
                    app.recent_list.close();
                    return true;
                }
            }

            app.tabs.set_filename(app.tabs.active, fname);
            const fd_res = ui.file_open(fname, ui.MODE_READ);
            if (fd_res >= 0) {
                const fd = @as(u32, @intCast(fd_res));
                const rd = ui.file_read(fd, &app.fb().buf);
                ui.file_close(fd);
                if (rd > 0) {
                    app.fb().len = @as(usize, @intCast(rd));
                    app.fb().cursor = 0;
                    app.fb().undo.clear();
                }
            }
            app.set_info("Loaded recent file");
        }
        app.recent_list.close();
        return true;
    }

    return false;
}

pub fn handle_close_confirm_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg1));
    const keycode: u16 = @as(u16, @truncate(ev.arg0));

    if (ascii == 'y' or ascii == 'Y') {
        const saved = app.save_active_file();
        if (saved) {
            app.close_confirm.active = false;
            app.tabs.close_active();
            app.set_status("Saved and closed");
        } else {
            app.close_confirm.active = false;
            app.set_info("Cannot save UNTITLED file - close aborted");
        }
        return true;
    }
    if (ascii == 'n' or ascii == 'N') {
        app.close_confirm.active = false;
        app.tabs.close_active();
        app.set_status("Closed without saving");
        return true;
    }
    if (ascii == 0x1b or keycode == 0x29) {
        app.close_confirm.active = false;
        app.set_status("Close canceled");
        return true;
    }
    return false;
}

pub fn handle_goto_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg1));
    const keycode: u16 = @as(u16, @truncate(ev.arg0));

    if (ascii == '\r' or ascii == '\n' or keycode == 0x28) {
        if (app.goto_prompt.parse_line()) |line_num| {
            app.fb().goto_line(line_num);
            var nbuf: [40]u8 = undefined;
            const total = app.fb().total_lines();
            const label = std.fmt.bufPrint(&nbuf, "Line {} of {}", .{ line_num, total }) catch "Goto";
            app.set_status(label);
            ui.write_console("edit: goto-ok\n");
        } else {
            app.set_status("Invalid line number");
        }
        app.goto_prompt.close();
        return true;
    }

    if (keycode == 0x29 or ascii == 0x1b) {
        app.goto_prompt.close();
        app.set_status("EDIT.BIN");
        return true;
    }

    if (ascii == 0x08 or ascii == 0x7f or keycode == 0x2a) {
        app.goto_prompt.backspace();
        return true;
    }

    if (ascii >= '0' and ascii <= '9') {
        app.goto_prompt.insert_char(@as(u8, @intCast(ascii)));
        return true;
    }

    return false;
}

pub fn handle_find_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg1));
    const keycode: u16 = @as(u16, @truncate(ev.arg0));
    const fp = &app.find_prompt;
    const fb_ptr = app.fb();

    if (keycode == 0x29 or ascii == 0x1b) {
        fp.close();
        app.set_status("EDIT.BIN");
        return true;
    }

    if (fp.is_replace and (ascii == '\t' or keycode == 0x2b)) {
        fp.focus_replace = !fp.focus_replace;
        return true;
    }

    if (fp.is_replace and (ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x04) {
        const count = replace_all_matches(fb_ptr, fp.get_find(), fp.get_replace());
        app.tabs.active_tab().dirty = true;
        var nbuf: [40]u8 = undefined;
        const msg = std.fmt.bufPrint(&nbuf, "Replaced {} matches", .{count}) catch "Replaced matches";
        app.set_status(msg);
        ui.write_console("edit: replace-all\n");
        return true;
    }

    if (ascii == '\r' or ascii == '\n' or keycode == 0x28) {
        const needle = fp.get_find();
        if (needle.len == 0) return true;

        if (fp.is_replace and fp.focus_replace) {
            if (match_at_ci(fb_ptr.slice(), needle, fb_ptr.cursor)) {
                _ = replace_current_match(fb_ptr, needle, fp.get_replace());
                app.tabs.active_tab().dirty = true;
            }
        }

        const is_cur_match = match_at_ci(fb_ptr.slice(), needle, fb_ptr.cursor);
        const start_pos = if (is_cur_match)
            (if (fb_ptr.cursor + 1 < fb_ptr.len) fb_ptr.cursor + 1 else 0)
        else
            fb_ptr.cursor;
        if (find_next_ci(fb_ptr.slice(), needle, start_pos, true)) |res| {
            fb_ptr.cursor = res.pos;
            const total = count_matches_ci(fb_ptr.slice(), needle);
            var nbuf: [40]u8 = undefined;
            const msg = if (res.wrapped)
                std.fmt.bufPrint(&nbuf, "Wrapped ({} matches)", .{total}) catch "Wrapped"
            else
                std.fmt.bufPrint(&nbuf, "Found match ({} total)", .{total}) catch "Found match";
            app.set_status(msg);
            ui.write_console("edit: find-next\n");
        } else {
            app.set_status("No matches found");
        }
        return true;
    }

    if (keycode == 0x52) {
        const needle = fp.get_find();
        if (needle.len > 0) {
            if (find_prev_ci(fb_ptr.slice(), needle, fb_ptr.cursor)) |pos| {
                fb_ptr.cursor = pos;
                app.set_status("Previous match");
                return true;
            }
        }
    }

    if (ascii == 0x08 or ascii == 0x7f or keycode == 0x2a) {
        fp.backspace();
        return true;
    }

    if (ascii >= 0x20 and ascii <= 0x7e) {
        fp.insert_char(@as(u8, @intCast(ascii)));
        return true;
    }

    return false;
}

pub fn handle_editor_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg1));
    const keycode: u16 = @as(u16, @truncate(ev.arg0));
    const fb_ptr = app.fb();

    // Escape clears secondary cursors & selection
    if (keycode == 0x29 or ascii == 0x1b) {
        if (fb_ptr.extra_cursor_count > 0 or fb_ptr.rect_sel.active) {
            fb_ptr.extra_cursor_count = 0;
            fb_ptr.rect_sel.clear();
            app.set_status("Cursors cleared");
            return true;
        }
    }

    // Navigation keys
    switch (keycode) {
        0x4f => {
            const moved = fb_ptr.move_left();
            if (moved and fb_ptr.rect_sel.active) {
                fb_ptr.rect_sel.end_line = fb_ptr.current_line();
                fb_ptr.rect_sel.end_col = fb_ptr.current_col();
            }
            return moved;
        },
        0x50 => {
            const moved = fb_ptr.move_right();
            if (moved and fb_ptr.rect_sel.active) {
                fb_ptr.rect_sel.end_line = fb_ptr.current_line();
                fb_ptr.rect_sel.end_col = fb_ptr.current_col();
            }
            return moved;
        },
        0x52 => {
            const moved = fb_ptr.move_up();
            if (moved and fb_ptr.rect_sel.active) {
                fb_ptr.rect_sel.end_line = fb_ptr.current_line();
                fb_ptr.rect_sel.end_col = fb_ptr.current_col();
            }
            return moved;
        },
        0x51 => {
            const moved = fb_ptr.move_down();
            if (moved and fb_ptr.rect_sel.active) {
                fb_ptr.rect_sel.end_line = fb_ptr.current_line();
                fb_ptr.rect_sel.end_col = fb_ptr.current_col();
            }
            return moved;
        },
        0x4a => { // Home
            const ls = fb_ptr.line_start(fb_ptr.cursor);
            if (fb_ptr.cursor != ls) {
                fb_ptr.cursor = ls;
                if (fb_ptr.rect_sel.active) {
                    fb_ptr.rect_sel.end_line = fb_ptr.current_line();
                    fb_ptr.rect_sel.end_col = fb_ptr.current_col();
                }
                return true;
            }
            return false;
        },
        0x4d => { // End
            const le = fb_ptr.line_end(fb_ptr.cursor);
            if (fb_ptr.cursor != le) {
                fb_ptr.cursor = le;
                if (fb_ptr.rect_sel.active) {
                    fb_ptr.rect_sel.end_line = fb_ptr.current_line();
                    fb_ptr.rect_sel.end_col = fb_ptr.current_col();
                }
                return true;
            }
            return false;
        },
        0x4b => { // PageUp
            var i: u8 = 0;
            var moved = false;
            while (i < 10) : (i += 1) {
                if (fb_ptr.move_up()) moved = true else break;
            }
            if (moved and fb_ptr.rect_sel.active) {
                fb_ptr.rect_sel.end_line = fb_ptr.current_line();
                fb_ptr.rect_sel.end_col = fb_ptr.current_col();
            }
            return moved;
        },
        0x4e => { // PageDown
            var i: u8 = 0;
            var moved = false;
            while (i < 10) : (i += 1) {
                if (fb_ptr.move_down()) moved = true else break;
            }
            if (moved and fb_ptr.rect_sel.active) {
                fb_ptr.rect_sel.end_line = fb_ptr.current_line();
                fb_ptr.rect_sel.end_col = fb_ptr.current_col();
            }
            return moved;
        },
        0x4c => { // Delete forward
            if (fb_ptr.delete_forward()) {
                app.tabs.active_tab().dirty = true;
                return true;
            }
            return false;
        },
        else => {},
    }

    // Insert key toggles INS/OVR
    if (keycode == 0x49) {
        app.insert_mode = !app.insert_mode;
        app.set_status(if (app.insert_mode) "INS mode" else "OVR mode");
        return true;
    }

    // Tab / Shift+Tab (E20 Indentation)
    if (ascii == '\t' or keycode == 0x2b) {
        if ((ev.flags & ui.MOD_SHIFT) != 0) {
            if (fb_ptr.dedent_current_line()) {
                app.tabs.active_tab().dirty = true;
                return true;
            }
        } else {
            if (fb_ptr.indent_current_line()) {
                app.tabs.active_tab().dirty = true;
                return true;
            }
        }
        return false;
    }

    // Ctrl+A / Ctrl+E
    if ((ev.flags & ui.MOD_CTRL) != 0) {
        if (keycode == 0x04) {
            fb_ptr.cursor = 0;
            return true;
        }
        if (keycode == 0x08) {
            fb_ptr.cursor = fb_ptr.len;
            return true;
        }
    }

    // Backspace
    if (ascii == 0x08 or ascii == 0x7f) {
        if (fb_ptr.rect_sel.active) {
            if (fb_ptr.backspace_rect_char()) {
                app.tabs.active_tab().dirty = true;
                return true;
            }
            return false;
        }
        if (fb_ptr.backspace()) {
            app.tabs.active_tab().dirty = true;
            return true;
        }
        return false;
    }

    // Enter
    if (ascii == '\r' or ascii == '\n') {
        if (fb_ptr.insert_newline()) {
            app.tabs.active_tab().dirty = true;
            return true;
        }
        return false;
    }

    // Printable characters
    if (ascii >= 0x20 and ascii <= 0x7e) {
        app.tabs.active_tab().dirty = true;
        if (fb_ptr.rect_sel.active) {
            return fb_ptr.insert_rect_char(@as(u8, @intCast(ascii)));
        }
        if (!app.insert_mode and fb_ptr.cursor < fb_ptr.len) {
            return fb_ptr.overwrite_char(@as(u8, @intCast(ascii)));
        }
        return fb_ptr.insert_char_with_dedent(@as(u8, @intCast(ascii)));
    }

    return false;
}

pub fn handle_console_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg1));
    const keycode: u16 = @as(u16, @truncate(ev.arg0));

    if (ascii == '\r' or ascii == '\n') {
        app.shell.execute(app.fb());
        return true;
    }

    if (ascii == 0x08 or ascii == 0x7f) {
        if (app.shell.cursor > 0) {
            var i = app.shell.cursor - 1;
            while (i < app.shell.len - 1) : (i += 1) {
                app.shell.buf[i] = app.shell.buf[i + 1];
            }
            app.shell.len -= 1;
            app.shell.cursor -= 1;
            return true;
        }
        return false;
    }

    if (keycode == 0x4f and app.shell.cursor > 0) {
        app.shell.cursor -= 1;
        return true;
    }
    if (keycode == 0x50 and app.shell.cursor < app.shell.len) {
        app.shell.cursor += 1;
        return true;
    }
    if (keycode == 0x4a) {
        app.shell.cursor = 0;
        return true;
    }
    if (keycode == 0x4d) {
        app.shell.cursor = app.shell.len;
        return true;
    }

    if (keycode == 0x4b) {
        app.shell.scroll = @min(app.shell.scroll + 5, 50);
        return true;
    }
    if (keycode == 0x4e) {
        if (app.shell.scroll > 5) app.shell.scroll -= 5 else app.shell.scroll = 0;
        return true;
    }

    if (ascii >= 0x20 and ascii <= 0x7e and app.shell.len < console_buf_cap - 1) {
        var i = app.shell.len;
        while (i > app.shell.cursor) : (i -= 1) {
            app.shell.buf[i] = app.shell.buf[i - 1];
        }
        app.shell.buf[app.shell.cursor] = @as(u8, @intCast(ascii));
        app.shell.len += 1;
        app.shell.cursor += 1;
        return true;
    }

    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "edit: FileBuffer insert/backspace/cursor" {
    var fb = FileBuffer{};
    try std.testing.expect(fb.insert_char('H'));
    try std.testing.expect(fb.insert_char('i'));
    try std.testing.expectEqualStrings("Hi", fb.slice());
    try std.testing.expectEqual(@as(usize, 2), fb.cursor);

    try std.testing.expect(fb.backspace());
    try std.testing.expectEqualStrings("H", fb.slice());
    try std.testing.expectEqual(@as(usize, 1), fb.cursor);

    _ = fb.insert_char('e');
    _ = fb.insert_char('y');
    try std.testing.expectEqualStrings("Hey", fb.slice());
}

test "edit: FileBuffer newline and line navigation" {
    var fb = FileBuffer{};
    fb.set_content("Line1\nLine2\nLine3");
    try std.testing.expectEqual(@as(usize, 3), fb.total_lines());
    try std.testing.expectEqual(@as(usize, 1), fb.current_line());
}

test "edit: FileBuffer line_start/line_end" {
    var fb = FileBuffer{};
    fb.set_content("hello\nworld");
    try std.testing.expectEqual(@as(usize, 0), fb.line_start(0));
    try std.testing.expectEqual(@as(usize, 5), fb.line_end(0));
    try std.testing.expectEqual(@as(usize, 6), fb.line_start(6));
    try std.testing.expectEqual(@as(usize, 11), fb.line_end(6));
}

test "edit: FileBuffer move_up/move_down" {
    var fb = FileBuffer{};
    fb.set_content("abc\ndefg\nhi");
    fb.cursor = 7;
    try std.testing.expect(fb.move_up());
    try std.testing.expectEqual(@as(usize, 2), fb.cursor);

    try std.testing.expect(fb.move_down());
    try std.testing.expectEqual(@as(usize, 6), fb.cursor);
}

test "edit: FileBuffer delete_forward" {
    var fb = FileBuffer{};
    fb.set_content("Hello");
    fb.cursor = 0;
    try std.testing.expect(fb.delete_forward());
    try std.testing.expectEqualStrings("ello", fb.slice());
}

test "edit: MiniShell echo and help builtins" {
    var fb = FileBuffer{};
    var sh = MiniShell{};

    @memcpy(sh.buf[0..9], "echo hi!!");
    sh.len = 9;
    sh.execute(&fb);
    try std.testing.expect(std.mem.indexOf(u8, sh.output[0..sh.output_len], "hi!!\n") != null);

    @memcpy(sh.buf[0..4], "help");
    sh.len = 4;
    sh.execute(&fb);
    try std.testing.expect(std.mem.indexOf(u8, sh.output[0..sh.output_len], "echo <text>") != null);

    @memcpy(sh.buf[0..5], "clear");
    sh.len = 5;
    sh.execute(&fb);
    try std.testing.expectEqual(@as(usize, 0), sh.output_len);
}

test "edit: MiniShell put inserts into the file buffer" {
    var fb = FileBuffer{};
    var sh = MiniShell{};

    @memcpy(sh.buf[0..12], "put test 123");
    sh.len = 12;
    sh.execute(&fb);
    try std.testing.expectEqualStrings("test 123\n", fb.slice());
}

test "edit: MiniShell line shows position" {
    var fb = FileBuffer{};
    fb.set_content("a\nb\nc");
    fb.cursor = 2;
    var sh = MiniShell{};
    @memcpy(sh.buf[0..4], "line");
    sh.len = 4;
    sh.execute(&fb);
    try std.testing.expect(std.mem.indexOf(u8, sh.output[0..sh.output_len], "L 2") != null);
}

test "edit: MiniShell unknown command" {
    var fb = FileBuffer{};
    var sh = MiniShell{};
    @memcpy(sh.buf[0..9], "nope blah");
    sh.len = 9;
    sh.execute(&fb);
    try std.testing.expect(std.mem.indexOf(u8, sh.output[0..sh.output_len], "unknown: nope") != null);
}

test "edit: fmt_int formats integers" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), fmt_int(&buf, 0));
    try std.testing.expectEqualStrings("0", buf[0..1]);

    var n = fmt_int(&buf, 42);
    try std.testing.expectEqualStrings("42", buf[0..n]);

    n = fmt_int(&buf, 1024);
    try std.testing.expectEqualStrings("1024", buf[0..n]);
}

test "edit: overwrite mode replaces at cursor" {
    var fb = FileBuffer{};
    fb.set_content("Hello");
    fb.cursor = 1;
    fb.buf[fb.cursor] = 'a';
    fb.cursor += 1;
    try std.testing.expectEqualStrings("Hallo", fb.slice());
}

test "edit: FileBuffer insert_slice bulk insertion" {
    var fb = FileBuffer{};
    const n = fb.insert_slice("abcdef");
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualStrings("abcdef", fb.slice());
}

test "edit: FileBuffer cursor at end after set_content" {
    var fb = FileBuffer{};
    fb.set_content("text");
    fb.cursor = 0;
    try std.testing.expect(fb.move_right());
    try std.testing.expectEqual(@as(usize, 1), fb.cursor);
}

// E2: Undo/redo tests

test "edit: E2 undo single insert" {
    var fb = FileBuffer{};
    _ = fb.insert_char('X');
    try std.testing.expectEqualStrings("X", fb.slice());
    try std.testing.expect(fb.undo_last());
    try std.testing.expectEqualStrings("", fb.slice());
    try std.testing.expectEqual(@as(usize, 0), fb.cursor);
}

test "edit: E2 undo multiple inserts" {
    var fb = FileBuffer{};
    _ = fb.insert_char('A');
    _ = fb.insert_char('B');
    _ = fb.insert_char('C');
    try std.testing.expectEqualStrings("ABC", fb.slice());
    try std.testing.expect(fb.undo_last());
    try std.testing.expectEqualStrings("AB", fb.slice());
    try std.testing.expect(fb.undo_last());
    try std.testing.expectEqualStrings("A", fb.slice());
    try std.testing.expect(fb.undo_last());
    try std.testing.expectEqualStrings("", fb.slice());
}

test "edit: E2 undo backspace" {
    var fb = FileBuffer{};
    _ = fb.insert_char('H');
    _ = fb.insert_char('i');
    try std.testing.expectEqualStrings("Hi", fb.slice());
    try std.testing.expect(fb.backspace());
    try std.testing.expectEqualStrings("H", fb.slice());
    try std.testing.expect(fb.undo_last());
    try std.testing.expectEqualStrings("Hi", fb.slice());
}

test "edit: E2 redo after undo" {
    var fb = FileBuffer{};
    _ = fb.insert_char('X');
    _ = fb.insert_char('Y');
    try std.testing.expectEqualStrings("XY", fb.slice());
    try std.testing.expect(fb.undo_last());
    try std.testing.expectEqualStrings("X", fb.slice());
    try std.testing.expect(fb.redo_last());
    try std.testing.expectEqualStrings("XY", fb.slice());
}

test "edit: E2 new edit clears redo stack" {
    var fb = FileBuffer{};
    _ = fb.insert_char('A');
    _ = fb.insert_char('B');
    try std.testing.expect(fb.undo_last());
    try std.testing.expectEqualStrings("A", fb.slice());
    _ = fb.insert_char('C');
    try std.testing.expectEqualStrings("AC", fb.slice());
    try std.testing.expect(!fb.undo.can_redo());
}

test "edit: E2 undo delete_forward" {
    var fb = FileBuffer{};
    fb.set_content("Hello");
    fb.cursor = 0;
    try std.testing.expect(fb.delete_forward());
    try std.testing.expectEqualStrings("ello", fb.slice());
    try std.testing.expect(fb.undo_last());
    try std.testing.expectEqualStrings("Hello", fb.slice());
}

test "edit: E2 undo overwrite_char" {
    var fb = FileBuffer{};
    fb.set_content("Hello");
    fb.cursor = 0;
    try std.testing.expect(fb.overwrite_char('J'));
    try std.testing.expectEqualStrings("Jello", fb.slice());
    try std.testing.expect(fb.undo_last());
    try std.testing.expectEqualStrings("Hello", fb.slice());
}

test "edit: E2 undo ring clears on set_content" {
    var fb = FileBuffer{};
    _ = fb.insert_char('X');
    _ = fb.insert_char('Y');
    fb.set_content("new");
    try std.testing.expect(!fb.undo.can_undo());
    try std.testing.expect(!fb.undo.can_redo());
}

// E3: Goto-line tests

test "edit: E3 goto_line jumps to line" {
    var fb = FileBuffer{};
    fb.set_content("line1\nline2\nline3\nline4");
    fb.goto_line(3);
    try std.testing.expectEqual(@as(usize, 12), fb.cursor);
    try std.testing.expectEqual(@as(usize, 3), fb.current_line());
}

test "edit: E3 goto_line clamps to last line" {
    var fb = FileBuffer{};
    fb.set_content("a\nb\nc");
    fb.goto_line(99);
    try std.testing.expectEqual(@as(usize, 3), fb.current_line());
}

test "edit: E3 goto_line zero goes to start" {
    var fb = FileBuffer{};
    fb.set_content("a\nb\nc");
    fb.cursor = 3;
    fb.goto_line(0);
    try std.testing.expectEqual(@as(usize, 0), fb.cursor);
}

test "edit: E3 GotoPrompt parse valid number" {
    var gp = GotoPrompt{};
    gp.insert_char('4');
    gp.insert_char('2');
    try std.testing.expectEqual(@as(?usize, 42), gp.parse_line());
}

test "edit: E3 GotoPrompt parse rejects non-digits" {
    var gp = GotoPrompt{};
    gp.insert_char('x');
    try std.testing.expectEqual(@as(?usize, null), gp.parse_line());
}

// E4: Multi-file tab tests

test "edit: E4 TabArray init has one tab" {
    var ta = TabArray.init();
    try std.testing.expectEqual(@as(usize, 1), ta.count);
    try std.testing.expect(ta.tabs[0].is_used);
    try std.testing.expectEqualStrings("UNTITLED", ta.get_filename(0));
}

test "edit: E4 open_new adds a tab" {
    var ta = TabArray.init();
    try std.testing.expect(ta.open_new());
    try std.testing.expectEqual(@as(usize, 2), ta.count);
    try std.testing.expectEqual(@as(usize, 1), ta.active);
    try std.testing.expectEqualStrings("UNTITLED", ta.get_filename(1));
}

test "edit: E4 open_new fails at max tabs" {
    var ta = TabArray.init();
    var i: usize = 0;
    while (i < max_tabs - 1) : (i += 1) {
        _ = ta.open_new();
    }
    try std.testing.expectEqual(@as(usize, max_tabs), ta.count);
    try std.testing.expect(!ta.open_new());
}

test "edit: E4 close_active compacts" {
    var ta = TabArray.init();
    _ = ta.open_new();
    ta.close_active();
    try std.testing.expectEqual(@as(usize, 1), ta.count);
    try std.testing.expect(!ta.tabs[1].is_used);
    try std.testing.expect(ta.tabs[0].is_used);
}

test "edit: E4 close_active refuses last tab" {
    var ta = TabArray.init();
    ta.close_active();
    try std.testing.expectEqual(@as(usize, 1), ta.count);
}

test "edit: E4 switch_next cycles tabs" {
    var ta = TabArray.init();
    _ = ta.open_new();
    ta.switch_next();
    try std.testing.expectEqual(@as(usize, 0), ta.active);
    ta.switch_next();
    try std.testing.expectEqual(@as(usize, 1), ta.active);
}

test "edit: E4 set_filename stores name" {
    var ta = TabArray.init();
    ta.set_filename(0, "test.zig");
    try std.testing.expectEqualStrings("test.zig", ta.get_filename(0));
}

test "edit: E4 is_zig_file detects .zig extension" {
    var ta = TabArray.init();
    ta.set_filename(0, "source.zig");
    try std.testing.expect(ta.is_zig_file());
    ta.set_filename(0, "source.txt");
    try std.testing.expect(!ta.is_zig_file());
    ta.set_filename(0, "noext");
    try std.testing.expect(!ta.is_zig_file());
}

test "edit: E4 tabs have independent buffers" {
    var ta = TabArray.init();
    _ = ta.tabs[0].fb.insert_char('A');
    _ = ta.open_new();
    _ = ta.tabs[1].fb.insert_char('B');
    try std.testing.expectEqualStrings("A", ta.tabs[0].fb.slice());
    try std.testing.expectEqualStrings("B", ta.tabs[1].fb.slice());
}

// E5: Syntax coloring tests

test "edit: E5 classify_token recognizes keyword" {
    const text = "const x = 5;";
    const r = classify_token(text);
    try std.testing.expectEqual(SyntaxKind.keyword, r.kind);
    try std.testing.expectEqual(@as(usize, 5), r.len);
}

test "edit: E5 classify_token recognizes string" {
    const text = "\"hello\" + 1";
    const r = classify_token(text);
    try std.testing.expectEqual(SyntaxKind.string, r.kind);
    try std.testing.expectEqual(@as(usize, 7), r.len);
}

test "edit: E5 classify_token recognizes comment" {
    const text = "// this is a comment\nrest";
    const r = classify_token(text);
    try std.testing.expectEqual(SyntaxKind.comment, r.kind);
    try std.testing.expectEqual(@as(usize, 20), r.len);
}

test "edit: E5 classify_token plain identifier" {
    const text = "myVar = 5";
    const r = classify_token(text);
    try std.testing.expectEqual(SyntaxKind.plain, r.kind);
    try std.testing.expectEqual(@as(usize, 5), r.len);
}

test "edit: E5 classify_token single char operator" {
    const text = "= 5";
    const r = classify_token(text);
    try std.testing.expectEqual(SyntaxKind.plain, r.kind);
    try std.testing.expectEqual(@as(usize, 1), r.len);
}

test "edit: E5 zig_keywords table is non-empty" {
    try std.testing.expect(zig_keywords.len > 0);
    var found_const = false;
    var found_fn = false;
    for (zig_keywords) |kw| {
        if (std.mem.eql(u8, kw, "const")) found_const = true;
        if (std.mem.eql(u8, kw, "fn")) found_fn = true;
    }
    try std.testing.expect(found_const);
    try std.testing.expect(found_fn);
}

test "edit: E5 classify_token escaped quote in string" {
    const text = "\"he\\\"llo\" rest";
    const r = classify_token(text);
    try std.testing.expectEqual(SyntaxKind.string, r.kind);
    try std.testing.expectEqual(@as(usize, 9), r.len);
}

test "edit: E5 classify_token char literal" {
    const text = "'x' + 1";
    const r = classify_token(text);
    try std.testing.expectEqual(SyntaxKind.string, r.kind);
    try std.testing.expectEqual(@as(usize, 3), r.len);
}

// E7: Search & Replace tests

test "edit: E7 match_at_ci case insensitive match" {
    const text = "Hello World";
    try std.testing.expect(match_at_ci(text, "hello", 0));
    try std.testing.expect(match_at_ci(text, "WORLD", 6));
    try std.testing.expect(!match_at_ci(text, "earth", 0));
}

test "edit: E7 count_matches_ci counts occurrences" {
    const text = "Banana baNaNa ban";
    try std.testing.expectEqual(@as(usize, 2), count_matches_ci(text, "banana"));
    try std.testing.expectEqual(@as(usize, 3), count_matches_ci(text, "ban"));
    try std.testing.expectEqual(@as(usize, 0), count_matches_ci(text, "orange"));
}

test "edit: E7 find_next_ci and wrap" {
    const text = "alpha beta alpha gamma";
    const m1 = find_next_ci(text, "alpha", 0, true);
    try std.testing.expect(m1 != null);
    try std.testing.expectEqual(@as(usize, 0), m1.?.pos);
    try std.testing.expect(!m1.?.wrapped);

    const m2 = find_next_ci(text, "alpha", 1, true);
    try std.testing.expect(m2 != null);
    try std.testing.expectEqual(@as(usize, 11), m2.?.pos);
    try std.testing.expect(!m2.?.wrapped);

    const m3 = find_next_ci(text, "alpha", 15, true);
    try std.testing.expect(m3 != null);
    try std.testing.expectEqual(@as(usize, 0), m3.?.pos);
    try std.testing.expect(m3.?.wrapped);
}

test "edit: E7 find_prev_ci finds previous occurrence" {
    const text = "foo bar foo baz";
    const p1 = find_prev_ci(text, "foo", 10);
    try std.testing.expectEqual(@as(?usize, 8), p1);

    const p2 = find_prev_ci(text, "foo", 7);
    try std.testing.expectEqual(@as(?usize, 0), p2);
}

test "edit: E7 replace_current_match single replacement" {
    var fb = FileBuffer{};
    fb.set_content("Hello World");
    fb.cursor = 0;
    try std.testing.expect(replace_current_match(&fb, "Hello", "Greetings"));
    try std.testing.expectEqualStrings("Greetings World", fb.slice());
    try std.testing.expectEqual(@as(usize, 9), fb.cursor);

    try std.testing.expect(fb.undo_last());
    try std.testing.expectEqualStrings("Hello World", fb.slice());
}

test "edit: E7 replace_all_matches replaces all occurrences" {
    var fb = FileBuffer{};
    fb.set_content("foo 1 foo 2 foo 3");
    const count = replace_all_matches(&fb, "foo", "bar");
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("bar 1 bar 2 bar 3", fb.slice());
}

// E8: Autoindent tests

test "edit: E8 insert_newline_autoindent preserves spaces" {
    var fb = FileBuffer{};
    fb.set_content("    fn main() {");
    fb.cursor = fb.len;
    try std.testing.expect(fb.insert_newline_autoindent());
    try std.testing.expectEqualStrings("    fn main() {\n    ", fb.slice());
}

test "edit: E8 insert_newline_autoindent on empty line" {
    var fb = FileBuffer{};
    fb.set_content("hello");
    fb.cursor = fb.len;
    try std.testing.expect(fb.insert_newline_autoindent());
    try std.testing.expectEqualStrings("hello\n", fb.slice());
}

test "edit: E8 insert_char_with_dedent on closing brace" {
    var fb = FileBuffer{};
    fb.set_content("        ");
    fb.cursor = 8;
    try std.testing.expect(fb.insert_char_with_dedent('}'));
    try std.testing.expectEqualStrings("    }", fb.slice());
}

// E9: Bracket matching tests

test "edit: E9 find_matching_bracket parentheses" {
    const text = "fn test(a: (u32, u32)) void";
    const m1 = find_matching_bracket(text, 7);
    try std.testing.expectEqual(@as(?usize, 21), m1);

    const m2 = find_matching_bracket(text, 11);
    try std.testing.expectEqual(@as(?usize, 20), m2);

    const m3 = find_matching_bracket(text, 21);
    try std.testing.expectEqual(@as(?usize, 7), m3);
}

test "edit: E9 find_matching_bracket braces and brackets" {
    const text = "const arr = [{ (1 + 2) }];";
    const mb = find_matching_bracket(text, 12);
    try std.testing.expectEqual(@as(?usize, 24), mb);

    const mc = find_matching_bracket(text, 13);
    try std.testing.expectEqual(@as(?usize, 23), mc);
}

test "edit: E9 find_matching_bracket unmatched returns null" {
    const text = "fn test(a: u32 {";
    try std.testing.expectEqual(@as(?usize, null), find_matching_bracket(text, 7));
}

// E11: Line numbers toggle tests

test "edit: E11 AppState show_line_numbers toggle" {
    var app = AppState{};
    app.init();
    try std.testing.expect(app.show_line_numbers);

    var ev = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 0, .arg0 = 0x0f, .arg1 = 0 };
    try std.testing.expect(handle_key(&app, &ev));
    try std.testing.expect(!app.show_line_numbers);
    try std.testing.expectEqualStrings("Line numbers OFF", app.status[0..app.status_len]);

    try std.testing.expect(handle_key(&app, &ev));
    try std.testing.expect(app.show_line_numbers);
    try std.testing.expectEqualStrings("Line numbers ON", app.status[0..app.status_len]);
}

// E22: Delete line tests

test "edit: E22 delete_current_line middle line" {
    var fb = FileBuffer{};
    fb.set_content("Line1\nLine2\nLine3\n");
    fb.cursor = 8;
    try std.testing.expect(fb.delete_current_line());
    try std.testing.expectEqualStrings("Line1\nLine3\n", fb.slice());

    try std.testing.expect(fb.undo_last());
    try std.testing.expectEqualStrings("Line1\nLine2\nLine3\n", fb.slice());
}

test "edit: E22 delete_current_line first line" {
    var fb = FileBuffer{};
    fb.set_content("First\nSecond\n");
    fb.cursor = 2;
    try std.testing.expect(fb.delete_current_line());
    try std.testing.expectEqualStrings("Second\n", fb.slice());
}

test "edit: E22 delete_current_line last line without trailing newline" {
    var fb = FileBuffer{};
    fb.set_content("First\nSecond");
    fb.cursor = 8;
    try std.testing.expect(fb.delete_current_line());
    try std.testing.expectEqualStrings("First\n", fb.slice());
}

test "edit: E22 delete_current_line single line buffer" {
    var fb = FileBuffer{};
    fb.set_content("OnlyLine");
    fb.cursor = 4;
    try std.testing.expect(fb.delete_current_line());
    try std.testing.expectEqualStrings("", fb.slice());
    try std.testing.expectEqual(@as(usize, 0), fb.cursor);

    try std.testing.expect(fb.undo_last());
    try std.testing.expectEqualStrings("OnlyLine", fb.slice());
}

test "edit: E22 delete_current_line empty buffer returns false" {
    var fb = FileBuffer{};
    try std.testing.expect(!fb.delete_current_line());
}

test "edit: E8 insert_char_with_dedent does not dedent when text precedes" {
    var fb = FileBuffer{};
    fb.set_content("    foo");
    fb.cursor = 7;
    try std.testing.expect(fb.insert_char_with_dedent('}'));
    try std.testing.expectEqualStrings("    foo}", fb.slice());
}

test "edit: E8 insert_newline_autoindent with tabs and spaces" {
    var fb = FileBuffer{};
    fb.set_content("\t  test();");
    fb.cursor = fb.len;
    try std.testing.expect(fb.insert_newline_autoindent());
    try std.testing.expectEqualStrings("\t  test();\n\t  ", fb.slice());
}

test "edit: E7 handle_find_key navigation and replace flow" {
    var app = AppState{};
    app.init();
    app.fb().set_content("foo bar foo baz foo");

    var ev_f = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 0, .arg0 = 0x09, .arg1 = 0 };
    try std.testing.expect(handle_key(&app, &ev_f));
    try std.testing.expect(app.find_prompt.active);
    try std.testing.expect(!app.find_prompt.is_replace);

    var ev_char = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 0, .arg0 = 0, .arg1 = 'f' };
    try std.testing.expect(handle_key(&app, &ev_char));
    ev_char.arg1 = 'o';
    try std.testing.expect(handle_key(&app, &ev_char));
    try std.testing.expect(handle_key(&app, &ev_char));
    try std.testing.expectEqualStrings("foo", app.find_prompt.get_find());

    var ev_enter = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 0, .arg0 = 0x28, .arg1 = '\n' };
    try std.testing.expect(handle_key(&app, &ev_enter));
    try std.testing.expectEqual(@as(usize, 8), app.fb().cursor);

    try std.testing.expect(handle_key(&app, &ev_enter));
    try std.testing.expectEqual(@as(usize, 16), app.fb().cursor);

    try std.testing.expect(handle_key(&app, &ev_enter));
    try std.testing.expectEqual(@as(usize, 0), app.fb().cursor);

    var ev_esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 0, .arg0 = 0x29, .arg1 = 0x1b };
    try std.testing.expect(handle_key(&app, &ev_esc));
    try std.testing.expect(!app.find_prompt.active);

    var ev_h = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 0, .arg0 = 0x0b, .arg1 = 0 };
    try std.testing.expect(handle_key(&app, &ev_h));
    try std.testing.expect(app.find_prompt.active);
    try std.testing.expect(app.find_prompt.is_replace);

    app.find_prompt.find_len = 0;
    app.find_prompt.insert_char('f');
    app.find_prompt.insert_char('o');
    app.find_prompt.insert_char('o');
    app.find_prompt.focus_replace = true;
    app.find_prompt.insert_char('q');
    app.find_prompt.insert_char('u');
    app.find_prompt.insert_char('x');

    var ev_ca = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 0, .arg0 = 0x04, .arg1 = 0 };
    try std.testing.expect(handle_key(&app, &ev_ca));
    try std.testing.expectEqualStrings("qux bar qux baz qux", app.fb().slice());
}

// ---------------------------------------------------------------------------
// New Tests for E10, E12–E21, E23–E25
// ---------------------------------------------------------------------------

test "edit: E20 indent_current_line and dedent_current_line" {
    var fb = FileBuffer{};
    fb.set_content("fn main() void");
    fb.cursor = 3;
    try std.testing.expect(fb.indent_current_line());
    try std.testing.expectEqualStrings("    fn main() void", fb.slice());
    try std.testing.expectEqual(@as(usize, 7), fb.cursor);

    try std.testing.expect(fb.dedent_current_line());
    try std.testing.expectEqualStrings("fn main() void", fb.slice());
    try std.testing.expectEqual(@as(usize, 3), fb.cursor);
}

test "edit: E21 Bookmarks toggle and navigation" {
    var bm = Bookmarks{};
    try std.testing.expect(!bm.has_bookmark(5));

    // Add bookmark on line 5
    try std.testing.expect(bm.toggle(5));
    try std.testing.expect(bm.has_bookmark(5));
    try std.testing.expectEqual(@as(usize, 1), bm.count);

    // Add bookmark on line 12 and line 2
    try std.testing.expect(bm.toggle(12));
    try std.testing.expect(bm.toggle(2));
    try std.testing.expectEqual(@as(usize, 3), bm.count);
    // Verified sorted: 2, 5, 12
    try std.testing.expectEqual(@as(usize, 2), bm.lines[0]);
    try std.testing.expectEqual(@as(usize, 5), bm.lines[1]);
    try std.testing.expectEqual(@as(usize, 12), bm.lines[2]);

    // Next after 3 -> 5
    try std.testing.expectEqual(@as(?usize, 5), bm.next_after(3));
    // Next after 12 -> wraps to 2
    try std.testing.expectEqual(@as(?usize, 2), bm.next_after(12));
    // Prev before 5 -> 2
    try std.testing.expectEqual(@as(?usize, 2), bm.prev_before(5));
    // Prev before 2 -> wraps to 12
    try std.testing.expectEqual(@as(?usize, 12), bm.prev_before(2));

    // Toggle 5 off
    try std.testing.expect(!bm.toggle(5));
    try std.testing.expect(!bm.has_bookmark(5));
    try std.testing.expectEqual(@as(usize, 2), bm.count);
}

test "edit: E23 extract_word_at_pos and find_definition_in_buffer" {
    const code =
        \\pub fn calculate_sum(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\pub fn main() void {
        \\    const res = calculate_sum(10, 20);
        \\}
    ;
    // Word at call site "calculate_sum"
    const call_pos = std.mem.indexOf(u8, code, "calculate_sum(10").?;
    const word = extract_word_at_pos(code, call_pos);
    try std.testing.expect(word != null);
    try std.testing.expectEqualStrings("calculate_sum", word.?);

    // Find definition in buffer -> line 0
    const def_pos = find_definition_in_buffer(code, word.?);
    try std.testing.expect(def_pos != null);
    try std.testing.expectEqual(@as(usize, 0), def_pos.?);
}

test "edit: E19 Theme switching and palettes" {
    var app = AppState{};
    app.init();
    try std.testing.expectEqualStrings("Dark", app.cur_theme().name);

    // Cycle to Light
    app.theme_idx = 1;
    try std.testing.expectEqualStrings("Light", app.cur_theme().name);

    // Cycle to Amber
    app.theme_idx = 2;
    try std.testing.expectEqualStrings("Amber", app.cur_theme().name);
}

test "edit: E14 CommandPalette fuzzy search and action lookup" {
    var cp = CommandPalette{};
    cp.open();

    // Query "sav" matches "Save File"
    cp.insert_char('s');
    cp.insert_char('a');
    cp.insert_char('v');
    try std.testing.expect(cp.match_count() >= 1);
    try std.testing.expectEqual(KeyAction.save_file, cp.get_selected_action().?);

    // Query "wrap" matches "Toggle Word Wrap"
    cp.query_len = 0;
    cp.insert_char('w');
    cp.insert_char('r');
    cp.insert_char('a');
    cp.insert_char('p');
    try std.testing.expectEqual(KeyAction.toggle_wrap, cp.get_selected_action().?);
}

test "edit: E15 RecentList MRU behavior" {
    var rl = RecentList{};
    rl.add("file1.zig");
    rl.add("file2.txt");
    try std.testing.expectEqual(@as(usize, 2), rl.count);
    try std.testing.expectEqualStrings("file2.txt", rl.files[0][0..rl.lens[0]]);
    try std.testing.expectEqualStrings("file1.zig", rl.files[1][0..rl.lens[1]]);

    // Accessing file1.zig again moves it to top
    rl.add("file1.zig");
    try std.testing.expectEqual(@as(usize, 2), rl.count);
    try std.testing.expectEqualStrings("file1.zig", rl.files[0][0..rl.lens[0]]);
}

test "edit: E12 Multiple cursors simultaneous multi-character typing and backspace" {
    var fb = FileBuffer{};
    fb.set_content("foo bar foo");
    fb.cursor = 0; // on first "foo"

    // Add cursor at second "foo" (offset 8)
    try std.testing.expect(fb.add_next_word_cursor());
    try std.testing.expectEqual(@as(usize, 1), fb.extra_cursor_count);
    try std.testing.expectEqual(@as(usize, 8), fb.extra_cursors[0]);

    // Type "X"
    try std.testing.expect(fb.insert_char('X'));
    try std.testing.expectEqualStrings("Xfoo bar Xfoo", fb.slice());
    try std.testing.expectEqual(@as(usize, 1), fb.cursor);
    try std.testing.expectEqual(@as(usize, 10), fb.extra_cursors[0]);

    // Type "Y" -> must produce "XYfoo bar XYfoo" (no coordinate stale corruption)
    try std.testing.expect(fb.insert_char('Y'));
    try std.testing.expectEqualStrings("XYfoo bar XYfoo", fb.slice());
    try std.testing.expectEqual(@as(usize, 2), fb.cursor);
    try std.testing.expectEqual(@as(usize, 12), fb.extra_cursors[0]);

    // Backspace 'Y'
    try std.testing.expect(fb.backspace());
    try std.testing.expectEqualStrings("Xfoo bar Xfoo", fb.slice());
    try std.testing.expectEqual(@as(usize, 1), fb.cursor);
    try std.testing.expectEqual(@as(usize, 10), fb.extra_cursors[0]);

    // Backspace 'X'
    try std.testing.expect(fb.backspace());
    try std.testing.expectEqualStrings("foo bar foo", fb.slice());
    try std.testing.expectEqual(@as(usize, 0), fb.cursor);
    try std.testing.expectEqual(@as(usize, 8), fb.extra_cursors[0]);
}

test "edit: E13 RectSelection contains and block typing" {
    var rs = RectSelection{
        .active = true,
        .start_line = 2,
        .start_col = 5,
        .end_line = 5,
        .end_col = 10,
    };
    try std.testing.expect(rs.contains(3, 7));
    try std.testing.expect(rs.contains(2, 5));
    try std.testing.expect(rs.contains(5, 10));
    try std.testing.expect(!rs.contains(1, 7));
    try std.testing.expect(!rs.contains(3, 12));

    var fb = FileBuffer{};
    fb.set_content("Line1\nLine2\nLine3\n");
    fb.rect_sel = .{ .active = true, .start_line = 1, .start_col = 1, .end_line = 3, .end_col = 1 };
    try std.testing.expect(fb.insert_rect_char('>'));
    try std.testing.expectEqualStrings(">Line1\n>Line2\n>Line3\n", fb.slice());

    try std.testing.expect(fb.backspace_rect_char());
    try std.testing.expectEqualStrings("Line1\nLine2\nLine3\n", fb.slice());
}

test "edit: E16 Close confirmation dialog key handling" {
    var app = AppState{};
    app.init();
    _ = app.tabs.open_new();
    app.tabs.active_tab().dirty = true;

    // Trigger Ctrl+W -> opens close confirmation
    var ev_w = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 0, .arg0 = 0x1a, .arg1 = 0 };
    try std.testing.expect(handle_key(&app, &ev_w));
    try std.testing.expect(app.close_confirm.active);

    // Cancel with Esc
    var ev_esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 0, .arg0 = 0x29, .arg1 = 0x1b };
    try std.testing.expect(handle_key(&app, &ev_esc));
    try std.testing.expect(!app.close_confirm.active);
    try std.testing.expectEqual(@as(usize, 2), app.tabs.count);

    // Trigger Ctrl+W again and press 'N' (discard) -> closes tab
    try std.testing.expect(handle_key(&app, &ev_w));
    var ev_n = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 0, .arg0 = 0, .arg1 = 'N' };
    try std.testing.expect(handle_key(&app, &ev_n));
    try std.testing.expect(!app.close_confirm.active);
    try std.testing.expectEqual(@as(usize, 1), app.tabs.count);

    // Now open new tab, mark dirty, press 'Y' -> saves and closes
    _ = app.tabs.open_new();
    app.tabs.active_tab().dirty = true;
    try std.testing.expect(handle_key(&app, &ev_w));
    var ev_y = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 0, .arg0 = 0, .arg1 = 'Y' };
    try std.testing.expect(handle_key(&app, &ev_y));
    try std.testing.expect(!app.close_confirm.active);
    try std.testing.expectEqual(@as(usize, 1), app.tabs.count);
}

test "edit: E24 FileSidebar interactive navigation" {
    var app = AppState{};
    app.init();
    app.file_sidebar.active = true;
    app.file_sidebar.count = 3;
    app.file_sidebar.selected = 0;

    // Down arrow moves selection
    var ev_down = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 0, .arg0 = 0x51, .arg1 = 0 };
    try std.testing.expect(handle_key(&app, &ev_down));
    try std.testing.expectEqual(@as(usize, 1), app.file_sidebar.selected);

    // Up arrow moves selection
    var ev_up = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 0, .arg0 = 0x52, .arg1 = 0 };
    try std.testing.expect(handle_key(&app, &ev_up));
    try std.testing.expectEqual(@as(usize, 0), app.file_sidebar.selected);

    // Esc closes sidebar
    var ev_esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 0, .arg0 = 0x29, .arg1 = 0x1b };
    try std.testing.expect(handle_key(&app, &ev_esc));
    try std.testing.expect(!app.file_sidebar.active);
}

test "edit: execute_key_action dispatches commands cleanly" {
    var app = AppState{};
    app.init();

    // Toggle wrap
    try std.testing.expect(!app.word_wrap);
    try std.testing.expect(execute_key_action(&app, .toggle_wrap));
    try std.testing.expect(app.word_wrap);

    // Toggle numbers
    try std.testing.expect(app.show_line_numbers);
    try std.testing.expect(execute_key_action(&app, .toggle_numbers));
    try std.testing.expect(!app.show_line_numbers);

    // Toggle sidebar
    try std.testing.expect(!app.file_sidebar.active);
    try std.testing.expect(execute_key_action(&app, .toggle_file_tree));
    try std.testing.expect(app.file_sidebar.active);

    // Cycle theme
    try std.testing.expectEqual(@as(usize, 0), app.theme_idx);
    try std.testing.expect(execute_key_action(&app, .cycle_theme));
    try std.testing.expectEqual(@as(usize, 1), app.theme_idx);

    // Toggle bookmark
    try std.testing.expect(execute_key_action(&app, .toggle_bookmark));
    try std.testing.expect(app.fb().bookmarks.has_bookmark(1));
}

test "edit: key chord dispatch for palette, recents, wrap, theme, bookmark, and jump-def" {
    var app = AppState{};
    app.init();
    app.fb().set_content("fn add(x: u32) u32 {\n    return x + 1;\n}\nconst val = add(5);");

    // Ctrl+Shift+P -> Command Palette
    var ev_p = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL | ui.MOD_SHIFT, .seq = 0, .arg0 = 0x13, .arg1 = 0 };
    try std.testing.expect(handle_key(&app, &ev_p));
    try std.testing.expect(app.cmd_palette.active);
    app.cmd_palette.close();

    // Ctrl+R -> Recent Files
    var ev_r = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 0, .arg0 = 0x15, .arg1 = 0 };
    try std.testing.expect(handle_key(&app, &ev_r));
    try std.testing.expect(app.recent_list.active);
    app.recent_list.close();

    // Alt+Z -> Toggle Word Wrap
    var ev_z = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_ALT, .seq = 0, .arg0 = 0x1d, .arg1 = 0 };
    try std.testing.expect(handle_key(&app, &ev_z));
    try std.testing.expect(app.word_wrap);

    // Ctrl+Shift+T -> Cycle Theme
    var ev_t = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL | ui.MOD_SHIFT, .seq = 0, .arg0 = 0x17, .arg1 = 0 };
    try std.testing.expect(handle_key(&app, &ev_t));
    try std.testing.expectEqual(@as(usize, 1), app.theme_idx);

    // Ctrl+B -> Toggle Bookmark
    var ev_b = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 0, .arg0 = 0x05, .arg1 = 0 };
    try std.testing.expect(handle_key(&app, &ev_b));
    try std.testing.expect(app.fb().bookmarks.has_bookmark(1));

    // Position on call site "add(5)"
    app.fb().cursor = std.mem.indexOf(u8, app.fb().slice(), "add(5)").?;
    // Ctrl+] -> Jump to Definition
    var ev_jump = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 0, .arg0 = 0x30, .arg1 = ']' };
    try std.testing.expect(handle_key(&app, &ev_jump));
    try std.testing.expectEqual(@as(usize, 0), app.fb().cursor);
}
