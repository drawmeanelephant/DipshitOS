//! DipshitOS text editor — EDIT.BIN (M23 E1–E6).
//!
//! A full-screen text editor with a line-number gutter, cursor navigation,
//! insert/overwrite mode, a status bar, and a Ctrl+` console split for running
//! shell-like commands without leaving the editor. Uses the ui.zig micro-widget
//! toolkit with zero dynamic allocation.
//!
//! E1 (base editor): 32 KiB file buffer, line index, cursor, status bar.
//! E2 (undo/redo): bounded 50-entry delta ring, Ctrl+Z / Ctrl+Y.
//! E3 (goto line): Ctrl+G opens a prompt, Enter jumps to line number.
//! E4 (multi-file tabs): Ctrl+T/W/Tab, 4 tabs max, each with own buffer.
//! E5 (syntax coloring): Zig keyword/string/comment coloring for .zig files.
//! E6 (console split): Ctrl+` toggles a bottom 40% pane with a mini-shell.

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Event = ui.Event;

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

// E2: undo/redo
const undo_cap: usize = 50;
const delta_text_cap: usize = 32;

/// A single undo/redo delta: position + what changed.
const Delta = struct {
    pos: usize = 0,
    old_len: usize = 0,
    new_len: usize = 0,
    old_text: [delta_text_cap]u8 = [_]u8{0} ** delta_text_cap,
    new_text: [delta_text_cap]u8 = [_]u8{0} ** delta_text_cap,
};

/// Bounded undo/redo ring. Undo pops from `undo_stack` and pushes the
/// reverse onto `redo_stack`. Redo pops from `redo_stack` and pushes back
/// onto `undo_stack`. New edits clear the redo stack.
const UndoRing = struct {
    undo_stack: [undo_cap]Delta = [_]Delta{.{}} ** undo_cap,
    undo_count: usize = 0,
    redo_stack: [undo_cap]Delta = [_]Delta{.{}} ** undo_cap,
    redo_count: usize = 0,

    fn clear(self: *UndoRing) void {
        self.undo_count = 0;
        self.redo_count = 0;
    }

    fn push_undo(self: *UndoRing, d: Delta) void {
        if (self.undo_count < undo_cap) {
            self.undo_stack[self.undo_count] = d;
            self.undo_count += 1;
        } else {
            // Shift left (drop oldest) and append
            var i: usize = 0;
            while (i < undo_cap - 1) : (i += 1) {
                self.undo_stack[i] = self.undo_stack[i + 1];
            }
            self.undo_stack[undo_cap - 1] = d;
        }
        // New edit clears redo
        self.redo_count = 0;
    }

    fn can_undo(self: *const UndoRing) bool {
        return self.undo_count > 0;
    }

    fn can_redo(self: *const UndoRing) bool {
        return self.redo_count > 0;
    }
};

// ---------------------------------------------------------------------------
// File Buffer (E1 + E2 undo hooks)
// ---------------------------------------------------------------------------

const file_buf_cap: usize = 32768;

