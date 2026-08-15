//! DipshitOS fifteenth ESP user program — NOTEPAD.BIN (Milestone 11, Card A3).
//!
//! Interactive graphical text editor with multi-line editing, cursor navigation,
//! and persistent load/save from `/data/notes.txt` using M10 storage syscalls.
//! Uses zero dynamic memory allocation (`ui.zig` micro-widgets).

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
// Editor GUI State (Stack-Allocated AppState)
// ---------------------------------------------------------------------------

pub const AppState = struct {
    buffer: TextBuffer = .{},
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
        const text_area = Rect.make(6, 36, 244, 150);
        ui.draw_rect(win, text_area, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, text_area, 1, ui.COLOR_BORDER);

        // Render text with multi-line flow and cursor
        var cur_x = text_area.x + 6;
        var cur_y = text_area.y + 6;
        const max_x = text_area.x + text_area.w - 12;
        const line_height: u32 = 12;

        var cursor_drawn = false;

        const slice = self.buffer.get_slice();
        var idx: usize = 0;
        while (idx <= slice.len) : (idx += 1) {
            // Draw cursor if at cursor position
            if (idx == self.buffer.cursor) {
                if (cur_x + 2 <= text_area.x + text_area.w and cur_y + 8 <= text_area.y + text_area.h) {
                    ui.win_fill(win, cur_x, cur_y, 2, 8, ui.COLOR_ACCENT);
                }
                cursor_drawn = true;
            }

            if (idx == slice.len) break;

            const ch = slice[idx];
            if (ch == '\n') {
                cur_x = text_area.x + 6;
                cur_y += line_height;
                if (cur_y + 8 > text_area.y + text_area.h) break;
                continue;
            }

            if (cur_x + 8 > max_x) {
                cur_x = text_area.x + 6;
                cur_y += line_height;
                if (cur_y + 8 > text_area.y + text_area.h) break;
            }

            ui.draw_char(win, ch, cur_x, cur_y, ui.COLOR_TEXT_PRIMARY);
            cur_x += 8;
        }

        if (!cursor_drawn and cur_y + 8 <= text_area.y + text_area.h) {
            ui.win_fill(win, cur_x, cur_y, 2, 8, ui.COLOR_ACCENT);
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
            self.set_status("Cleared");
            changed = true;
        }

        return changed;
    }

    pub fn handle_keyboard_event(self: *AppState, ev: *const Event) bool {
        if (ev.kind != ui.KEY_DOWN) return false;
        const keycode = ev.arg0;
        const ascii = @as(u8, @truncate(ev.arg1));

        // Backspace
        if (ascii == 0x08 or keycode == 0x2a) {
            if (self.buffer.backspace()) {
                self.set_status("Editing");
                return true;
            }
            return false;
        }

        // Enter / Newline
        if (ascii == '\r' or ascii == '\n' or keycode == 0x28) {
            if (self.buffer.insert_char('\n')) {
                self.set_status("Editing");
                return true;
            }
            return false;
        }

        // Left arrow
        if (keycode == 0x50) {
            return self.buffer.move_cursor_left();
        }

        // Right arrow
        if (keycode == 0x4f) {
            return self.buffer.move_cursor_right();
        }

        // Printable character
        if (ascii >= 0x20 and ascii <= 0x7e) {
            if (self.buffer.insert_char(ascii)) {
                self.set_status("Editing");
                return true;
            }
        }

        return false;
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
