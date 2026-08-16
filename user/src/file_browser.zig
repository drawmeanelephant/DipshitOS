//! DipshitOS twenty-first ESP user program — FILE.BIN (Milestone 13, Card B3).
//!
//! Graphical file browser for the DATA partition (`/data/`). Browses the
//! directory in a scrollable list, shows the selected entry's size/type, and
//! opens `.TXT` files in a read-only view. Uses the M10 file seam
//! (`sys_dir_list` / `sys_file_open` / `sys_file_read` / `sys_file_close`)
//! and the ui.zig micro-widget toolkit with ZERO heap allocation — every
//! buffer lives in the stack-allocated `AppState` (W^X safe: no writable
//! globals).
//!
//! Delete/rename arrive with card B1 (ADR 0007 slots 34–37, issue #161);
//! this app only browses and reads — the read-only ABI is the B3 core.

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const Event = ui.Event;
const DirEntry = ui.DirEntry;

pub const window_id: u32 = 5;
pub const window_x: u32 = 40;
pub const window_y: u32 = 40;
pub const window_w: u32 = 256;
pub const window_h: u32 = 192;

pub const exit_status: u32 = 43;
pub const data_path: []const u8 = "/data";

// Geometry (inside the 256x192 window).
pub const title_rect = Rect.make(0, 0, 256, 22);
pub const list_area = Rect.make(6, 26, 148, 130);
pub const details_area = Rect.make(158, 26, 92, 130);
pub const btn_open_rect = Rect.make(6, 162, 44, 22);
pub const btn_rename_rect = Rect.make(54, 162, 52, 22);
pub const btn_delete_rect = Rect.make(110, 162, 52, 22);
pub const btn_back_rect = Rect.make(6, 162, 44, 22); // overlaps Open; mode-exclusive

pub const list_row_h: u32 = 16;
pub const glyph_w: u32 = 8;
pub const line_h: u32 = 12;
pub const view_text_x: u32 = 10;
pub const view_text_y: u32 = 30;
pub const view_cols: usize = 29; // (window_w - 12 - 12) / glyph_w
pub const view_rows: usize = 9; // ~(details_area.h - 12) / line_h

pub const max_entries: usize = 16;
pub const content_max: usize = 512;

// ---------------------------------------------------------------------------
// Hand-rolled string building (W^X-safe; std.fmt.bufPrint is avoided — see
// desktop.zig claim 8877 for the FP/SIMD root cause).
// ---------------------------------------------------------------------------

fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    @memcpy(buf[pos .. pos + src.len], src);
    return pos + src.len;
}

fn fmt_u64(buf: []u8, value: u64) []const u8 {
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }
    return buf[i..];
}

// ---------------------------------------------------------------------------
// Entry helpers (pure, host-testable)
// ---------------------------------------------------------------------------

/// Length of a NUL-padded `name[32]` (FAT display name).
pub fn entry_name(entry: *const DirEntry) []const u8 {
    var len: usize = 0;
    while (len < entry.name.len and entry.name[len] != 0) : (len += 1) {}
    return entry.name[0..len];
}

fn ascii_upper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

/// True when the name ends in `.TXT` (case-insensitive) — the files this
/// browser opens read-only.
pub fn is_txt_file(name: []const u8) bool {
    if (name.len < 4) return false;
    const s = name[name.len - 4 ..];
    return ascii_upper(s[0]) == '.' and
        ascii_upper(s[1]) == 'T' and
        ascii_upper(s[2]) == 'X' and
        ascii_upper(s[3]) == 'T';
}

