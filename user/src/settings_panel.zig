//! DipshitOS thirtieth ESP user program -- SETTINGS.BIN (Issue #214).
//!
//! GUI settings panel. Reads current settings from `/data/SETTINGS.TXT`
//! via the M10 file seam, displays them in labeled TextInput widgets,
//! and writes them back on Save. Uses zero heap allocation.

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const TextInput = ui.TextInput;
const DropDown = ui.DropDown;
const Event = ui.Event;

pub const window_id: u32 = 6;
pub const window_x: u32 = 80;
pub const window_y: u32 = 40;
pub const window_w: u32 = 512;
pub const window_h: u32 = 384;
pub const exit_status: u32 = 43;
pub const settings_path: []const u8 = "/data/SETTINGS.TXT";

// Layout constants.
pub const row_y0: u32 = 40;
pub const row_h: u32 = 32;
pub const label_x: u32 = 16;
pub const input_x: u32 = 120;
pub const input_w: u32 = 340;
pub const input_h: u32 = 22;

// Theme options for the dropdown.
pub const theme_options = [_][]const u8{ "dark", "light", "amber" };

// Hand-rolled string helpers (W^X-safe).
fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Settings parsing from SETTINGS.TXT content
// ---------------------------------------------------------------------------

const max_value: usize = 64;

pub const Settings = struct {
    hostname: [max_value]u8 = [_]u8{0} ** max_value,
    hostname_len: usize = 0,
    theme: [max_value]u8 = [_]u8{0} ** max_value,
    theme_len: usize = 0,
    prompt: [max_value]u8 = [_]u8{0} ** max_value,
    prompt_len: usize = 0,

    pub fn init() Settings {
        return .{};
    }

    pub fn parse_line(self: *Settings, line: []const u8) void {
        var i: usize = 0;
        while (i < line.len and line[i] != '=') : (i += 1) {}
        if (i >= line.len) return;
        const key = line[0..i];
        const val = if (i + 1 < line.len) line[i + 1 ..] else &[_]u8{};
        const trimmed = trim(val);
        if (eql(key, "hostname")) {
            self.hostname_len = @min(trimmed.len, max_value);
            @memcpy(self.hostname[0..self.hostname_len], trimmed[0..self.hostname_len]);
        } else if (eql(key, "theme")) {
            self.theme_len = @min(trimmed.len, max_value);
            @memcpy(self.theme[0..self.theme_len], trimmed[0..self.theme_len]);
        } else if (eql(key, "prompt")) {
            self.prompt_len = @min(trimmed.len, max_value);
            @memcpy(self.prompt[0..self.prompt_len], trimmed[0..self.prompt_len]);
        }
    }

    fn trim(s: []const u8) []const u8 {
        var start: usize = 0;
        while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
        var end: usize = s.len;
        while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1) {}
        return s[start..end];
    }
};

// ---------------------------------------------------------------------------
// File I/O helpers
// ---------------------------------------------------------------------------

fn read_settings_file(buf: []u8) usize {
    const fd = ui.file_open(settings_path, ui.MODE_READ);
    if (fd < 0) return 0;
    const handle = @as(u32, @intCast(fd));
    const n = ui.file_read(handle, buf);
    ui.file_close(handle);
    if (n < 0) return 0;
    return @as(usize, @intCast(n));
}

fn write_settings_file(content: []const u8) bool {
    const fd_trunc = ui.file_open(settings_path, ui.MODE_WRITE);
    if (fd_trunc >= 0) {
        _ = ui.file_truncate(@as(u32, @intCast(fd_trunc)), 0);
        ui.file_close(@as(u32, @intCast(fd_trunc)));
    }
    const fd = ui.file_open(settings_path, ui.MODE_WRITE | ui.MODE_CREATE);
    if (fd < 0) return false;
    const handle = @as(u32, @intCast(fd));
    const n = ui.file_write(handle, content);
    ui.file_close(handle);
    return n >= 0;
}

// ---------------------------------------------------------------------------
// App State
// ---------------------------------------------------------------------------

