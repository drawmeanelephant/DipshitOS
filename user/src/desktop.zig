//! DipshitOS seventeenth ESP user program — DESKTOP.BIN (Milestone 11, Card A5).
//!
//! Desktop Launcher & Environment Panel.
//! Provides system diagnostics, a quick application launcher bar, and
//! an interactive catalog of installed userland programs on the ESP.

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const Label = ui.Label;
const ListView = ui.ListView;
const Event = ui.Event;

pub const window_id: u32 = 4;
pub const window_x: u32 = 16;
pub const window_y: u32 = 16;
pub const window_w: u32 = 256;
pub const window_h: u32 = 192;

pub const exit_status: u32 = 43;

// ---------------------------------------------------------------------------
// App Entry Metadata
// ---------------------------------------------------------------------------

pub const AppEntry = struct {
    name: []const u8,
    desc: []const u8,
    status: []const u8,
};

pub const installed_apps = [_]AppEntry{
    .{ .name = "CALC.BIN", .desc = "64-bit Calc", .status = "GUI Active" },
    .{ .name = "NOTEPAD.BIN", .desc = "Text Editor", .status = "/data Storage" },
    .{ .name = "TOP.BIN", .desc = "Task Manager", .status = "sys_procs" },
    .{ .name = "KEYTEST.BIN", .desc = "HID Input", .status = "USB Events" },
    .{ .name = "TYPE.BIN", .desc = "File Reader", .status = "FAT32 Data" },
    .{ .name = "DIR.BIN", .desc = "Directory List", .status = "FAT32 ESP" },
};

// ---------------------------------------------------------------------------
// GUI Components & State
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// GUI Components & App State (Stack-Allocated AppState)
// ---------------------------------------------------------------------------