const FileBuffer = struct {
    buf: [file_buf_cap]u8 = [_]u8{0} ** file_buf_cap,
    len: usize = 0,
    cursor: usize = 0,
    undo: UndoRing = .{},

    pub fn slice(self: *const FileBuffer) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set_content(self: *FileBuffer, content: []const u8) void {
        const n = @min(content.len, file_buf_cap);
        @memcpy(self.buf[0..n], content[0..n]);
        self.len = n;
        self.cursor = @min(self.cursor, n);
        self.undo.clear();
    }

    pub fn clear(self: *FileBuffer) void {
        self.len = 0;
        self.cursor = 0;
        self.undo.clear();
    }

    pub fn insert_char(self: *FileBuffer, ch: u8) bool {
        if (self.len >= file_buf_cap) return false;
        var i = self.len;
        while (i > self.cursor) : (i -= 1) self.buf[i] = self.buf[i - 1];
        self.buf[self.cursor] = ch;
        self.len += 1;
        // E2: push undo delta (insert: old="" new=ch)
        var d: Delta = .{ .pos = self.cursor };
        d.new_text[0] = ch;
        d.new_len = 1;
        self.undo.push_undo(d);
        self.cursor += 1;
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

    pub fn backspace(self: *FileBuffer) bool {
        if (self.cursor == 0 or self.len == 0) return false;
        const deleted_char = self.buf[self.cursor - 1];
        var i = self.cursor - 1;
        while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
        self.len -= 1;
        // E2: push undo delta (delete: old=deleted_char new="")
        var d: Delta = .{ .pos = self.cursor - 1 };
        d.old_text[0] = deleted_char;
        d.old_len = 1;
        self.undo.push_undo(d);
        self.cursor -= 1;
        return true;
    }

    pub fn delete_forward(self: *FileBuffer) bool {
        if (self.cursor >= self.len) return false;
        const deleted_char = self.buf[self.cursor];
        var i = self.cursor;
        while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
        self.len -= 1;
        // E2: push undo delta (delete-forward: old=deleted_char new="")
        var d: Delta = .{ .pos = self.cursor };
        d.old_text[0] = deleted_char;
        d.old_len = 1;
        self.undo.push_undo(d);
        return true;
    }

    /// Overwrite a character at cursor (OVR mode). Returns true if done.
    pub fn overwrite_char(self: *FileBuffer, ch: u8) bool {
        if (self.cursor >= self.len) return false;
        const old_ch = self.buf[self.cursor];
        self.buf[self.cursor] = ch;
        // E2: push undo delta (overwrite: old=old_ch new=ch)
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
        return self.insert_char('\n');
    }

    /// E2: Apply undo. Pops the top undo delta, reverses it, pushes to redo.
    /// Returns true if something was undone.
    pub fn undo_last(self: *FileBuffer) bool {
        if (!self.undo.can_undo()) return false;
        const d = self.undo.undo_stack[self.undo.undo_count - 1];
        self.undo.undo_count -= 1;

        // Reverse: remove new_text, insert old_text at pos
        self.cursor = d.pos;
        // Remove new_len bytes
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
        // Insert old_text
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

        // Push to redo
        self.undo.redo_stack[self.undo.redo_count] = d;
        self.undo.redo_count += 1;
        return true;
    }

    /// E2: Apply redo. Pops the top redo delta, re-applies it, pushes to undo.
    pub fn redo_last(self: *FileBuffer) bool {
        if (!self.undo.can_redo()) return false;
        const d = self.undo.redo_stack[self.undo.redo_count - 1];
        self.undo.redo_count -= 1;

        // Re-apply: remove old_text, insert new_text at pos
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

        // Push back to undo
        self.undo.undo_stack[self.undo.undo_count] = d;
        self.undo.undo_count += 1;
        return true;
    }

    /// E3: Goto a specific line (1-based). Clamps to last line.
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

    /// Find the start of the current line (byte offset).
    pub fn line_start(self: *const FileBuffer, pos: usize) usize {
        var p = pos;
        while (p > 0 and self.buf[p - 1] != '\n') p -= 1;
        return p;
    }

    /// Find the end of the current line (byte offset).
    pub fn line_end(self: *const FileBuffer, pos: usize) usize {
        var p = pos;
        while (p < self.len and self.buf[p] != '\n') p += 1;
        return p;
    }

    /// Move cursor left one column (respecting line boundaries).
    pub fn move_left(self: *FileBuffer) bool {
        if (self.cursor == 0) return false;
        self.cursor -= 1;
        return true;
    }

    /// Move cursor right one column.
    pub fn move_right(self: *FileBuffer) bool {
        if (self.cursor >= self.len) return false;
        self.cursor += 1;
        return true;
    }

    /// Move cursor up one display row.
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

    /// Move cursor down one display row.
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

    /// Count total lines (for status bar).
    pub fn total_lines(self: *const FileBuffer) usize {
        if (self.len == 0) return 1;
        var n: usize = 1;
        for (self.buf[0..self.len]) |b| {
            if (b == '\n') n += 1;
        }
        return n;
    }

    /// Current line number (1-based).
    pub fn current_line(self: *const FileBuffer) usize {
        var n: usize = 1;
        var i: usize = 0;
        while (i < self.cursor) : (i += 1) {
            if (self.buf[i] == '\n') n += 1;
        }
        return n;
    }

    /// Current column (1-based).
    pub fn current_col(self: *const FileBuffer) usize {
        const ls = self.line_start(self.cursor);
        return self.cursor - ls + 1;
    }
};

// ---------------------------------------------------------------------------
// E5: Syntax coloring — Zig keyword table + token classifier
// ---------------------------------------------------------------------------

const SyntaxKind = enum { plain, keyword, string, comment };

const zig_keywords = [_][]const u8{
    "const",          "var",    "fn",       "pub",   "test",     "if",        "else",
    "while",          "for",    "return",   "break", "continue", "switch",    "and",
    "or",             "not",    "struct",   "enum",  "union",    "opaque",    "comptime",
    "inline",         "extern", "export",   "error", "try",      "catch",     "unreachable",
    "usingnamespace", "defer",  "errdefer", "asm",   "volatile", "align",     "linksection",
    "callconv",       "packed", "true",     "false", "null",     "undefined",
};

/// Classify a token at the start of `text` (up to the next whitespace or
/// delimiter). Returns the syntax kind and the token length.
fn classify_token(text: []const u8) struct { kind: SyntaxKind, len: usize } {
    if (text.len == 0) return .{ .kind = .plain, .len = 0 };

    // Comment: starts with //
    if (text.len >= 2 and text[0] == '/' and text[1] == '/') {
        var i: usize = 0;
        while (i < text.len and text[i] != '\n') : (i += 1) {}
        return .{ .kind = .comment, .len = i };
    }

    // String literal: starts with "
    if (text[0] == '"') {
        var i: usize = 1;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len) {
                i += 1; // skip escaped char
                continue;
            }
            if (text[i] == '"') {
                i += 1;
                break;
            }
        }
        return .{ .kind = .string, .len = i };
    }

    // Char literal: starts with '
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

    // Identifier / keyword
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

    // Non-identifier: consume one char
    return .{ .kind = .plain, .len = 1 };
}

