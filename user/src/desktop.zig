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
pub const window_w: u32 = 512;
pub const window_h: u32 = 384;

pub const exit_status: u32 = 43;

// ---------------------------------------------------------------------------
// App Entry Metadata
// ---------------------------------------------------------------------------

pub const AppEntry = struct {
    name: []const u8,
    desc: []const u8,
    status: []const u8,
    icon: u8 = '?',
    dock: bool = false,
};

/// The built-in catalog — used ONLY as a fallback when `/esp/APPS.TXT` is
/// missing or unreadable (claim 8877). The live launcher reads the manifest
/// from the ESP so adding an app means a manifest line, not a recompile.
pub const installed_apps = [_]AppEntry{
    .{ .name = "CALC.BIN", .desc = "64-bit Calc", .status = "GUI Active", .icon = 'c' },
    .{ .name = "NOTEPAD.BIN", .desc = "Text Editor", .status = "/data Storage", .icon = 'n' },
    .{ .name = "TOP.BIN", .desc = "Task Manager", .status = "sys_procs", .icon = 't' },
    .{ .name = "KEYTEST.BIN", .desc = "HID Input", .status = "USB Events", .icon = 'k' },
    .{ .name = "TYPE.BIN", .desc = "File Reader", .status = "FAT32 Data", .icon = 'f' },
    .{ .name = "DIR.BIN", .desc = "Directory List", .status = "FAT32 ESP", .icon = 'd' },
    .{ .name = "FETCH.BIN", .desc = "HTTP/1.0 Client", .status = "TCP Syscall", .icon = 'w' },
    .{ .name = "CHAT.BIN", .desc = "P2P Net Chat", .status = "UDP Socket", .icon = 'm' },
    .{ .name = "FILE.BIN", .desc = "File Browser", .status = "/data Browse", .icon = 'b' },
};

pub const manifest_max_bytes: usize = 512;
pub const manifest_max_apps: usize = 16;