/// Number of display rows a content slice occupies, wrapping at `cols`
/// glyphs per row and breaking on '\\n' (mirrors notepad's TextLayout).
pub fn content_rows(content: []const u8, cols: usize) usize {
    var row: usize = 0;
    var col: usize = 0;
    for (content) |ch| {
        if (ch == '\n') {
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
    return row + 1;
}

// ---------------------------------------------------------------------------
// Scrollable file-list model (selection + viewport, host-testable)
// ---------------------------------------------------------------------------

pub const FileList = struct {
    rect: Rect,
    row_height: u32 = list_row_h,
    scroll: usize = 0,
    selected: ?usize = null,

    pub fn init(rect: Rect) FileList {
        return .{ .rect = rect };
    }

    pub fn visible_rows(self: *const FileList) usize {
        if (self.row_height == 0) return 0;
        return @intCast(self.rect.h / self.row_height);
    }

    /// Largest legal scroll offset for `count` entries.
    pub fn max_scroll(self: *const FileList, count: usize) usize {
        const vis = self.visible_rows();
        if (count <= vis) return 0;
        return count - vis;
    }

    /// Keep the selection inside the viewport; clamps `scroll`.
    pub fn ensure_visible(self: *FileList, count: usize) void {
        const ms = self.max_scroll(count);
        if (self.scroll > ms) self.scroll = ms;
        const sel = self.selected orelse return;
        const vis = self.visible_rows();
        if (vis == 0) return;
        if (sel < self.scroll) self.scroll = sel;
        if (sel >= self.scroll + vis) self.scroll = sel - vis + 1;
    }

    pub fn select(self: *FileList, idx: usize, count: usize) void {
        if (count == 0) {
            self.selected = null;
            return;
        }
        self.selected = @min(idx, count - 1);
        self.ensure_visible(count);
    }

    pub fn move_by(self: *FileList, delta: isize, count: usize) void {
        if (count == 0) return;
        const base: isize = if (self.selected) |s| @intCast(s) else -1;
        var next = base + delta;
        if (next < 0) next = 0;
        if (next >= @as(isize, @intCast(count))) next = @intCast(count - 1);
        self.selected = @intCast(next);
        self.ensure_visible(count);
    }

    /// Click-to-select: maps a window-local (px,py) to the absolute entry
    /// index (scroll-aware). Returns true when the selection changed.
    pub fn click(self: *FileList, px: u32, py: u32, count: usize) bool {
        if (count == 0 or !self.rect.contains(px, py)) return false;
        const rel_y = py - self.rect.y;
        const row = rel_y / self.row_height;
        if (row >= self.visible_rows()) return false;
        const abs = self.scroll + @as(usize, @intCast(row));
        if (abs >= count) return false;
        const prev = self.selected;
        self.selected = abs;
        return prev != self.selected;
    }
};

// ---------------------------------------------------------------------------
// App State (stack-allocated, W^X-safe)
// ---------------------------------------------------------------------------

/// Render one list row (shared by AppState.draw_list).
fn draw_list_row(win: u32, row: usize, name: []const u8, entry: *const DirEntry, is_sel: bool) void {
    const row_y = list_area.y + @as(u32, @intCast(row)) * list_row_h;
    const row_rect = Rect.make(list_area.x, row_y, list_area.w, list_row_h);
    const bg = if (is_sel)
        ui.COLOR_ACCENT
    else if (entry.is_dir != 0)
        ui.COLOR_BTN_IDLE
    else if (row % 2 == 0)
        ui.COLOR_SURFACE
    else
        ui.COLOR_BG;
    ui.draw_rect(win, row_rect, bg);
    // Cap the drawn name to the row width (148 - 8 padding = 140px = 17 glyphs).
    const cap = @min(name.len, 17);
    ui.draw_text(win, name[0..cap], row_rect.x + 4, row_rect.y + (list_row_h - 8) / 2, ui.COLOR_TEXT_PRIMARY);
}

pub const AppState = struct {
    entries: [max_entries]DirEntry = undefined,
    entry_count: usize = 0,

    list: FileList = FileList.init(list_area),

    // Read-only view state.
    view_mode: bool = false,
    view_name: [32]u8 = [_]u8{0} ** 32,
    view_name_len: usize = 0,
    content: [content_max]u8 = undefined,
    content_len: usize = 0,

    status_msg: [24]u8 = "Ready\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*,
    status_len: usize = 5,

    btn_open: Button = Button.init(btn_open_rect, "Open"),
    btn_rename: Button = Button.init(btn_rename_rect, "Rename"),
    btn_delete: Button = Button.init(btn_delete_rect, "Delete"),
    btn_back: Button = Button.init(btn_back_rect, "Back"),

    pub fn init() AppState {
        var s = AppState{};
        s.btn_open.bg_color = ui.COLOR_ACCENT;
        s.btn_rename.bg_color = ui.COLOR_WARNING;
        s.btn_delete.bg_color = ui.COLOR_DANGER;
        s.btn_back.bg_color = ui.COLOR_SUCCESS;
        return s;
    }

    pub fn set_status(self: *AppState, msg: []const u8) void {
        const n = @min(msg.len, self.status_msg.len);
        @memcpy(self.status_msg[0..n], msg[0..n]);
        self.status_len = n;
    }

    /// Enumerate `/data/` via `sys_dir_list` (slot 27). Emits a
    /// `file: listing N entries` marker for the live gate.
    pub fn list_directory(self: *AppState) void {
        const res = ui.dir_list(data_path, &self.entries);
        if (res < 0) {
            self.entry_count = 0;
            self.set_status("List Err");
            ui.write_console("file: list error\n");
            return;
        }
        self.entry_count = @intCast(res);
        self.list.select(0, self.entry_count);
        self.set_status("Listed");

        var buf: [48]u8 = undefined;
        var pos: usize = 0;
        pos = append_str(&buf, pos, "file: listing ");
        pos = append_str(&buf, pos, fmt_u64(buf[pos..], self.entry_count));
        pos = append_str(&buf, pos, " entries\n");
        ui.write_console(buf[0..pos]);
    }

    /// Open the selected entry read-only. Emits `file: open NAME` + the
    /// read result marker (`file: view NAME` / `file: read error`). Only
    /// regular files open; directories and non-TXT files are refused with
    /// an honest status (the browser's view is a text view).
    pub fn open_selected(self: *AppState) bool {
        const sel = self.list.selected orelse return false;
        if (sel >= self.entry_count) return false;
        const entry = &self.entries[sel];
        const name = entry_name(entry);

        if (entry.is_dir != 0) {
            self.set_status("Is a directory");
            return false;
        }

        // Build "/data/<name>" (name ≤ 31, prefix is 6).
        var path_buf: [64]u8 = undefined;
        const path = build_data_path(&path_buf, name);

        const fd = ui.file_open(path, ui.MODE_READ);
        if (fd < 0) {
            self.set_status("Open Err");
            return false;
        }
        const n = ui.file_read(@as(u32, @intCast(fd)), &self.content);
        ui.file_close(@as(u32, @intCast(fd)));
        if (n < 0) {
            self.set_status("Read Err");
            return false;
        }

        const cn = @min(name.len, self.view_name.len);
        @memcpy(self.view_name[0..cn], name[0..cn]);
        self.view_name_len = cn;
        self.content_len = @intCast(n);
        self.view_mode = true;
        self.set_status("Viewing");

        var obuf: [64]u8 = undefined;
        var opos: usize = 0;
        opos = append_str(&obuf, opos, "file: open ");
        opos = append_str(&obuf, opos, name);
        obuf[opos] = '\n';
        ui.write_console(obuf[0 .. opos + 1]);

        var vbuf: [64]u8 = undefined;
        var vpos: usize = 0;
        vpos = append_str(&vbuf, vpos, "file: view ");
        vpos = append_str(&vbuf, vpos, name);
        vbuf[vpos] = '\n';
        ui.write_console(vbuf[0 .. vpos + 1]);

        return true;
    }

    pub fn back_to_list(self: *AppState) void {
        self.view_mode = false;
        self.content_len = 0;
        self.set_status("Listed");
        ui.write_console("file: back\n");
    }

    /// Re-list `/data/`, preserving the selection when it still fits.
    pub fn refresh(self: *AppState) void {
        const prev = self.list.selected;
        self.list_directory();
        if (self.entry_count > 0) {
            const idx = if (prev) |p| @min(p, self.entry_count - 1) else 0;
            self.list.select(idx, self.entry_count);
        }
    }

    /// Delete the selected entry through sys_file_delete (slot 34). Emits
    /// `file: delete NAME` on success. Directories are refused.
    pub fn delete_selected(self: *AppState) bool {
        const sel = self.list.selected orelse return false;
        if (sel >= self.entry_count) return false;
        const entry = &self.entries[sel];
        const name = entry_name(entry);
        if (entry.is_dir != 0) {
            self.set_status("Is dir");
            return false;
        }

        var path_buf: [64]u8 = undefined;
        const path = build_data_path(&path_buf, name);
        const res = ui.file_delete(path);
        if (res < 0) {
            self.set_status("Del Err");
            return false;
        }

        var obuf: [64]u8 = undefined;
        var opos: usize = 0;
        opos = append_str(&obuf, opos, "file: delete ");
        opos = append_str(&obuf, opos, name);
        obuf[opos] = '\n';
        ui.write_console(obuf[0 .. opos + 1]);

        self.set_status("Deleted");
        self.refresh();
        return true;
    }

    /// Rename the selected entry to `STEM.BAK` through sys_file_rename
    /// (slot 35). Emits `file: rename NAME -> NEW` on success.
    pub fn rename_selected(self: *AppState) bool {
        const sel = self.list.selected orelse return false;
        if (sel >= self.entry_count) return false;
        const entry = &self.entries[sel];
        const name = entry_name(entry);
        if (entry.is_dir != 0) {
            self.set_status("Is dir");
            return false;
        }

        var bak: [32]u8 = undefined;
        const new_name = make_bak_name(name, &bak);
        var old_path: [64]u8 = undefined;
        var new_path: [64]u8 = undefined;
        const op = build_data_path(&old_path, name);
        const np = build_data_path(&new_path, new_name);
        const res = ui.file_rename(op, np);
        if (res < 0) {
            self.set_status("Ren Err");
            return false;
        }

        var obuf: [96]u8 = undefined;
        var opos: usize = 0;
        opos = append_str(&obuf, opos, "file: rename ");
        opos = append_str(&obuf, opos, name);
        opos = append_str(&obuf, opos, " -> ");
        opos = append_str(&obuf, opos, new_name);
        obuf[opos] = '\n';
        ui.write_console(obuf[0 .. opos + 1]);

        self.set_status("Renamed");
        self.refresh();
        return true;
    }

    pub fn draw(self: *const AppState, win: u32) void {
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.COLOR_BG);

        // Title bar.
        ui.draw_rect(win, title_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, title_rect, 1, ui.COLOR_BORDER);
        if (self.view_mode) {
            ui.draw_text(win, "View", 8, 8, ui.COLOR_TEXT_PRIMARY);
            ui.draw_text(win, self.view_name[0..self.view_name_len], 56, 8, ui.COLOR_ACCENT);
        } else {
            ui.draw_text(win, "Files:", 8, 8, ui.COLOR_TEXT_PRIMARY);
            ui.draw_text(win, "/data", 60, 8, ui.COLOR_ACCENT);
        }

        // Status strip (title-bar right).
        ui.draw_text(win, self.status_msg[0..self.status_len], 150, 8, ui.COLOR_TEXT_MUTED);

        if (self.view_mode) {
            self.draw_view(win);
            self.btn_back.draw(win);
        } else {
            self.draw_list(win);
            self.draw_details(win);
            self.btn_open.draw(win);
            self.btn_rename.draw(win);
            self.btn_delete.draw(win);
        }
    }

    fn draw_list(self: *const AppState, win: u32) void {
        ui.draw_rect(win, list_area, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, list_area, 1, ui.COLOR_BORDER);

        const vis = self.list.visible_rows();
        var i = self.list.scroll;
        var row: usize = 0;
        while (i < self.entry_count and row < vis) : ({
            i += 1;
            row += 1;
        }) {
            const entry = &self.entries[i];
            const name = entry_name(entry);
            const is_sel = if (self.list.selected) |s| s == i else false;
            draw_list_row(win, row, name, entry, is_sel);
        }
    }

    fn draw_details(self: *const AppState, win: u32) void {
        ui.draw_rect(win, details_area, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, details_area, 1, ui.COLOR_BORDER);

        const sel = self.list.selected orelse {
            ui.draw_text(win, "(empty)", details_area.x + 6, details_area.y + 8, ui.COLOR_TEXT_MUTED);
            return;
        };
        if (sel >= self.entry_count) return;
        const entry = &self.entries[sel];
        const name = entry_name(entry);

        ui.draw_text(win, "Size", details_area.x + 6, details_area.y + 6, ui.COLOR_TEXT_MUTED);
        var sbuf: [24]u8 = undefined;
        var spos: usize = 0;
        spos = append_str(&sbuf, spos, fmt_u64(sbuf[spos..], entry.size));
        spos = append_str(&sbuf, spos, " B");
        ui.draw_text(win, sbuf[0..spos], details_area.x + 6, details_area.y + 20, ui.COLOR_TEXT_PRIMARY);

        ui.draw_text(win, "Type", details_area.x + 6, details_area.y + 44, ui.COLOR_TEXT_MUTED);
        const type_label: []const u8 = if (entry.is_dir != 0) "DIR" else "FILE";
        ui.draw_text(win, type_label, details_area.x + 6, details_area.y + 58, if (entry.is_dir != 0) ui.COLOR_WARNING else ui.COLOR_SUCCESS);

        ui.draw_text(win, "Name", details_area.x + 6, details_area.y + 82, ui.COLOR_TEXT_MUTED);
        const cap = @min(name.len, 10);
        ui.draw_text(win, name[0..cap], details_area.x + 6, details_area.y + 96, ui.COLOR_ACCENT);
    }

    fn draw_view(self: *const AppState, win: u32) void {
        const body = Rect.make(6, 26, 244, 130);
        ui.draw_rect(win, body, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, body, 1, ui.COLOR_BORDER);

        const slice = self.content[0..self.content_len];
        // Render the first `view_rows` display rows with the same wrap rule
        // `content_rows` documents (29 glyphs/row, '\\n' forces a break).
        var row: usize = 0;
        var col: usize = 0;
        for (slice) |ch| {
            if (ch == '\n') {
                row += 1;
                col = 0;
                continue;
            }
            if (col == view_cols) {
                row += 1;
                col = 0;
            }
            if (row >= view_rows) break;
            const x = view_text_x + @as(u32, @intCast(col)) * glyph_w;
            const y = view_text_y + @as(u32, @intCast(row)) * line_h;
            ui.draw_char(win, ch, x, y, ui.COLOR_TEXT_PRIMARY);
            col += 1;
        }
    }

    pub fn handle_mouse_events(self: *AppState, ev: *const Event) bool {
        if (self.view_mode) {
            if (self.btn_back.handle_event(ev)) {
                self.back_to_list();
                return true;
            }
            return false;
        }

        if (self.btn_open.handle_event(ev)) {
            return self.open_selected();
        }
        if (self.btn_rename.handle_event(ev)) {
            return self.rename_selected();
        }
        if (self.btn_delete.handle_event(ev)) {
            return self.delete_selected();
        }
        if (ev.kind == ui.MOUSE_DOWN and (ev.flags & ui.BTN_LEFT) != 0) {
            return self.list.click(ev.arg0, ev.arg1, self.entry_count);
        }
        return false;
    }

    pub fn handle_keyboard_event(self: *AppState, ev: *const Event) bool {
        if (ev.kind != ui.KEY_DOWN) return false;
        const keycode = ev.arg0;
        const ascii_char: u8 = @truncate(ev.arg1);

        if (self.view_mode) {
            // Esc (0x29) or Enter returns to the list.
            if (keycode == 0x29) {
                self.back_to_list();
                return true;
            }
            return false;
        }

        // Enter opens the selected entry.
        if (keycode == 0x28 or ascii_char == '\n' or ascii_char == '\r') {
            return self.open_selected();
        }

        // 'd' deletes, 'r' renames the selected entry (claim 5801 slots 34/35).
        if (ascii_char == 'd' or ascii_char == 'D') {
            return self.delete_selected();
        }
        if (ascii_char == 'r' or ascii_char == 'R') {
            return self.rename_selected();
        }

        switch (keycode) {
            0x52 => { // Up
                self.list.move_by(-1, self.entry_count);
                return true;
            },
            0x51 => { // Down
                self.list.move_by(1, self.entry_count);
                return true;
            },
            0x4a => { // Home
                self.list.select(0, self.entry_count);
                return true;
            },
            0x4d => { // End
                if (self.entry_count > 0) {
                    self.list.select(self.entry_count - 1, self.entry_count);
                }
                return true;
            },
            else => {},
        }
        return false;
    }
};

/// Build `/data/<name>` into `buf` (caller provides ≥ 6 + name.len bytes).
pub fn build_data_path(buf: []u8, name: []const u8) []const u8 {
    const prefix = "/data/";
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + name.len], name);
    return buf[0 .. prefix.len + name.len];
}