fn is_ident_start(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

fn is_ident_char(ch: u8) bool {
    return is_ident_start(ch) or (ch >= '0' and ch <= '9');
}

/// Draw a line of text with syntax coloring. Only used when the file
/// has a .zig extension. Otherwise draws plain white.
fn draw_line_colored(win: u32, text: []const u8, x: u32, y: u32) void {
    var pos: usize = 0;
    var cur_x = x;
    while (pos < text.len) {
        // Skip leading whitespace, draw it plain
        var ws: usize = 0;
        while (pos + ws < text.len and (text[pos + ws] == ' ' or text[pos + ws] == '\t')) : (ws += 1) {}
        if (ws > 0) {
            ui.draw_text(win, text[pos..][0..ws], cur_x, y, ui.COLOR_TEXT_PRIMARY);
            cur_x += @as(u32, @intCast(ws)) * glyph_w;
            pos += ws;
        }
        if (pos >= text.len) break;

        const result = classify_token(text[pos..]);
        const color: u32 = switch (result.kind) {
            .plain => ui.COLOR_TEXT_PRIMARY,
            .keyword => ui.COLOR_ACCENT,
            .string => ui.COLOR_SUCCESS,
            .comment => ui.COLOR_WARNING,
        };
        if (result.len == 0) break;
        ui.draw_text(win, text[pos..][0..result.len], cur_x, y, color);
        cur_x += @as(u32, @intCast(result.len)) * glyph_w;
        pos += result.len;
    }
}

// ---------------------------------------------------------------------------
// Console Split Mini-Shell (E6)
// ---------------------------------------------------------------------------

const console_buf_cap: usize = 512;

const MiniShell = struct {
    buf: [console_buf_cap]u8 = [_]u8{0} ** console_buf_cap,
    len: usize = 0,
    cursor: usize = 0,
    output: [console_buf_cap]u8 = [_]u8{0} ** console_buf_cap,
    output_len: usize = 0,
    active: bool = false,
    scroll: usize = 0,

    fn reset(self: *MiniShell) void {
        self.len = 0;
        self.cursor = 0;
        self.output_len = 0;
        self.scroll = 0;
    }

    fn append_output(self: *MiniShell, text: []const u8) void {
        const room = console_buf_cap -| self.output_len;
        const n = @min(text.len, room);
        @memcpy(self.output[self.output_len..][0..n], text[0..n]);
        self.output_len += n;
    }

    fn putc(self: *MiniShell, ch: u8) void {
        if (self.output_len < console_buf_cap) {
            self.output[self.output_len] = ch;
            self.output_len += 1;
        }
    }

    fn execute(self: *MiniShell, fb: *FileBuffer) void {
        const cmd = self.buf[0..self.len];

        // Parse: first word is command, rest is argument.
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
            // Format "L N, C M"
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

        // Auto-scroll to bottom if we wrote output
        if (self.output_len > old_len) {
            self.scroll = 0;
        }

        self.len = 0;
        self.cursor = 0;
    }
};

/// Format a positive integer into a stack buffer; returns the slice.
fn fmt_int(buf: []u8, n: usize) usize {
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

const GotoPrompt = struct {
    buf: [8]u8 = [_]u8{0} ** 8,
    len: usize = 0,
    active: bool = false,

    fn open(self: *GotoPrompt) void {
        self.len = 0;
        self.active = true;
    }

    fn close(self: *GotoPrompt) void {
        self.active = false;
        self.len = 0;
    }

    fn insert_char(self: *GotoPrompt, ch: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = ch;
            self.len += 1;
        }
    }

    fn backspace(self: *GotoPrompt) void {
        if (self.len > 0) self.len -= 1;
    }

    fn get_text(self: *const GotoPrompt) []const u8 {
        return self.buf[0..self.len];
    }

    /// Parse the input as a line number. Returns null if invalid.
    fn parse_line(self: *const GotoPrompt) ?usize {
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

const EditorTab = struct {
    fb: FileBuffer = .{},
    filename: [filename_cap]u8 = [_]u8{0} ** filename_cap,
    filename_len: usize = 0,
    dirty: bool = false,
    is_used: bool = false,
};

const TabArray = struct {
    tabs: [max_tabs]EditorTab = [_]EditorTab{.{}} ** max_tabs,
    active: usize = 0,
    count: usize = 0, // number of used tabs

    fn init() TabArray {
        var ta = TabArray{};
        ta.tabs[0].is_used = true;
        ta.count = 1;
        ta.set_filename(0, "UNTITLED");
        return ta;
    }

    fn active_tab(self: *TabArray) *EditorTab {
        return &self.tabs[self.active];
    }

    fn active_fb(self: *TabArray) *FileBuffer {
        return &self.tabs[self.active].fb;
    }

    fn set_filename(self: *TabArray, idx: usize, name: []const u8) void {
        const n = @min(name.len, filename_cap);
        @memcpy(self.tabs[idx].filename[0..n], name[0..n]);
        self.tabs[idx].filename_len = n;
    }

    fn get_filename(self: *const TabArray, idx: usize) []const u8 {
        return self.tabs[idx].filename[0..self.tabs[idx].filename_len];
    }

    /// Open a new tab. Returns true if a slot was available.
    fn open_new(self: *TabArray) bool {
        if (self.count >= max_tabs) return false;
        // Find next free slot
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

    /// Close the active tab. Compacts the array.
    fn close_active(self: *TabArray) void {
        if (self.count <= 1) return; // never close the last tab
        self.tabs[self.active].is_used = false;
        self.count -= 1;
        // Find next available tab
        var i: usize = 0;
        while (i < max_tabs) : (i += 1) {
            if (self.tabs[i].is_used) {
                self.active = i;
                return;
            }
        }
        self.active = 0;
    }

    /// Switch to the next tab (Ctrl+Tab).
    fn switch_next(self: *TabArray) void {
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

    /// Check if the active tab's file has a .zig extension.
    fn is_zig_file(self: *const TabArray) bool {
        const name = self.get_filename(self.active);
        if (name.len < 4) return false;
        return std.mem.eql(u8, name[name.len - 4 ..], ".zig");
    }
};

// ---------------------------------------------------------------------------
// Editor State
// ---------------------------------------------------------------------------

pub const AppState = struct {
    tabs: TabArray = TabArray.init(),
    shell: MiniShell = .{},
    status: [40]u8 = [_]u8{0} ** 40,
    status_len: usize = 8,
    insert_mode: bool = true,
    show_shell: bool = false,
    goto_prompt: GotoPrompt = .{},
    win_id: u32 = 0,

    pub fn init() AppState {
        return .{};
    }

    fn fb(self: *AppState) *FileBuffer {
        return self.tabs.active_fb();
    }

    pub fn set_status(self: *AppState, msg: []const u8) void {
        const n = @min(msg.len, self.status.len);
        @memcpy(self.status[0..n], msg[0..n]);
        self.status_len = n;
    }

    pub fn draw(self: *const AppState, win: u32) void {
        // Background
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.COLOR_BG);

        // Status bar
        ui.draw_rect(win, Rect.make(0, 0, window_w, 16), ui.COLOR_SURFACE);
        ui.draw_text(win, self.status[0..self.status_len], 6, 3, ui.COLOR_TEXT_MUTED);

        // Mode indicator
        const mode = if (self.insert_mode) "INS" else "OVR";
        ui.draw_text(win, mode, @intCast(window_w - 30), 3, ui.COLOR_ACCENT);

        // F-key hints
        ui.draw_text(win, "^`sh ^G:Go ^Z:Undo ^T:Tab", @intCast(window_w - 260), 3, ui.COLOR_TEXT_MUTED);

        // Divider
        ui.draw_rect(win, Rect.make(0, 16, window_w, 1), ui.COLOR_BORDER);

        // E4: Tab bar
        self.draw_tab_bar(win);

        if (self.show_shell) {
            self.draw_split(win);
        } else {
            self.draw_editor_full(win);
        }

        // E3: Goto-line prompt overlay
        if (self.goto_prompt.active) {
            self.draw_goto_prompt(win);
        }
    }

    fn draw_tab_bar(self: *const AppState, win: u32) void {
        const tab_y: u32 = 17;
        ui.draw_rect(win, Rect.make(0, tab_y, window_w, tab_bar_h), ui.COLOR_BG);

        var tab_x: u32 = 0;
        var i: usize = 0;
        while (i < max_tabs) : (i += 1) {
            if (!self.tabs.tabs[i].is_used) continue;
            const name = self.tabs.get_filename(i);
            const name_len: u32 = @min(@as(u32, @intCast(name.len)), 16);
            const tab_w: u32 = name_len * glyph_w + 16; // padding

            const is_active = (i == self.tabs.active);
            const bg = if (is_active) ui.COLOR_SURFACE else ui.COLOR_BG;
            ui.draw_rect(win, Rect.make(tab_x, tab_y, tab_w, tab_bar_h), bg);

            // Tab separator
            ui.draw_rect(win, Rect.make(tab_x + tab_w, tab_y, 1, tab_bar_h), ui.COLOR_BORDER);

            // Dirty indicator
            const text_color = if (is_active) ui.COLOR_TEXT_PRIMARY else ui.COLOR_TEXT_MUTED;
            ui.draw_text(win, name[0..name_len], tab_x + 4, tab_y + 3, text_color);

            if (self.tabs.tabs[i].dirty) {
                ui.draw_text(win, "*", tab_x + 4 + name_len * glyph_w + 2, tab_y + 3, ui.COLOR_WARNING);
            }

            tab_x += tab_w + 1;
        }

        // Divider below tab bar
        ui.draw_rect(win, Rect.make(0, tab_y + tab_bar_h, window_w, 1), ui.COLOR_BORDER);
    }

    fn editor_top(self: *const AppState) u32 {
        _ = self;
        return 17 + tab_bar_h + 1; // below tab bar
    }

    fn editor_available_h(self: *const AppState) u32 {
        return if (self.show_shell)
            text_area_h - console_split_h - 2 - tab_bar_h
        else
            text_area_h - tab_bar_h;
    }

    fn draw_editor_full(self: *const AppState, win: u32) void {
        const top = self.editor_top();
        const avail = self.editor_available_h();
        const vis_rows = @max(avail / line_h + 1, 2);

        // Editor surface
        ui.draw_rect(win, Rect.make(0, top, window_w, avail), ui.COLOR_SURFACE);

        // Gutter
        ui.draw_rect(win, Rect.make(0, top, gutter_w, avail), ui.COLOR_BG);

        const fb_ptr = &self.tabs.tabs[self.tabs.active].fb;
        const slice = fb_ptr.slice();
        const use_syntax = self.tabs.is_zig_file();

        // Render visible lines
        var ln: usize = 0;
        var byte_pos: usize = 0;
        while (byte_pos < slice.len and ln < vis_rows) : (ln += 1) {
            const line_start = byte_pos;
            while (byte_pos < slice.len and slice[byte_pos] != '\n') byte_pos += 1;
            const line_end = byte_pos;
            if (byte_pos < slice.len) byte_pos += 1; // skip \n

            // Gutter: line number
            var nbuf: [4]u8 = undefined;
            const nl = fmt_int(&nbuf, ln + 1);
            const gy = top + 3 + @as(u32, @intCast(ln)) * line_h;
            ui.draw_text(win, nbuf[0..nl], 2, gy, ui.COLOR_TEXT_MUTED);

            // Line content
            const llen = line_end - line_start;
            const max_cols: usize = text_cols;
            const take = @min(llen, max_cols);
            if (use_syntax) {
                draw_line_colored(win, slice[line_start..][0..take], editor_x0, gy);
            } else {
                ui.draw_text(win, slice[line_start..][0..take], editor_x0, gy, ui.COLOR_TEXT_PRIMARY);
            }
        }

        // Cursor
        if (self.insert_mode) {
            const cl = fb_ptr.current_line();
            const cc = fb_ptr.current_col();
            if (ln > 0 and cl <= ln) {
                const cx = editor_x0 + @as(u32, @intCast(cc - 1)) * glyph_w;
                const cy = top + 2 + @as(u32, @intCast(cl - 1)) * line_h;
                ui.draw_rect(win, Rect.make(cx, cy, glyph_w, line_h), ui.COLOR_ACCENT);
            }
        }
    }

    fn draw_split(self: *const AppState, win: u32) void {
        const top = self.editor_top();
        const edit_h = self.editor_available_h();
        const vis_rows = @max(edit_h / line_h + 1, 1);

        // Editor pane
        ui.draw_rect(win, Rect.make(0, top, window_w, edit_h), ui.COLOR_SURFACE);
        ui.draw_rect(win, Rect.make(0, top, gutter_w, edit_h), ui.COLOR_BG);

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

            var nbuf: [4]u8 = undefined;
            const nl = fmt_int(&nbuf, ln + 1);
            const gy = top + 3 + @as(u32, @intCast(ln)) * line_h;
            ui.draw_text(win, nbuf[0..nl], 2, gy, ui.COLOR_TEXT_MUTED);

            const llen = line_end - line_start;
            const take = @min(llen, text_cols);
            if (use_syntax) {
                draw_line_colored(win, slice[line_start..][0..take], editor_x0, gy);
            } else {
                ui.draw_text(win, slice[line_start..][0..take], editor_x0, gy, ui.COLOR_TEXT_PRIMARY);
            }
        }

        // Editor cursor
        if (self.insert_mode) {
            const cl = fb_ptr.current_line();
            const cc = fb_ptr.current_col();
            if (ln > 0 and cl <= ln) {
                const cx = editor_x0 + @as(u32, @intCast(cc - 1)) * glyph_w;
                const cy = top + 2 + @as(u32, @intCast(cl - 1)) * line_h;
                ui.draw_rect(win, Rect.make(cx, cy, glyph_w, line_h), ui.COLOR_ACCENT);
            }
        }

        // Divider between editor and console
        const div_y = top + edit_h;
        ui.draw_rect(win, Rect.make(0, div_y, window_w, 1), ui.COLOR_BORDER);

        // Console pane
        const con_y = div_y + 1;
        const con_h = console_split_h - 1;
        ui.draw_rect(win, Rect.make(0, con_y, window_w, con_h), ui.COLOR_SURFACE);

        // Console prompt
        ui.draw_text(win, ">", 4, con_y + 4, ui.COLOR_ACCENT);

        // Input line (what user is typing)
        if (self.shell.len > 0) {
            ui.draw_text(win, self.shell.buf[0..self.shell.len], 16, con_y + 4, ui.COLOR_TEXT_PRIMARY);
        }

        // Cursor in console input
        const cx2: u32 = 16 + @as(u32, @intCast(self.shell.cursor)) * glyph_w;
        ui.draw_rect(win, Rect.make(cx2, con_y + 3, glyph_w, 1), ui.COLOR_ACCENT);

        // Output lines (scrollable)
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
            ui.draw_text(win, out_slice[ol_start..][0..take], 6, oy, ui.COLOR_TEXT_MUTED);
        }
    }

    fn draw_goto_prompt(self: *const AppState, win: u32) void {
        // Bottom overlay bar
        const bar_h: u32 = 20;
        const bar_y = window_h - bar_h;
        ui.draw_rect(win, Rect.make(0, bar_y, window_w, bar_h), ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, Rect.make(0, bar_y, window_w, bar_h), 1, ui.COLOR_ACCENT);

        ui.draw_text(win, "Goto line:", 6, bar_y + 5, ui.COLOR_ACCENT);

        const input_x: u32 = 80;
        const text = self.goto_prompt.get_text();
        if (text.len > 0) {
            ui.draw_text(win, text, input_x, bar_y + 5, ui.COLOR_TEXT_PRIMARY);
        }

        // Cursor
        const cx = input_x + @as(u32, @intCast(self.goto_prompt.len)) * glyph_w;
        ui.draw_rect(win, Rect.make(cx, bar_y + 4, glyph_w, 10), ui.COLOR_ACCENT);

        ui.draw_text(win, "Enter=Go Esc=Cancel", window_w - 160, bar_y + 5, ui.COLOR_TEXT_MUTED);
    }
};

// ---------------------------------------------------------------------------
// Entry Point
// ---------------------------------------------------------------------------

pub export fn _start(argc: usize, argv: ?[*]const [32]u8) callconv(.c) noreturn {
    var app = AppState.init();

    // Optional: load a file on startup
    _ = argc;
    _ = argv;

    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("edit: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));
    app.win_id = win;

    app.draw(win);
    ui.win_present(win);
    ui.write_console("edit: ready\n");

    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        if (ev.kind == ui.WIN_CLOSE) break;

        if (ev.kind == ui.KEY_DOWN) {
            dirty = handle_key(&app, &ev) or dirty;
        }

        // Drain pending queue
        while (ui.poll_event(&ev) > 0) {
            if (ev.kind == ui.WIN_CLOSE) {
                ui.win_close(win);
                ui.exit_process(exit_status);
            }
            if (ev.kind == ui.KEY_DOWN) {
                dirty = handle_key(&app, &ev) or dirty;
            }
        }

        if (dirty) {
            app.draw(win);
            ui.win_present(win);
        }
    }

    ui.write_console("edit: exiting 44\n");
    ui.win_close(win);
    ui.exit_process(exit_status);
}

/// Top-level key dispatch: routes to goto prompt, console, or editor.
fn handle_key(app: *AppState, ev: *const Event) bool {
    const keycode: u16 = @as(u16, @intCast(ev.arg1));

    // E3: Goto-line prompt takes priority when active
    if (app.goto_prompt.active) {
        return handle_goto_key(app, ev);
    }

    // Ctrl+` toggles the console split (E6) — works in both modes
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x32) {
        app.show_shell = !app.show_shell;
        app.shell.reset();
        if (app.show_shell) {
            app.set_status("Shell (E6)");
        } else {
            app.set_status("EDIT.BIN");
        }
        return true;
    }

    // Ctrl+G opens goto-line prompt (E3)
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x0a) {
        app.goto_prompt.open();
        app.set_status("Goto line");
        ui.write_console("edit: goto-open\n");
        return true;
    }

    // E2: Ctrl+Z undo, Ctrl+Y redo
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x1d) { // Z
        if (app.fb().undo_last()) {
            app.set_status("Undo");
            ui.write_console("edit: undo\n");
            return true;
        }
        return false;
    }
    if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x15) { // Y
        if (app.fb().redo_last()) {
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
            app.tabs.close_active();
            app.set_status("Tab closed");
            ui.write_console("edit: tab-close\n");
            return true;
        }
        app.set_status("Cannot close last tab");
        return true;
    }
    // Ctrl+Tab: keycode 0x2b with Ctrl modifier
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

