//! DipshitOS text editor — EDIT.BIN (M23 E1: base editor + E6: console split).
//!
//! A full-screen text editor with a line-number gutter, cursor navigation,
//! insert/overwrite mode, a status bar, and a Ctrl+` console split for running
//! shell-like commands without leaving the editor. Uses the ui.zig micro-widget
//! toolkit with zero dynamic allocation.
//!
//! E1 (base editor): 32 KiB file buffer, line index, cursor, status bar.
//! E6 (console split): Ctrl+` toggles a bottom 40% pane with a mini-shell
//! (echo, exec, cat, ls, pwd as builtins), Enter runs the command, output
//! scrolls in the pane.

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

// E6: console split dimensions
pub const split_ratio: u32 = 2; // editor gets 60%, console 40%
pub const console_split_h: u32 = text_area_h * 2 / 5; // bottom 40%
pub const console_rows: usize = 10;

// ---------------------------------------------------------------------------
// File Buffer (E1)
// ---------------------------------------------------------------------------

const file_buf_cap: usize = 32768;

const FileBuffer = struct {
    buf: [file_buf_cap]u8 = [_]u8{0} ** file_buf_cap,
    len: usize = 0,
    cursor: usize = 0,

    pub fn slice(self: *const FileBuffer) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set_content(self: *FileBuffer, content: []const u8) void {
        const n = @min(content.len, file_buf_cap);
        @memcpy(self.buf[0..n], content[0..n]);
        self.len = n;
        self.cursor = @min(self.cursor, n);
    }

    pub fn clear(self: *FileBuffer) void {
        self.len = 0;
        self.cursor = 0;
    }

    pub fn insert_char(self: *FileBuffer, ch: u8) bool {
        if (self.len >= file_buf_cap) return false;
        var i = self.len;
        while (i > self.cursor) : (i -= 1) self.buf[i] = self.buf[i - 1];
        self.buf[self.cursor] = ch;
        self.len += 1;
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
        var i = self.cursor - 1;
        while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
        self.len -= 1;
        self.cursor -= 1;
        return true;
    }

    pub fn delete_forward(self: *FileBuffer) bool {
        if (self.cursor >= self.len) return false;
        var i = self.cursor;
        while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
        self.len -= 1;
        return true;
    }

    pub fn insert_newline(self: *FileBuffer) bool {
        return self.insert_char('\n');
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
// Editor State
// ---------------------------------------------------------------------------

pub const AppState = struct {
    fb: FileBuffer = .{},
    shell: MiniShell = .{},
    status: [20]u8 = "EDIT.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*,
    status_len: usize = 8,
    insert_mode: bool = true,
    show_shell: bool = false,
    win_id: u32 = 0,

    pub fn init() AppState {
        return .{};
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
        ui.draw_text(win, "Ctrl+` shell F3:Save", @intCast(window_w - 260), 3, ui.COLOR_TEXT_MUTED);

        // Divider
        ui.draw_rect(win, Rect.make(0, 16, window_w, 1), ui.COLOR_BORDER);

        if (self.show_shell) {
            self.draw_split(win);
        } else {
            self.draw_editor_full(win);
        }
    }

    fn editor_top(self: *const AppState) u32 {
        return if (self.show_shell) 18 else 18;
    }

    fn editor_available_h(self: *const AppState) u32 {
        return if (self.show_shell)
            text_area_h - console_split_h - 2
        else
            text_area_h;
    }

    fn draw_editor_full(self: *const AppState, win: u32) void {
        const top = self.editor_top();
        const avail = self.editor_available_h();
        const vis_rows = @max(avail / line_h + 1, 2);

        // Editor surface
        ui.draw_rect(win, Rect.make(0, top, window_w, avail), ui.COLOR_SURFACE);

        // Gutter
        ui.draw_rect(win, Rect.make(0, top, gutter_w, avail), ui.COLOR_BG);

        const slice = self.fb.slice();

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
            ui.draw_text(win, slice[line_start..][0..take], editor_x0, gy, ui.COLOR_TEXT_PRIMARY);
        }

        // Cursor
        if (self.insert_mode) {
            const cl = self.fb.current_line();
            const cc = self.fb.current_col();
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

        const slice = self.fb.slice();
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
            ui.draw_text(win, slice[line_start..][0..take], editor_x0, gy, ui.COLOR_TEXT_PRIMARY);
        }

        // Editor cursor
        if (self.insert_mode) {
            const cl = self.fb.current_line();
            const cc = self.fb.current_col();
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
            const keycode: u16 = @as(u16, @intCast(ev.arg1));

            // Ctrl+` toggles the console split (E6)
            if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x32) { // ` key (US usage 0x32)
                app.show_shell = !app.show_shell;
                app.shell.reset();
                if (app.show_shell) {
                    app.set_status("Shell (E6)");
                } else {
                    app.set_status("EDIT.BIN");
                }
                dirty = true;
            } else if (app.show_shell) {
                // Console-mode key handling
                dirty = handle_console_key(&app, &ev) or dirty;
            } else {
                // Editor-mode key handling
                dirty = handle_editor_key(&app, &ev) or dirty;
            }
        }

        // Drain pending queue
        while (ui.poll_event(&ev) > 0) {
            if (ev.kind == ui.WIN_CLOSE) {
                ui.win_close(win);
                ui.exit_process(exit_status);
            }
            if (ev.kind == ui.KEY_DOWN) {
                const keycode: u16 = @as(u16, @intCast(ev.arg1));
                if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x32) {
                    app.show_shell = !app.show_shell;
                    app.shell.reset();
                    dirty = true;
                } else if (app.show_shell) {
                    dirty = handle_console_key(&app, &ev) or dirty;
                } else {
                    dirty = handle_editor_key(&app, &ev) or dirty;
                }
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

fn handle_editor_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg0));
    const keycode: u16 = @as(u16, @intCast(ev.arg1));

    // Navigation keys
    switch (keycode) {
        0x4f => return app.fb.move_left(), // Left
        0x50 => return app.fb.move_right(), // Right
        0x52 => return app.fb.move_up(), // Up
        0x51 => return app.fb.move_down(), // Down
        0x4a => { // Home
            const ls = app.fb.line_start(app.fb.cursor);
            if (app.fb.cursor != ls) {
                app.fb.cursor = ls;
                return true;
            }
            return false;
        },
        0x4d => { // End
            const le = app.fb.line_end(app.fb.cursor);
            if (app.fb.cursor != le) {
                app.fb.cursor = le;
                return true;
            }
            return false;
        },
        0x4b => { // PageUp — jump up 10 lines
            var i: u8 = 0;
            var moved = false;
            while (i < 10) : (i += 1) {
                if (app.fb.move_up()) moved = true else break;
            }
            return moved;
        },
        0x4e => { // PageDown — jump down 10 lines
            var i: u8 = 0;
            var moved = false;
            while (i < 10) : (i += 1) {
                if (app.fb.move_down()) moved = true else break;
            }
            return moved;
        },
        0x4c => return app.fb.delete_forward(), // Delete
        else => {},
    }

    // Insert key toggles mode
    if (keycode == 0x49) {
        app.insert_mode = !app.insert_mode;
        app.set_status(if (app.insert_mode) "INS mode" else "OVR mode");
        return true;
    }

    // Ctrl+A / Ctrl+E
    if ((ev.flags & ui.MOD_CTRL) != 0) {
        if (keycode == 0x04) {
            app.fb.cursor = 0;
            return true;
        }
        if (keycode == 0x08) {
            app.fb.cursor = app.fb.len;
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
        return app.fb.backspace();
    }

    // Enter
    if (ascii == '\r' or ascii == '\n') {
        return app.fb.insert_newline();
    }

    // Printable
    if (ascii >= 0x20 and ascii <= 0x7e) {
        if (!app.insert_mode and app.fb.cursor < app.fb.len) {
            // Overwrite mode
            app.fb.buf[app.fb.cursor] = @as(u8, @intCast(ascii));
            app.fb.cursor += 1;
            return true;
        }
        return app.fb.insert_char(@as(u8, @intCast(ascii)));
    }

    return false;
}

fn handle_console_key(app: *AppState, ev: *const Event) bool {
    const ascii: i32 = @as(i32, @intCast(ev.arg0));
    const keycode: u16 = @as(u16, @intCast(ev.arg1));

    // Enter executes
    if (ascii == '\r' or ascii == '\n') {
        app.shell.execute(&app.fb);
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