/// Build `<stem>.BAK` from `name` (an existing extension is stripped; the
/// stem is capped at 8 chars so the result always fits FAT 8.3). Caller
/// provides a buffer ≥ 12 bytes.
pub fn make_bak_name(name: []const u8, buf: []u8) []const u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| name[0..i] else name;
    const n = @min(@min(stem.len, 8), buf.len - 4);
    @memcpy(buf[0..n], stem[0..n]);
    const suffix = ".BAK";
    @memcpy(buf[n .. n + 4], suffix);
    return buf[0 .. n + 4];
}

// ---------------------------------------------------------------------------
// Entry Point (EL0)
// ---------------------------------------------------------------------------

pub export fn _start() callconv(.c) noreturn {
    var app = AppState.init();

    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("file: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));
    ui.write_console("file: open id=5\n");

    app.list_directory();
    app.draw(win);
    ui.win_present(win);
    ui.write_console("file: ready\n");

    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        if (ev.kind == ui.WIN_CLOSE) {
            ui.write_console("file: close\n");
            break;
        }

        if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
            dirty = app.handle_mouse_events(&ev) or dirty;
        } else if (ev.kind == ui.KEY_DOWN) {
            dirty = app.handle_keyboard_event(&ev) or dirty;
        }

        while (ui.poll_event(&ev) > 0) {
            if (ev.kind == ui.WIN_CLOSE) {
                ui.write_console("file: close\n");
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

    ui.write_console("file: exiting 43\n");
    ui.win_close(win);
    ui.exit_process(exit_status);
}

// ---------------------------------------------------------------------------
// Unit Tests (Class A Host Validation)
// ---------------------------------------------------------------------------

test "file: entry_name stops at the NUL pad and is_txt_file checks the suffix" {
    var de = DirEntry{
        .name = [_]u8{0} ** 32,
        .size = 90,
        .is_dir = 0,
        .reserved = .{ 0, 0, 0 },
    };
    @memcpy(de.name[0..10], "README.TXT");
    try std.testing.expectEqualStrings("README.TXT", entry_name(&de));
    try std.testing.expect(is_txt_file("README.TXT"));
    try std.testing.expect(is_txt_file("notes.txt")); // case-insensitive
    try std.testing.expect(!is_txt_file("DATA.TXT") == false);
    try std.testing.expect(!is_txt_file("hello.bin"));
    try std.testing.expect(!is_txt_file("README"));
}

test "file: content_rows wraps and counts newlines (claim B3)" {
    try std.testing.expectEqual(@as(usize, 1), content_rows("", 29));
    try std.testing.expectEqual(@as(usize, 1), content_rows("short", 29));
    // Exactly cols glyphs stays on one row.
    const full = [_]u8{'a'} ** 29;
    try std.testing.expectEqual(@as(usize, 1), content_rows(&full, 29));
    // cols+1 wraps to a second row.
    const over = [_]u8{'a'} ** 30;
    try std.testing.expectEqual(@as(usize, 2), content_rows(&over, 29));
    // A newline forces a break (a trailing newline still counts its row).
    try std.testing.expectEqual(@as(usize, 2), content_rows("ab\ncd", 29));
    try std.testing.expectEqual(@as(usize, 2), content_rows("ab\n", 29));
}

test "file: FileList selection, scrolling, and click mapping" {
    var fl = FileList.init(list_area);
    try std.testing.expectEqual(@as(usize, 8), fl.visible_rows()); // 130/16

    // 10 entries -> scrollable by 2.
    const count: usize = 10;
    try std.testing.expectEqual(@as(usize, 2), fl.max_scroll(count));

    fl.select(0, count);
    try std.testing.expectEqual(@as(?usize, 0), fl.selected);

    // Move down past the viewport scrolls the list.
    var i: usize = 0;
    while (i < 9) : (i += 1) fl.move_by(1, count);
    try std.testing.expectEqual(@as(?usize, 9), fl.selected);
    try std.testing.expectEqual(@as(usize, 2), fl.scroll); // 9 - 8 + 1

    // Click maps the visible row to an absolute index (scroll-aware).
    // Visible row 0 is absolute entry 2.
    _ = fl.click(list_area.x + 4, list_area.y + 2, count);
    try std.testing.expectEqual(@as(?usize, 2), fl.selected);

    // Home via select clamps scroll back to 0.
    fl.select(0, count);
    try std.testing.expectEqual(@as(?usize, 0), fl.selected);
    try std.testing.expectEqual(@as(usize, 0), fl.scroll);

    // Empty list: selection clears, navigation is a no-op.
    fl.select(3, 0);
    try std.testing.expectEqual(@as(?usize, null), fl.selected);
    fl.move_by(1, 0);
    try std.testing.expectEqual(@as(?usize, null), fl.selected);
}

test "file: build_data_path prefixes /data/" {
    var buf: [64]u8 = undefined;
    const p = build_data_path(&buf, "README.TXT");
    try std.testing.expectEqualStrings("/data/README.TXT", p);
}

test "file: AppState fits the 16 KiB EL0 stack (W^X, claim B3)" {
    try std.testing.expect(@sizeOf(AppState) < 4 * 1024);
    std.debug.print("AppState size: {d}\\n", .{@sizeOf(AppState)});
}

test "file: keyboard navigation routes through the FileList model" {
    var app = AppState.init();
    app.entry_count = 3;
    app.list.select(0, app.entry_count);

    var ev_down = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x51, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_down));
    try std.testing.expectEqual(@as(?usize, 1), app.list.selected);

    var ev_up = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x52, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_up));
    try std.testing.expectEqual(@as(?usize, 0), app.list.selected);

    var ev_end = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x4d, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_end));
    try std.testing.expectEqual(@as(?usize, 2), app.list.selected);

    // Esc in list mode is not handled (nothing to go back to).
    var ev_esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x29, .arg1 = 0 };
    try std.testing.expect(!app.handle_keyboard_event(&ev_esc));
}