pub const AppState = struct {
    btn_calc: Button = Button.init(Rect.make(6, 30, 52, 22), "Calc"),
    btn_notes: Button = Button.init(Rect.make(62, 30, 58, 22), "Notes"),
    btn_top: Button = Button.init(Rect.make(124, 30, 52, 22), "Top"),
    btn_key: Button = Button.init(Rect.make(180, 30, 70, 22), "Keytest"),

    list_apps: ListView = ListView.init(Rect.make(6, 58, 118, 128), 18),
    active_procs_count: usize = 1,

    pub fn init() AppState {
        var s = AppState{};
        s.btn_calc.bg_color = ui.COLOR_ACCENT;
        s.btn_notes.bg_color = 0x8b5cf6; // Purple accent
        s.btn_top.bg_color = ui.COLOR_SUCCESS;
        s.btn_key.bg_color = ui.COLOR_WARNING;

        s.list_apps.item_count = installed_apps.len;
        s.list_apps.selected_idx = 0;

        // Refresh active procs count
        var raw: [320]u8 = undefined;
        const res = ui.get_procs(&raw);
        if (res > 0) {
            s.active_procs_count = @as(usize, @intCast(res));
        }
        return s;
    }

    pub fn draw(self: *const AppState, win: u32) void {
        // 1. Background
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.COLOR_BG);

        // 2. Top Title & Diagnostics Bar
        const title_rect = Rect.make(0, 0, window_w, 24);
        ui.draw_rect(win, title_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, title_rect, 1, ui.COLOR_BORDER);
        ui.draw_text(win, "DipshitOS", 8, 8, ui.COLOR_TEXT_PRIMARY);

        var diag_buf: [32]u8 = undefined;
        const diag_str = std.fmt.bufPrint(&diag_buf, "P:{d} A:{d}", .{ self.active_procs_count, installed_apps.len }) catch "P:?";
        ui.draw_text(win, diag_str, 196, 8, ui.COLOR_TEXT_MUTED);

        // 3. Quick Launch Bar
        self.btn_calc.draw(win);
        self.btn_notes.draw(win);
        self.btn_top.draw(win);
        self.btn_key.draw(win);

        // 4. Installed Programs List
        ui.draw_rect(win, self.list_apps.rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, self.list_apps.rect, 1, ui.COLOR_BORDER);
        var i: usize = 0;
        while (i < installed_apps.len) : (i += 1) {
            const is_sel = if (self.list_apps.selected_idx) |sel| sel == i else false;
            self.list_apps.draw_row(win, i, installed_apps[i].name, is_sel);
        }

        // 5. App Details Pane
        const details_rect = Rect.make(128, 58, 122, 128);
        ui.draw_rect(win, details_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, details_rect, 1, ui.COLOR_BORDER);

        const sel_idx = self.list_apps.selected_idx orelse 0;
        if (sel_idx < installed_apps.len) {
            const app = &installed_apps[sel_idx];
            ui.draw_text(win, "App:", details_rect.x + 6, details_rect.y + 8, ui.COLOR_TEXT_MUTED);
            ui.draw_text(win, app.name, details_rect.x + 6, details_rect.y + 22, ui.COLOR_ACCENT);

            ui.draw_text(win, "Desc:", details_rect.x + 6, details_rect.y + 44, ui.COLOR_TEXT_MUTED);
            ui.draw_text(win, app.desc, details_rect.x + 6, details_rect.y + 58, ui.COLOR_TEXT_PRIMARY);

            ui.draw_text(win, "Target:", details_rect.x + 6, details_rect.y + 80, ui.COLOR_TEXT_MUTED);
            ui.draw_text(win, app.status, details_rect.x + 6, details_rect.y + 94, ui.COLOR_SUCCESS);
        }
    }

    pub fn handle_mouse_events(self: *AppState, ev: *const Event) bool {
        var changed = false;

        if (self.btn_calc.handle_event(ev)) {
            self.list_apps.selected_idx = 0;
            ui.write_console("desktop: select CALC.BIN\n");
            changed = true;
        } else if (self.btn_notes.handle_event(ev)) {
            self.list_apps.selected_idx = 1;
            ui.write_console("desktop: select NOTEPAD.BIN\n");
            changed = true;
        } else if (self.btn_top.handle_event(ev)) {
            self.list_apps.selected_idx = 2;
            ui.write_console("desktop: select TOP.BIN\n");
            changed = true;
        } else if (self.btn_key.handle_event(ev)) {
            self.list_apps.selected_idx = 3;
            ui.write_console("desktop: select KEYTEST.BIN\n");
            changed = true;
        } else if (self.list_apps.handle_event(ev)) {
            if (self.list_apps.selected_idx) |sel| {
                if (sel < installed_apps.len) {
                    ui.write_console("desktop: select app\n");
                }
            }
            changed = true;
        }

        return changed;
    }

    pub fn handle_keyboard_event(self: *AppState, ev: *const Event) bool {
        if (ev.kind != ui.KEY_DOWN) return false;

        if (self.list_apps.handle_event(ev)) {
            ui.write_console("desktop: select app\n");
            return true;
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
        ui.write_console("desktop: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));

    ui.write_console("desktop: open id=4\n");

    // 2. Initial Draw & Present
    app.draw(win);
    ui.win_present(win);
    ui.write_console("desktop: ready\n");
    ui.write_console("desktop: menu ready\n");

    // 3. Event Loop
    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        if (ev.kind == ui.WIN_CLOSE) {
            ui.write_console("desktop: win_close\n");
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
                ui.write_console("desktop: win_close\n");
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

    ui.write_console("desktop: exiting 43\n");
    ui.win_close(win);
    ui.exit_process(exit_status);
}

// ---------------------------------------------------------------------------
// Unit Tests (Class A Host Validation)
// ---------------------------------------------------------------------------

test "desktop: installed application catalog metadata" {
    try std.testing.expectEqual(@as(usize, 6), installed_apps.len);
    try std.testing.expectEqualStrings("CALC.BIN", installed_apps[0].name);
    try std.testing.expectEqualStrings("NOTEPAD.BIN", installed_apps[1].name);
    try std.testing.expectEqualStrings("TOP.BIN", installed_apps[2].name);
    try std.testing.expectEqualStrings("KEYTEST.BIN", installed_apps[3].name);
}