pub const AppState = struct {
    settings: Settings = Settings.init(),

    input_hostname: TextInput,
    dropdown_theme: DropDown,
    input_prompt: TextInput,

    btn_save: Button,
    btn_reset: Button,
    btn_defaults: Button,
    btn_wizard: Button,

    // M27 G2: First-boot wizard mode & steps (1..3)
    wizard_mode: bool = false,
    wizard_step: u8 = 1,
    btn_wizard_back: Button,
    btn_wizard_next: Button,
    btn_wizard_finish: Button,
    btn_wizard_skip: Button,

    // C10 live preview: in-memory last_saved_theme for Reset and same-frame preview.
    last_saved_theme: [max_value]u8 = [_]u8{0} ** max_value,
    last_saved_theme_len: usize = 0,

    status_msg: [32]u8 = [_]u8{0} ** 32,
    status_len: usize = 0,

    pub fn init() AppState {
        return .{
            .input_hostname = TextInput.init(Rect.make(input_x, row_y0, input_w, input_h)),
            .dropdown_theme = DropDown.init(Rect.make(input_x, row_y0 + row_h, input_w, input_h), &theme_options),
            .input_prompt = TextInput.init(Rect.make(input_x, row_y0 + row_h * 2, input_w, input_h)),
            .btn_save = Button.init(Rect.make(16, row_y0 + row_h * 3 + 16, 70, 24), "Save"),
            .btn_reset = Button.init(Rect.make(96, row_y0 + row_h * 3 + 16, 70, 24), "Reset"),
            .btn_defaults = Button.init(Rect.make(176, row_y0 + row_h * 3 + 16, 85, 24), "Defaults"),
            .btn_wizard = Button.init(Rect.make(271, row_y0 + row_h * 3 + 16, 75, 24), "Wizard"),
            .btn_wizard_back = Button.init(Rect.make(input_x, row_y0 + row_h * 3 + 16, 75, 24), "< Back"),
            .btn_wizard_next = Button.init(Rect.make(input_x + 90, row_y0 + row_h * 3 + 16, 75, 24), "Next >"),
            .btn_wizard_finish = Button.init(Rect.make(input_x + 90, row_y0 + row_h * 3 + 16, 75, 24), "Finish"),
            .btn_wizard_skip = Button.init(Rect.make(16, row_y0 + row_h * 3 + 16, 65, 24), "Skip"),
        };
    }

    pub fn load(self: *AppState) void {
        var buf: [2048]u8 = undefined;
        const n = read_settings_file(&buf);
        if (n == 0) {
            self.set_status("First boot setup");
            self.wizard_mode = true;
            self.wizard_step = 1;
            // Set sane defaults
            self.input_hostname.set_text("dipshitos");
            self.dropdown_theme.set_selected_by_name("dark");
            self.input_prompt.set_text("$ ");
            if (self.last_saved_theme_len == 0) {
                const def = "dark";
                @memcpy(self.last_saved_theme[0..def.len], def);
                self.last_saved_theme_len = def.len;
            }
            _ = ui.set_theme(self.last_saved_theme[0..self.last_saved_theme_len]);
            return;
        }
        var line_start: usize = 0;
        var i: usize = 0;
        while (i <= n) : (i += 1) {
            if (i == n or buf[i] == '\n') {
                if (i > line_start) {
                    self.settings.parse_line(buf[line_start..i]);
                }
                line_start = i + 1;
            }
        }
        self.input_hostname.set_text(self.settings.hostname[0..self.settings.hostname_len]);
        self.dropdown_theme.set_selected_by_name(self.settings.theme[0..self.settings.theme_len]);
        self.input_prompt.set_text(self.settings.prompt[0..self.settings.prompt_len]);
        // C10: cache last_saved_theme and apply live preview via ui.set_theme (EL0 palette).
        self.last_saved_theme_len = self.settings.theme_len;
        if (self.last_saved_theme_len > 0) {
            @memcpy(self.last_saved_theme[0..self.last_saved_theme_len], self.settings.theme[0..self.settings.theme_len]);
            _ = ui.set_theme(self.last_saved_theme[0..self.last_saved_theme_len]);
        } else {
            const def = "dark";
            @memcpy(self.last_saved_theme[0..def.len], def);
            self.last_saved_theme_len = def.len;
            _ = ui.set_theme(def);
        }
        self.set_status("Loaded");
    }

    pub fn reset_defaults(self: *AppState) void {
        self.input_hostname.set_text("dipshitos");
        self.dropdown_theme.set_selected_by_name("dark");
        self.input_prompt.set_text("$ ");
        _ = ui.set_theme("dark");
        self.save();
        self.set_status("Defaults restored");
    }

    pub fn save(self: *AppState) void {
        var buf: [512]u8 = undefined;
        var pos: usize = 0;
        pos = append_pair(&buf, pos, "hostname", self.input_hostname.get_text());
        pos = append_pair(&buf, pos, "theme", self.dropdown_theme.selected_text());
        pos = append_pair(&buf, pos, "prompt", self.input_prompt.get_text());
        if (write_settings_file(buf[0..pos])) {
            // C10: Save persists and updates last_saved_theme so Reset reverts to the just-saved value.
            const sel = self.dropdown_theme.selected_text();
            self.last_saved_theme_len = @min(sel.len, max_value);
            @memcpy(self.last_saved_theme[0..self.last_saved_theme_len], sel[0..self.last_saved_theme_len]);
            _ = ui.set_theme(sel);
            self.set_status("Saved OK");
        } else {
            self.set_status("Save failed");
        }
    }

    fn append_pair(buf: []u8, pos: usize, key: []const u8, val: []const u8) usize {
        var p = pos;
        if (p + key.len + 1 + val.len + 1 > buf.len) return p;
        @memcpy(buf[p..][0..key.len], key);
        p += key.len;
        buf[p] = '=';
        p += 1;
        @memcpy(buf[p..][0..val.len], val);
        p += val.len;
        buf[p] = '\n';
        p += 1;
        return p;
    }

    fn set_status(self: *AppState, msg: []const u8) void {
        const n = @min(msg.len, self.status_msg.len);
        @memcpy(self.status_msg[0..n], msg[0..n]);
        self.status_len = n;
    }

    pub fn handle_mouse(self: *AppState, ev: *const Event) bool {
        if (self.wizard_mode) {
            if (self.btn_wizard_skip.handle_event(ev)) {
                self.wizard_mode = false;
                self.reset_defaults();
                return true;
            }
            if (self.wizard_step > 1 and self.btn_wizard_back.handle_event(ev)) {
                self.wizard_step -= 1;
                return true;
            }
            if (self.wizard_step < 3 and self.btn_wizard_next.handle_event(ev)) {
                self.wizard_step += 1;
                return true;
            }
            if (self.wizard_step == 3 and self.btn_wizard_finish.handle_event(ev)) {
                self.wizard_mode = false;
                self.save();
                return true;
            }
            if (self.wizard_step == 1) {
                return self.input_hostname.handle_event(ev);
            } else if (self.wizard_step == 2) {
                const old_sel = self.dropdown_theme.selected;
                const dd_handled = self.dropdown_theme.handle_event(ev);
                if (old_sel != self.dropdown_theme.selected) {
                    _ = ui.set_theme(self.dropdown_theme.selected_text());
                    return true;
                }
                return dd_handled;
            } else if (self.wizard_step == 3) {
                return self.input_prompt.handle_event(ev);
            }
            return false;
        }

        if (self.btn_save.handle_event(ev)) {
            self.save();
            return true;
        }
        if (self.btn_reset.handle_event(ev)) {
            if (self.last_saved_theme_len > 0) {
                self.dropdown_theme.set_selected_by_name(self.last_saved_theme[0..self.last_saved_theme_len]);
                _ = ui.set_theme(self.last_saved_theme[0..self.last_saved_theme_len]);
            }
            self.load();
            return true;
        }
        if (self.btn_defaults.handle_event(ev)) {
            self.reset_defaults();
            return true;
        }
        if (self.btn_wizard.handle_event(ev)) {
            self.wizard_mode = true;
            self.wizard_step = 1;
            return true;
        }
        _ = self.input_hostname.handle_event(ev);
        const old_sel = self.dropdown_theme.selected;
        const old_open = self.dropdown_theme.open;
        const dd_handled = self.dropdown_theme.handle_event(ev);
        const sel_changed = old_sel != self.dropdown_theme.selected;
        const open_changed = old_open != self.dropdown_theme.open;
        if (sel_changed) {
            _ = ui.set_theme(self.dropdown_theme.selected_text());
            return true;
        }
        if (open_changed) return true;
        if (dd_handled) return true;
        _ = self.input_prompt.handle_event(ev);
        return true;
    }

    pub fn handle_key(self: *AppState, ev: *const Event) bool {
        if (self.wizard_mode) {
            if (self.wizard_step == 1) return self.input_hostname.handle_event(ev);
            if (self.wizard_step == 2) {
                const old_sel = self.dropdown_theme.selected;
                const dd_h = self.dropdown_theme.handle_event(ev);
                if (old_sel != self.dropdown_theme.selected) {
                    _ = ui.set_theme(self.dropdown_theme.selected_text());
                    return true;
                }
                return dd_h;
            }
            if (self.wizard_step == 3) return self.input_prompt.handle_event(ev);
            return false;
        }
        if (self.input_hostname.handle_event(ev)) return true;
        const old_sel = self.dropdown_theme.selected;
        const old_open = self.dropdown_theme.open;
        const dd_handled = self.dropdown_theme.handle_event(ev);
        const sel_changed = old_sel != self.dropdown_theme.selected;
        const open_changed = old_open != self.dropdown_theme.open;
        if (sel_changed) {
            _ = ui.set_theme(self.dropdown_theme.selected_text());
            return true;
        }
        if (open_changed) return true;
        if (dd_handled) return true;
        if (self.input_prompt.handle_event(ev)) return true;
        return false;
    }

    pub fn draw(self: *const AppState, win: u32) void {
        // Background.
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.theme_bg());

        // Title bar.
        ui.draw_rect(win, Rect.make(0, 0, window_w, 28), ui.theme_surface());
        ui.draw_rect_outline(win, Rect.make(0, 0, window_w, 28), 1, ui.theme_border());

        if (self.wizard_mode) {
            ui.draw_text_large(win, "Setup Wizard", 16, 6, ui.theme_text_primary());
            var step_hdr: [32]u8 = undefined;
            const step_txt = std.fmt.bufPrint(&step_hdr, "Step {d} of 3", .{self.wizard_step}) catch "Step 1/3";
            ui.draw_text(win, step_txt, window_w - 100, 8, ui.theme_accent());

            if (self.wizard_step == 1) {
                ui.draw_text(win, "Welcome! Set your system hostname:", label_x, row_y0 - 8, ui.theme_text_primary());
                ui.draw_text(win, "Hostname:", label_x, row_y0 + 16 + 7, ui.theme_text_muted());
                var in_h = self.input_hostname;
                in_h.rect = Rect.make(input_x, row_y0 + 16, input_w, input_h);
                in_h.draw(win);
            } else if (self.wizard_step == 2) {
                ui.draw_text(win, "Choose your color theme (live preview):", label_x, row_y0 - 8, ui.theme_text_primary());
                ui.draw_text(win, "Theme:", label_x, row_y0 + 16 + 7, ui.theme_text_muted());
                var dd_t = self.dropdown_theme;
                dd_t.rect = Rect.make(input_x, row_y0 + 16, input_w, input_h);
                dd_t.draw(win);
            } else if (self.wizard_step == 3) {
                ui.draw_text(win, "Configure your shell command prompt:", label_x, row_y0 - 8, ui.theme_text_primary());
                ui.draw_text(win, "Prompt:", label_x, row_y0 + 16 + 7, ui.theme_text_muted());
                var in_p = self.input_prompt;
                in_p.rect = Rect.make(input_x, row_y0 + 16, input_w, input_h);
                in_p.draw(win);
            }

            self.btn_wizard_skip.draw(win);
            if (self.wizard_step > 1) self.btn_wizard_back.draw(win);
            if (self.wizard_step < 3) self.btn_wizard_next.draw(win) else self.btn_wizard_finish.draw(win);
        } else {
            ui.draw_text_large(win, "Settings", 16, 6, ui.theme_text_primary());

            // Labels.
            ui.draw_text(win, "Hostname:", label_x, row_y0 + 7, ui.theme_text_muted());
            ui.draw_text(win, "Theme:", label_x, row_y0 + row_h + 7, ui.theme_text_muted());
            ui.draw_text(win, "Prompt:", label_x, row_y0 + row_h * 2 + 7, ui.theme_text_muted());

            // Input fields.
            self.input_hostname.draw(win);
            self.dropdown_theme.draw(win);
            self.input_prompt.draw(win);

            // Buttons.
            self.btn_save.draw(win);
            self.btn_reset.draw(win);
            self.btn_defaults.draw(win);
            self.btn_wizard.draw(win);
        }

        // Status bar.
        ui.draw_rect(win, Rect.make(0, window_h - 20, window_w, 20), ui.theme_surface());
        if (self.status_len > 0) {
            ui.draw_text(win, self.status_msg[0..self.status_len], 8, window_h - 16, ui.theme_text_muted());
        }
    }
};

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub export fn _start() callconv(.c) noreturn {
    var app = AppState.init();

    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("settings: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));
    ui.write_console("settings: open id=6\n");

    app.load();
    app.draw(win);
    ui.win_present(win);
    ui.write_console("settings: ready\n");

    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        if (ev.kind == ui.WIN_CLOSE) {
            ui.write_console("settings: close\n");
            break;
        }

        if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
            dirty = app.handle_mouse(&ev) or dirty;
        } else if (ev.kind == ui.KEY_DOWN) {
            dirty = app.handle_key(&ev) or dirty;
        }

        while (ui.poll_event(&ev) > 0) {
            if (ev.kind == ui.WIN_CLOSE) {
                ui.write_console("settings: close\n");
                ui.win_close(win);
                ui.exit_process(exit_status);
            }
            if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
                dirty = app.handle_mouse(&ev) or dirty;
            } else if (ev.kind == ui.KEY_DOWN) {
                dirty = app.handle_key(&ev) or dirty;
            }
        }

        if (dirty) {
            app.draw(win);
            ui.win_present(win);
        }
    }

    ui.write_console("settings: exiting\n");
    ui.win_close(win);
    ui.exit_process(exit_status);
}