/// Parse the APPS.TXT manifest text (`NAME.BIN | Display Name | icon-char`
/// per line, `#` comments and blank lines ignored) into `out`, returning
/// the entry count (capped at `out.len`). Entries are slices into `text`,
/// so the caller must keep `text` alive for the entries' lifetime — in the
/// app, `text` is the AppState-owned manifest buffer (stack memory, W^X
/// safe). Pure and host-testable (claim 8877).
pub fn parse_manifest(text: []const u8, out: []AppEntry) usize {
    var count: usize = 0;
    var line_start: usize = 0;
    while (line_start <= text.len and count < out.len) {
        // Find the end of the current line (\n or EOF).
        var line_end = line_start;
        while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
        const line = text[line_start..line_end];

        // Skip blank lines and comments.
        var trimmed_start: usize = 0;
        while (trimmed_start < line.len and (line[trimmed_start] == ' ' or line[trimmed_start] == '\t' or line[trimmed_start] == '\r')) : (trimmed_start += 1) {}
        if (trimmed_start < line.len and line[trimmed_start] != '#') {
            const content = line[trimmed_start..];
            // Split on '|' into up to 4 fields (M15 C4 dock flag).
            var fields: [4][]const u8 = undefined;
            var field_count: usize = 0;
            var field_start: usize = 0;
            var i: usize = 0;
            while (i <= content.len and field_count < 4) : (i += 1) {
                if (i == content.len or content[i] == '|') {
                    fields[field_count] = content[field_start..i];
                    field_count += 1;
                    field_start = i + 1;
                }
            }
            if (field_count >= 2) {
                const name = trim(fields[0]);
                const desc = trim(fields[1]);
                const icon_field = if (field_count >= 3) trim(fields[2]) else "";
                const dock_field = if (field_count >= 4) trim(fields[3]) else "";
                if (name.len > 0 and desc.len > 0) {
                    out[count] = .{
                        .name = name,
                        .desc = desc,
                        .status = "APPS.TXT",
                        .icon = if (icon_field.len > 0) icon_field[0] else '?',
                        .dock = std.mem.eql(u8, dock_field, "dock=true"),
                    };
                    count += 1;
                }
            }
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
    return count;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r')) : (start += 1) {}
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[start..end];
}

// ---------------------------------------------------------------------------
// Hand-rolled string building (claim 8877)
// ---------------------------------------------------------------------------
// std.fmt.bufPrint's outlined runtime-format path corrupts its
// FixedBufferStream state against the 8 KiB EL0 stack (the live gate
// faulted twice: the manifest marker wrote the prefix at stack_top-9, and
// the `P:{d} A:{d}` diag wrote over AppState+0 with pos≈0xE8). The desktop
// therefore never uses bufPrint — every marker/diag string is built with
// these helpers (pure, host-testable, W^X-safe).

/// Copy `src` into `buf` at `pos`, returning the new position. The caller
/// guarantees the slice fits.
fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    @memcpy(buf[pos .. pos + src.len], src);
    return pos + src.len;
}

/// Format `value` as decimal into `buf` (caller provides >= 20 bytes),
/// returning the written slice.
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
// GUI Components & App State (Stack-Allocated AppState)
// ---------------------------------------------------------------------------

pub const AppState = struct {
    btn_calc: Button = Button.init(Rect.make(6, 30, 52, 22), "Calc"),
    btn_notes: Button = Button.init(Rect.make(62, 30, 58, 22), "Notes"),
    btn_top: Button = Button.init(Rect.make(124, 30, 52, 22), "Top"),
    btn_key: Button = Button.init(Rect.make(180, 30, 70, 22), "Keytest"),

    list_apps: ListView = ListView.init(Rect.make(6, 58, 118, 128), 18),
    active_procs_count: usize = 1,

    /// Manifest-owned catalog (claim 8877): `apps` slices point into
    /// `manifest_buf` (stack memory — no writable globals, W^X safe), so the
    /// buffer must outlive the app; it lives in the stack-allocated AppState.
    manifest_buf: [manifest_max_bytes]u8 = undefined,
    apps: [manifest_max_apps]AppEntry = undefined,
    app_count: usize = 0,
    manifest_loaded: bool = false,

    pub noinline fn init() AppState {
        var s = AppState{};
        s.btn_calc.bg_color = ui.COLOR_ACCENT;
        s.btn_notes.bg_color = 0x8b5cf6; // Purple accent
        s.btn_top.bg_color = ui.COLOR_SUCCESS;
        s.btn_key.bg_color = ui.COLOR_WARNING;

        // Default: the built-in catalog (fallback when no manifest).
        s.app_count = installed_apps.len;
        for (installed_apps, 0..) |entry, i| {
            s.apps[i] = entry;
        }
        s.list_apps.item_count = s.app_count;
        s.list_apps.selected_idx = 0;

        // Refresh active procs count
        var raw: [320]u8 = undefined;
        const res = ui.get_procs(&raw);
        if (res > 0) {
            s.active_procs_count = @as(usize, @intCast(res));
        }
        return s;
    }

    /// Load `/esp/APPS.TXT` into the manifest-owned catalog. On any failure
    /// (missing file, read error, empty manifest) the built-in catalog stays
    /// — honest degradation, the desktop always has a launcher list.
    /// Returns the number of apps loaded, or 0 when falling back.
    pub fn load_manifest(self: *AppState) usize {
        const fd = ui.file_open("/esp/APPS.TXT", ui.MODE_READ);
        if (fd < 0) return 0;
        defer ui.file_close(@intCast(fd));
        const n = ui.file_read(@intCast(fd), &self.manifest_buf);
        if (n <= 0) return 0;
        const text = self.manifest_buf[0..@intCast(n)];
        const count = parse_manifest(text, &self.apps);
        if (count == 0) return 0;
        self.app_count = count;
        self.manifest_loaded = true;
        self.list_apps.item_count = count;
        return count;
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
        var diag_len: usize = 0;
        diag_len = append_str(&diag_buf, diag_len, "P:");
        diag_len = append_str(&diag_buf, diag_len, fmt_u64(diag_buf[diag_len..], self.active_procs_count));
        diag_len = append_str(&diag_buf, diag_len, " A:");
        diag_len = append_str(&diag_buf, diag_len, fmt_u64(diag_buf[diag_len..], self.app_count));
        ui.draw_text(win, diag_buf[0..diag_len], 196, 8, ui.COLOR_TEXT_MUTED);

        // 3. Quick Launch Bar
        self.btn_calc.draw(win);
        self.btn_notes.draw(win);
        self.btn_top.draw(win);
        self.btn_key.draw(win);

        // 4. Installed Programs List
        ui.draw_rect(win, self.list_apps.rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, self.list_apps.rect, 1, ui.COLOR_BORDER);
        var i: usize = 0;
        while (i < self.app_count) : (i += 1) {
            const is_sel = if (self.list_apps.selected_idx) |sel| sel == i else false;
            self.list_apps.draw_row(win, i, self.apps[i].name, is_sel);
        }

        // 5. App Details Pane
        const details_rect = Rect.make(128, 58, 122, 128);
        ui.draw_rect(win, details_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, details_rect, 1, ui.COLOR_BORDER);

        const sel_idx = self.list_apps.selected_idx orelse 0;
        if (sel_idx < self.app_count) {
            const app = &self.apps[sel_idx];
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

        const catalog = self.apps[0..self.app_count];
        if (self.btn_calc.handle_event(ev)) {
            self.list_apps.selected_idx = 0;
            changed = launch_app(0, catalog) or changed;
        } else if (self.btn_notes.handle_event(ev)) {
            self.list_apps.selected_idx = 1;
            changed = launch_app(1, catalog) or changed;
        } else if (self.btn_top.handle_event(ev)) {
            self.list_apps.selected_idx = 2;
            changed = launch_app(2, catalog) or changed;
        } else if (self.btn_key.handle_event(ev)) {
            self.list_apps.selected_idx = 3;
            changed = launch_app(3, catalog) or changed;
        } else if (self.list_apps.handle_event(ev)) {
            if (self.list_apps.selected_idx) |sel| {
                if (sel < self.app_count) {
                    ui.write_console("desktop: select app\n");
                }
            }
            changed = true;
        }

        return changed;
    }

    pub fn handle_keyboard_event(self: *AppState, ev: *const Event) bool {
        if (ev.kind != ui.KEY_DOWN) return false;

        // Enter (HID usage 0x28 / '\n'): launch the selected app — the
        // keyboard half of the launcher (claim 6359).
        const ascii_char: u8 = @truncate(ev.arg1);
        if (ev.arg0 == 0x28 or ascii_char == '\n') {
            if (self.list_apps.selected_idx) |sel| {
                if (sel < self.app_count) {
                    return launch_app(sel, self.apps[0..self.app_count]);
                }
            }
            return false;
        }

        if (self.list_apps.handle_event(ev)) {
            ui.write_console("desktop: select app\n");
            return true;
        }

        return false;
    }
};

// ---------------------------------------------------------------------------
// Launcher (Claim 6359: ADR 0007 slot 28 sys_exec)
// ---------------------------------------------------------------------------

/// Launch the app at `index` through the EL0 exec seam — the launcher half
/// of the desktop. Prints a `desktop: launch <NAME> pid=<n>` marker (or the
/// negative error) for the live gate. Never blocks: exec spawns a fresh
/// process into a new slot and returns the pid immediately.
pub fn launch_app(index: usize, catalog: []const AppEntry) bool {
    if (index >= catalog.len) return false;
    const app = &catalog[index];
    const res = ui.exec_program(app.name);
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    pos = append_str(&buf, pos, "desktop: launch ");
    pos = append_str(&buf, pos, app.name);
    if (res >= 0) {
        pos = append_str(&buf, pos, " pid=");
        pos = append_str(&buf, pos, fmt_u64(buf[pos..], @intCast(res)));
    } else {
        pos = append_str(&buf, pos, " err=");
        pos = append_str(&buf, pos, fmt_u64(buf[pos..], @intCast(-res)));
    }
    buf[pos] = '\n';
    ui.write_console(buf[0 .. pos + 1]);
    return true;
}

// ---------------------------------------------------------------------------
// Entry Point (EL0)
// ---------------------------------------------------------------------------

pub export fn _start() callconv(.c) noreturn {
    var app = AppState.init();

    // 1. Load the application manifest (claim 8877). The launcher menu is
    //    built from /esp/APPS.TXT; the built-in catalog is only the fallback.
    const manifest_count = app.load_manifest();
    if (manifest_count > 0) {
        var man_buf: [48]u8 = undefined;
        var man_len: usize = 0;
        man_len = append_str(&man_buf, man_len, "desktop: manifest apps=");
        man_len = append_str(&man_buf, man_len, fmt_u64(man_buf[man_len..], manifest_count));
        man_buf[man_len] = '\n';
        ui.write_console(man_buf[0 .. man_len + 1]);
    } else {
        ui.write_console("desktop: manifest none (built-in catalog)\n");
    }

    // 2. Open Window
    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("desktop: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));

    // Issue #563: print the REAL returned window id (the first free user
    // slot — restored WINDOWS.SAV state or other apps shift it from the
    // naive id=4; a hardcoded marker made the desktop's actual window
    // unobservable in gates).
    var id_buf: [32]u8 = undefined;
    var id_len: usize = 0;
    id_len = append_str(&id_buf, id_len, "desktop: open id=");
    id_len = append_str(&id_buf, id_len, fmt_u64(id_buf[id_len..], win));
    id_buf[id_len] = '\n';
    ui.write_console(id_buf[0 .. id_len + 1]);

    // 2. Initial Draw & Present
    app.draw(win);
    ui.win_present(win);
    ui.write_console("desktop: ready\n");
    ui.write_console("desktop: menu ready\n");

    // 3. Event Loop
    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) {
            var dbg: [40]u8 = undefined;
            var dlen: usize = 0;
            dlen = append_str(&dbg, dlen, "desktop: wait err=");
            dlen = append_str(&dbg, dlen, fmt_u64(dbg[dlen..], @intCast(-wait_rc)));
            dbg[dlen] = '\n';
            ui.write_console(dbg[0 .. dlen + 1]);
            break;
        }

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
    try std.testing.expectEqual(@as(usize, 9), installed_apps.len);
    try std.testing.expectEqualStrings("CALC.BIN", installed_apps[0].name);
    try std.testing.expectEqualStrings("NOTEPAD.BIN", installed_apps[1].name);
    try std.testing.expectEqualStrings("TOP.BIN", installed_apps[2].name);
    try std.testing.expectEqualStrings("KEYTEST.BIN", installed_apps[3].name);
    try std.testing.expectEqualStrings("FETCH.BIN", installed_apps[6].name);
    try std.testing.expectEqualStrings("CHAT.BIN", installed_apps[7].name);
    try std.testing.expectEqualStrings("FILE.BIN", installed_apps[8].name);
}

test "desktop: manifest cap holds the full 9-app catalog incl FILE.BIN (card B4)" {
    try std.testing.expect(manifest_max_apps >= 9);
    // The real APPS.TXT catalog (9 entries) parses end-to-end without
    // truncation — FILE.BIN must be the ninth entry and reachable.
    const text =
        "CALC.BIN | 64-bit Calc | c\n" ++
        "NOTEPAD.BIN | Text Editor | n\n" ++
        "TOP.BIN | Task Manager | t\n" ++
        "KEYTEST.BIN | HID Input | k\n" ++
        "TYPE.BIN | File Reader | f\n" ++
        "DIR.BIN | Directory List | d\n" ++
        "FETCH.BIN | HTTP/1.0 Client | w\n" ++
        "CHAT.BIN | P2P Net Chat | m\n" ++
        "FILE.BIN | File Browser | b";
    var out: [manifest_max_apps]AppEntry = undefined;
    const n = parse_manifest(text, &out);
    try std.testing.expectEqual(@as(usize, 9), n);
    try std.testing.expectEqualStrings("FILE.BIN", out[8].name);
    try std.testing.expectEqualStrings("File Browser", out[8].desc);
    try std.testing.expectEqual(@as(u8, 'b'), out[8].icon);
}

test "desktop: parse_manifest reads NAME | Display | icon lines (claim 8877)" {
    const text =
        "# comment line\n" ++
        "\n" ++
        "CALC.BIN | 64-bit Calc | c\n" ++
        "NOTEPAD.BIN | Text Editor | n\n" ++
        "  TOP.BIN  |  Task Manager  |  t  \n" ++
        "# another comment\n" ++
        "CHAT.BIN | P2P Net Chat | m";
    var out: [manifest_max_apps]AppEntry = undefined;
    const n = parse_manifest(text, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("CALC.BIN", out[0].name);
    try std.testing.expectEqualStrings("64-bit Calc", out[0].desc);
    try std.testing.expectEqual(@as(u8, 'c'), out[0].icon);
    try std.testing.expectEqualStrings("NOTEPAD.BIN", out[1].name);
    try std.testing.expectEqualStrings("Text Editor", out[1].desc);
    try std.testing.expectEqual(@as(u8, 'n'), out[1].icon);
    // Whitespace around fields is trimmed
    try std.testing.expectEqualStrings("TOP.BIN", out[2].name);
    try std.testing.expectEqualStrings("Task Manager", out[2].desc);
    try std.testing.expectEqual(@as(u8, 't'), out[2].icon);
    // Last line has no trailing newline
    try std.testing.expectEqualStrings("CHAT.BIN", out[3].name);
    try std.testing.expectEqual(@as(u8, 'm'), out[3].icon);
}

test "desktop: parse_manifest rejects malformed lines and bounds the count" {
    const text =
        "NO_PIPE_LINE\n" ++
        "| MissingName | x\n" ++
        "NAME.BIN |\n" ++
        "\n" ++
        "OK.BIN | Fine | o\n";
    var out: [manifest_max_apps]AppEntry = undefined;
    const n = parse_manifest(text, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("OK.BIN", out[0].name);
    try std.testing.expectEqualStrings("Fine", out[0].desc);

    // The entry count is capped at out.len.
    var many: [2]AppEntry = undefined;
    const big = "A.BIN | A | a\nB.BIN | B | b\nC.BIN | C | c\n";
    const capped = parse_manifest(big, &many);
    try std.testing.expectEqual(@as(usize, 2), capped);
    try std.testing.expectEqualStrings("A.BIN", many[0].name);
    try std.testing.expectEqualStrings("B.BIN", many[1].name);
}

test "desktop: empty or comment-only manifest yields zero apps" {
    var out: [manifest_max_apps]AppEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), parse_manifest("", &out));
    try std.testing.expectEqual(@as(usize, 0), parse_manifest("# nothing here\n\n", &out));
}

test "desktop: Enter routes the selected list item to launch (claim 6359)" {
    var app = AppState.init();
    // The catalog starts selected at index 0 (CALC.BIN)
    try std.testing.expectEqual(@as(?usize, 0), app.list_apps.selected_idx);

    // Enter (HID usage 0x28, ASCII '\n') with a selection -> launch
    var ev_enter = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x28, .arg1 = '\n' };
    try std.testing.expect(app.handle_keyboard_event(&ev_enter));

    // No selection -> nothing to launch
    app.list_apps.selected_idx = null;
    var ev_enter2 = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x28, .arg1 = '\n' };
    try std.testing.expect(!app.handle_keyboard_event(&ev_enter2));

    // Out-of-range selection -> nothing to launch
    app.list_apps.selected_idx = app.app_count;
    var ev_enter3 = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x28, .arg1 = '\n' };
    try std.testing.expect(!app.handle_keyboard_event(&ev_enter3));

    // Arrow navigation is untouched by the launch path
    app.list_apps.selected_idx = 0;
    var ev_down = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x51, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_down));
    try std.testing.expectEqual(@as(?usize, 1), app.list_apps.selected_idx);
}

test "desktop: AppState fits the 8 KiB EL0 stack (W^X, claim 8877)" {
    try std.testing.expect(@sizeOf(AppState) < 4 * 1024);
    std.debug.print("AppState size: {d}\n", .{@sizeOf(AppState)});
    std.debug.print("manifest_buf off: {d} apps off: {d} app_count off: {d}\n", .{
        @offsetOf(AppState, "manifest_buf"),
        @offsetOf(AppState, "apps"),
        @offsetOf(AppState, "app_count"),
    });
}