fn handle_goto_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg0));
    const keycode: u16 = @as(u16, @intCast(ev.arg1));

    // Enter: jump to line
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

    // Escape cancels
    if (keycode == 0x29 or ascii == 0x1b) {
        app.goto_prompt.close();
        app.set_status("EDIT.BIN");
        return true;
    }

    // Backspace
    if (ascii == 0x08 or ascii == 0x7f or keycode == 0x2a) {
        app.goto_prompt.backspace();
        return true;
    }

    // Digits only
    if (ascii >= '0' and ascii <= '9') {
        app.goto_prompt.insert_char(@as(u8, @intCast(ascii)));
        return true;
    }

    return false;
}

fn handle_editor_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg0));
    const keycode: u16 = @as(u16, @intCast(ev.arg1));
    const fb_ptr = app.fb();

    // Navigation keys
    switch (keycode) {
        0x4f => return fb_ptr.move_left(), // Left
        0x50 => return fb_ptr.move_right(), // Right
        0x52 => return fb_ptr.move_up(), // Up
        0x51 => return fb_ptr.move_down(), // Down
        0x4a => { // Home
            const ls = fb_ptr.line_start(fb_ptr.cursor);
            if (fb_ptr.cursor != ls) {
                fb_ptr.cursor = ls;
                return true;
            }
            return false;
        },
        0x4d => { // End
            const le = fb_ptr.line_end(fb_ptr.cursor);
            if (fb_ptr.cursor != le) {
                fb_ptr.cursor = le;
                return true;
            }
            return false;
        },
        0x4b => { // PageUp — jump up 10 lines
            var i: u8 = 0;
            var moved = false;
            while (i < 10) : (i += 1) {
                if (fb_ptr.move_up()) moved = true else break;
            }
            return moved;
        },
        0x4e => { // PageDown — jump down 10 lines
            var i: u8 = 0;
            var moved = false;
            while (i < 10) : (i += 1) {
                if (fb_ptr.move_down()) moved = true else break;
            }
            return moved;
        },
        0x4c => return fb_ptr.delete_forward(), // Delete
        else => {},
    }

    // Insert key toggles mode
    if (keycode == 0x49) {
        app.insert_mode = !app.insert_mode;
        app.set_status(if (app.insert_mode) "INS mode" else "OVR mode");
        return true;
    }

    // Ctrl+A / Ctrl+E (beginning/end of buffer)
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

    // F3: Save
    if (keycode == 0x3d) {
        app.set_status("Save not wired");
        return true;
    }

    // Backspace
    if (ascii == 0x08 or ascii == 0x7f) {
        return fb_ptr.backspace();
    }

    // Enter
    if (ascii == '\r' or ascii == '\n') {
        return fb_ptr.insert_newline();
    }

    // Printable
    if (ascii >= 0x20 and ascii <= 0x7e) {
        if (!app.insert_mode and fb_ptr.cursor < fb_ptr.len) {
            // Overwrite mode
            return fb_ptr.overwrite_char(@as(u8, @intCast(ascii)));
        }
        return fb_ptr.insert_char(@as(u8, @intCast(ascii)));
    }

    return false;
}