test "settings: AppState wizard flow and reset_defaults" {
    var app = AppState.init();
    app.wizard_mode = true;
    app.wizard_step = 1;

    // Next step in wizard (MOUSE_DOWN + MOUSE_UP)
    const btn_next_rect = app.btn_wizard_next.rect;
    var ev_down_next = Event{
        .kind = ui.MOUSE_DOWN,
        .flags = ui.BTN_LEFT,
        .seq = 1,
        .arg0 = btn_next_rect.x + 2,
        .arg1 = btn_next_rect.y + 2,
    };
    _ = app.handle_mouse(&ev_down_next);
    var ev_up_next = Event{
        .kind = ui.MOUSE_UP,
        .flags = ui.BTN_LEFT,
        .seq = 2,
        .arg0 = btn_next_rect.x + 2,
        .arg1 = btn_next_rect.y + 2,
    };
    _ = app.handle_mouse(&ev_up_next);
    try std.testing.expectEqual(@as(u8, 2), app.wizard_step);

    // Back step (MOUSE_DOWN + MOUSE_UP)
    const btn_back_rect = app.btn_wizard_back.rect;
    var ev_down_back = Event{
        .kind = ui.MOUSE_DOWN,
        .flags = ui.BTN_LEFT,
        .seq = 3,
        .arg0 = btn_back_rect.x + 2,
        .arg1 = btn_back_rect.y + 2,
    };
    _ = app.handle_mouse(&ev_down_back);
    var ev_up_back = Event{
        .kind = ui.MOUSE_UP,
        .flags = ui.BTN_LEFT,
        .seq = 4,
        .arg0 = btn_back_rect.x + 2,
        .arg1 = btn_back_rect.y + 2,
    };
    _ = app.handle_mouse(&ev_up_back);
    try std.testing.expectEqual(@as(u8, 1), app.wizard_step);

    // Reset defaults
    app.reset_defaults();
    try std.testing.expectEqualStrings("dipshitos", app.input_hostname.get_text());
    try std.testing.expectEqualStrings("dark", app.dropdown_theme.selected_text());
    try std.testing.expectEqualStrings("$ ", app.input_prompt.get_text());
}