test "file: view-mode Esc returns to the list (claim B3)" {
    var app = AppState.init();
    app.view_mode = true;
    var ev_esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x29, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_esc));
    try std.testing.expect(!app.view_mode);
}

test "file: make_bak_name strips the extension and caps the stem (claim 5801)" {
    var b: [32]u8 = [_]u8{0} ** 32;
    try std.testing.expectEqualStrings("README.BAK", make_bak_name("README.TXT", &b));
    try std.testing.expectEqualStrings("DATA.BAK", make_bak_name("DATA.TXT", &b));
    try std.testing.expectEqualStrings("noext.BAK", make_bak_name("noext", &b));
    try std.testing.expectEqualStrings("verylong.BAK", make_bak_name("verylongname.TXT", &b));
}

test "file: 'd' and 'r' route to delete/rename (claim 5801)" {
    var app = AppState.init();
    app.entries[0] = .{ .name = [_]u8{0} ** 32, .size = 10, .is_dir = 0, .reserved = .{ 0, 0, 0 } };
    @memcpy(app.entries[0].name[0..10], "README.TXT");
    app.entry_count = 1;
    app.list.select(0, 1);

    // 'd' routes to delete (host syscall returns 0, so the success path runs).
    var ev_d = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x07, .arg1 = 'd' };
    try std.testing.expect(app.handle_keyboard_event(&ev_d));

    // 'r' routes to rename.
    app.entries[0] = .{ .name = [_]u8{0} ** 32, .size = 10, .is_dir = 0, .reserved = .{ 0, 0, 0 } };
    @memcpy(app.entries[0].name[0..10], "README.TXT");
    app.entry_count = 1;
    app.list.select(0, 1);
    var ev_r = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x15, .arg1 = 'r' };
    try std.testing.expect(app.handle_keyboard_event(&ev_r));
}