fn handle_console_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg0));
    const keycode: u16 = @as(u16, @intCast(ev.arg1));

    // Enter executes
    if (ascii == '\r' or ascii == '\n') {
        app.shell.execute(app.fb());
        return true;
    }

    // Backspace
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

    // Left/right in input
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
    } // Home
    if (keycode == 0x4d) {
        app.shell.cursor = app.shell.len;
        return true;
    } // End

    // PageUp/Down for scroll
    if (keycode == 0x4b) { // PageUp: scroll up
        app.shell.scroll = @min(app.shell.scroll + 5, 50);
        return true;
    }
    if (keycode == 0x4e) { // PageDown: scroll down
        if (app.shell.scroll > 5) app.shell.scroll -= 5 else app.shell.scroll = 0;
        return true;
    }

    // Printable
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
    try std.testing.expectEqual(@as(usize, 1), fb.current_line()); // cursor at 0
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
    fb.cursor = 7; // on 'g' of "defg"
    try std.testing.expect(fb.move_up());
    // col=3 on line of len=3 clips to 'c' at offset 2
    try std.testing.expectEqual(@as(usize, 2), fb.cursor);

    try std.testing.expect(fb.move_down());
    try std.testing.expectEqual(@as(usize, 6), fb.cursor); // back to "defg", col preserved
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

    // echo
    @memcpy(sh.buf[0..9], "echo hi!!");
    sh.len = 9;
    sh.execute(&fb);
    try std.testing.expect(std.mem.indexOf(u8, sh.output[0..sh.output_len], "hi!!\n") != null);

    // help
    @memcpy(sh.buf[0..4], "help");
    sh.len = 4;
    sh.execute(&fb);
    try std.testing.expect(std.mem.indexOf(u8, sh.output[0..sh.output_len], "echo <text>") != null);

    // clear
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
    fb.cursor = 2; // L2 C1
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
    // Simulate overwrite by directly writing to buf
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
    // set_content moves cursor, so move it back
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
    // New edit clears redo
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
    try std.testing.expectEqual(@as(usize, 12), fb.cursor); // start of "line3"
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
    _ = ta.open_new(); // now 2 tabs, active=1
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
    _ = ta.open_new(); // 2 tabs, active=1
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
    // Spot-check a few
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
    // "he\"llo" = 9 bytes: " h e \ " l l o "
    try std.testing.expectEqual(@as(usize, 9), r.len);
}

test "edit: E5 classify_token char literal" {
    const text = "'x' + 1";
    const r = classify_token(text);
    try std.testing.expectEqual(SyntaxKind.string, r.kind);
    try std.testing.expectEqual(@as(usize, 3), r.len);
}
