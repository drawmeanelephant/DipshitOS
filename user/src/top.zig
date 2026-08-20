//! DipshitOS sixteenth ESP user program -- TOP.BIN (Milestone 11, Card A4).
//!
//! Graphical Task Manager & Process Monitor. Polls `sys_procs` (slot 7) to
//! inspect active processes, renders live process tables and system statistics,
//! and provides interactive row selection via micro-widgets.
//!
//! Enhanced (Issue #216): CPU usage bars, auto-refresh via app timers,
//! and a process-count sparkline history.

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const Label = ui.Label;
const Event = ui.Event;
const ProcInfo = ui.ProcInfo;
const ProcState = ui.ProcState;

pub const window_id: u32 = 3;
pub const window_x: u32 = 40;
pub const window_y: u32 = 40;
pub const window_w: u32 = 512;
pub const window_h: u32 = 384;

pub const exit_status: u32 = 43;
pub const max_display_procs: usize = 16;
pub const history_len: usize = 48;
pub const auto_refresh_ticks: u64 = 12;

// ---------------------------------------------------------------------------
// Process Table Model
// ---------------------------------------------------------------------------

pub const ProcessTable = struct {
    procs: [max_display_procs]ProcInfo = [_]ProcInfo{.{
        .pid = 0,
        .state = .created,
        .exit_status = 0,
        .name = [_]u8{0} ** 16,
        .name_len = 0,
    }} ** max_display_procs,
    count: usize = 0,
    selected_row: ?usize = null,

    pub fn init() ProcessTable {
        return .{};
    }

    pub fn refresh_from_system(self: *ProcessTable) usize {
        var raw: [640]u8 = undefined;
        const res = ui.get_procs(&raw);
        if (res < 0) {
            self.count = 0;
            return 0;
        }

        const row_count = @as(usize, @intCast(res));
        self.count = ui.parse_procs(&raw, row_count, &self.procs);
        if (self.selected_row) |sel| {
            if (sel >= self.count) {
                self.selected_row = if (self.count > 0) self.count - 1 else null;
            }
        } else {
            self.select_default();
        }
        return self.count;
    }

    pub fn select_default(self: *ProcessTable) void {
        if (self.selected_row != null) return;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.procs[i].state == .running) {
                self.selected_row = i;
                return;
            }
        }
    }

    pub fn count_running(self: *const ProcessTable) usize {
        var running: usize = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.procs[i].state == .running) running += 1;
        }
        return running;
    }

    pub fn select_next(self: *ProcessTable) void {
        if (self.count == 0) return;
        if (self.selected_row) |sel| {
            if (sel + 1 < self.count) self.selected_row = sel + 1;
        } else {
            self.selected_row = 0;
        }
    }

    pub fn select_prev(self: *ProcessTable) void {
        if (self.count == 0) return;
        if (self.selected_row) |sel| {
            if (sel > 0) self.selected_row = sel - 1;
        } else {
            self.selected_row = 0;
        }
    }
};

// ---------------------------------------------------------------------------
// GUI Layout & App State
// ---------------------------------------------------------------------------

fn state_str(state: ProcState) []const u8 {
    return switch (state) {
        .created => "created",
        .running => "running",
        .exited => "exited",
        _ => "unknown",
    };
}

fn state_color(state: ProcState) u32 {
    return switch (state) {
        .running => ui.COLOR_SUCCESS,
        .created => ui.COLOR_WARNING,
        .exited => ui.COLOR_TEXT_MUTED,
        _ => ui.COLOR_TEXT_MUTED,
    };
}

pub const AppState = struct {
    table: ProcessTable = .{},
    btn_refresh: Button = Button.init(Rect.make(6, 6, 60, 20), "Refresh"),
    btn_kill: Button = Button.init(Rect.make(70, 6, 46, 20), "Kill"),
    btn_auto: Button = Button.init(Rect.make(122, 6, 50, 20), "Auto"),
    auto_mode: bool = false,
    proc_history: [history_len]u16 = [_]u16{0} ** history_len,
    history_pos: usize = 0,

    pub fn init() AppState {
        var s = AppState{};
        s.btn_refresh.bg_color = ui.COLOR_ACCENT;
        s.btn_kill.bg_color = ui.COLOR_DANGER;
        _ = s.table.refresh_from_system();
        s.push_history();
        return s;
    }

    fn push_history(self: *AppState) void {
        self.proc_history[self.history_pos] = @intCast(self.table.count);
        self.history_pos = (self.history_pos + 1) % history_len;
    }

    fn draw_cpu_bar(self: *const AppState, win: u32) void {
        const bar_x: u32 = 6;
        const bar_y: u32 = 30;
        const bar_w: u32 = window_w - 12;
        const bar_h: u32 = 14;

        // Background
        ui.draw_rect(win, Rect.make(bar_x, bar_y, bar_w, bar_h), ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, Rect.make(bar_x, bar_y, bar_w, bar_h), 1, ui.COLOR_BORDER);

        const running = self.table.count_running();
        const total = self.table.count;

        if (total > 0) {
            const fill_w = (bar_w - 4) * @as(u32, @intCast(running)) / @as(u32, @intCast(total));
            if (fill_w > 0) {
                ui.draw_rect(win, Rect.make(bar_x + 2, bar_y + 2, fill_w, bar_h - 4), ui.COLOR_SUCCESS);
            }
        }

        // Label
        var buf: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "CPU: {d}/{d}", .{ running, total }) catch "CPU: ?";
        ui.draw_text(win, label, bar_x + 4, bar_y + 3, ui.COLOR_TEXT_PRIMARY);
    }

    fn draw_sparkline(self: *const AppState, win: u32) void {
        const sp_x: u32 = 6;
        const sp_y: u32 = window_h - 40;
        const sp_w: u32 = window_w - 12;
        const sp_h: u32 = 16;

        // Background
        ui.draw_rect(win, Rect.make(sp_x, sp_y, sp_w, sp_h), ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, Rect.make(sp_x, sp_y, sp_w, sp_h), 1, ui.COLOR_BORDER);

        // Find max in history for scaling
        var max_val: u16 = 1;
        var i: usize = 0;
        while (i < history_len) : (i += 1) {
            if (self.proc_history[i] > max_val) {
                max_val = self.proc_history[i];
            }
        }

        // Draw bars (each bar is 2px wide with 1px gap = 3px per sample)
        const bar_w_px: u32 = 2;
        const gap: u32 = 1;
        const step: u32 = bar_w_px + gap;
        var x_off: u32 = 2;
        i = 0;
        while (i < history_len and x_off + bar_w_px <= sp_w - 2) : (i += 1) {
            const idx = (self.history_pos + i) % history_len;
            const val = self.proc_history[idx];
            const h: u32 = if (max_val > 0) @intCast(@as(u32, @intCast(val)) * (sp_h - 4) / @as(u32, @intCast(max_val))) else 0;
            if (h > 0) {
                ui.draw_rect(win, Rect.make(sp_x + x_off, sp_y + sp_h - 2 - h, bar_w_px, h), ui.COLOR_ACCENT);
            }
            x_off += step;
        }

        // Label
        ui.draw_text(win, "History", sp_x + sp_w - 48, sp_y + 3, ui.COLOR_TEXT_MUTED);
    }

    pub fn draw(self: *const AppState, win: u32) void {
        // Window background
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.COLOR_BG);

        // Toolbar
        self.btn_refresh.draw(win);
        self.btn_kill.draw(win);
        self.btn_auto.draw(win);

        // Stats header
        var stats_buf: [40]u8 = undefined;
        const running_cnt = self.table.count_running();
        const stats_str = std.fmt.bufPrint(&stats_buf, "Procs: {d} Run: {d}", .{ self.table.count, running_cnt }) catch "Procs: ?";
        ui.draw_text(win, stats_str, 180, 12, ui.COLOR_TEXT_MUTED);

        // CPU usage bar
        self.draw_cpu_bar(win);

        // Divider line
        ui.draw_rect(win, Rect.make(0, 48, window_w, 1), ui.COLOR_BORDER);

        // Table Header
        const header_rect = Rect.make(6, 52, window_w - 12, 16);
        ui.draw_rect(win, header_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, header_rect, 1, ui.COLOR_BORDER);
        ui.draw_text(win, "PID", header_rect.x + 4, header_rect.y + 4, ui.COLOR_TEXT_MUTED);
        ui.draw_text(win, "NAME", header_rect.x + 32, header_rect.y + 4, ui.COLOR_TEXT_MUTED);
        ui.draw_text(win, "STATE", header_rect.x + 130, header_rect.y + 4, ui.COLOR_TEXT_MUTED);
        ui.draw_text(win, "EXIT", header_rect.x + 196, header_rect.y + 4, ui.COLOR_TEXT_MUTED);

        // Table Rows
        const row_h: u32 = 16;
        var row_y: u32 = 70;
        var i: usize = 0;
        while (i < self.table.count and row_y + row_h <= window_h - 44) : (i += 1) {
            const proc = &self.table.procs[i];
            const is_selected = if (self.table.selected_row) |sel| sel == i else false;
            const row_rect = Rect.make(6, row_y, window_w - 12, row_h);

            // Row background
            if (is_selected) {
                ui.draw_rect(win, row_rect, ui.COLOR_BTN_HOVER);
                ui.draw_rect_outline(win, row_rect, 1, ui.COLOR_ACCENT);
            } else if (i % 2 == 1) {
                ui.draw_rect(win, row_rect, 0x1e293b);
            }

            // PID
            var pid_buf: [8]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{proc.pid}) catch "?";
            ui.draw_text(win, pid_str, row_rect.x + 4, row_y + 4, ui.COLOR_TEXT_PRIMARY);

            // Name
            const name_slice = if (proc.name_len > 0) proc.name[0..proc.name_len] else "unknown";
            ui.draw_text(win, name_slice, row_rect.x + 32, row_y + 4, ui.COLOR_TEXT_PRIMARY);

            // State
            ui.draw_text(win, state_str(proc.state), row_rect.x + 130, row_y + 4, state_color(proc.state));

            // Exit status
            if (proc.state == .exited) {
                var exit_buf: [8]u8 = undefined;
                const exit_str = std.fmt.bufPrint(&exit_buf, "{d}", .{proc.exit_status}) catch "?";
                ui.draw_text(win, exit_str, row_rect.x + 196, row_y + 4, ui.COLOR_TEXT_MUTED);
            } else {
                ui.draw_text(win, "-", row_rect.x + 196, row_y + 4, ui.COLOR_TEXT_MUTED);
            }

            row_y += row_h;
        }

        // Sparkline at bottom
        self.draw_sparkline(win);
    }

    pub fn toggle_auto_refresh(self: *AppState) void {
        self.auto_mode = !self.auto_mode;
        if (self.auto_mode) {
            _ = ui.timer_set(auto_refresh_ticks);
            self.btn_auto.label = "Stop";
            self.btn_auto.bg_color = ui.COLOR_DANGER;
        } else {
            _ = ui.timer_cancel();
            self.btn_auto.label = "Auto";
            self.btn_auto.bg_color = ui.COLOR_WARNING;
        }
    }

    pub fn handle_mouse_events(self: *AppState, ev: *const Event) bool {
        var changed = false;

        if (self.btn_refresh.handle_event(ev)) {
            _ = self.table.refresh_from_system();
            self.push_history();
            ui.write_console("top: refreshed ok\n");
            changed = true;
        } else if (self.btn_kill.handle_event(ev)) {
            if (self.table.selected_row) |sel| {
                changed = self.kill_selected(sel) or changed;
            }
        } else if (self.btn_auto.handle_event(ev)) {
            self.toggle_auto_refresh();
            changed = true;
        } else if (ev.kind == ui.MOUSE_DOWN and (ev.flags & ui.BTN_LEFT) != 0) {
            const click_x = ev.arg0;
            const click_y = ev.arg1;
            if (click_x >= 6 and click_x < window_w - 6 and click_y >= 70) {
                const row_idx = (click_y - 70) / 16;
                if (row_idx < self.table.count) {
                    self.table.selected_row = row_idx;
                    changed = true;
                }
            }
        }

        return changed;
    }

    pub fn handle_keyboard_event(self: *AppState, ev: *const Event) bool {
        if (ev.kind != ui.KEY_DOWN) return false;
        const keycode = ev.arg0;

        // Up arrow
        if (keycode == 0x52) {
            self.table.select_prev();
            return true;
        }

        // Down arrow
        if (keycode == 0x51) {
            self.table.select_next();
            return true;
        }

        // 'r' or 'R' -> Refresh
        if (ev.arg1 == 'r' or ev.arg1 == 'R') {
            _ = self.table.refresh_from_system();
            self.push_history();
            ui.write_console("top: refreshed ok\n");
            return true;
        }

        // 'k' or 'K' -> kill the selected process
        if (ev.arg1 == 'k' or ev.arg1 == 'K') {
            if (self.table.selected_row) |sel| {
                return self.kill_selected(sel);
            }
            return false;
        }

        // 'a' or 'A' -> toggle auto-refresh
        if (ev.arg1 == 'a' or ev.arg1 == 'A') {
            self.toggle_auto_refresh();
            return true;
        }

        return false;
    }

    pub fn handle_timer(self: *AppState) bool {
        _ = self.table.refresh_from_system();
        self.push_history();
        // Re-arm timer if still in auto mode
        if (self.auto_mode) {
            _ = ui.timer_set(auto_refresh_ticks);
        }
        return true;
    }

    pub fn kill_selected(self: *AppState, row: usize) bool {
        if (row >= self.table.count) return false;
        const proc = &self.table.procs[row];
        const res = ui.kill_process(proc.pid);
        var buf: [48]u8 = undefined;
        if (res == 0) {
            const msg = std.fmt.bufPrint(&buf, "top: kill pid={d}\n", .{proc.pid}) catch "top: kill\n";
            ui.write_console(msg);
            _ = self.table.refresh_from_system();
            self.push_history();
        } else {
            const msg = std.fmt.bufPrint(&buf, "top: kill pid={d} err={d}\n", .{ proc.pid, res }) catch "top: kill err\n";
            ui.write_console(msg);
        }
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
        ui.write_console("top: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));

    ui.write_console("top: open id=3\n");

    // 2. Initial Draw & Present
    app.draw(win);
    ui.win_present(win);
    ui.write_console("top: ready\n");

    // 3. Event Loop
    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        if (ev.kind == ui.WIN_CLOSE) {
            ui.write_console("top: win_close\n");
            break;
        }

        if (ev.kind == ui.EVENT_TIMER) {
            dirty = app.handle_timer();
        } else if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
            dirty = app.handle_mouse_events(&ev) or dirty;
        } else if (ev.kind == ui.KEY_DOWN) {
            dirty = app.handle_keyboard_event(&ev) or dirty;
        }

        // Drain pending queue
        while (ui.poll_event(&ev) > 0) {
            if (ev.kind == ui.WIN_CLOSE) {
                ui.write_console("top: win_close\n");
                ui.win_close(win);
                ui.exit_process(exit_status);
            }
            if (ev.kind == ui.EVENT_TIMER) {
                dirty = app.handle_timer();
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

    // Cancel timer before exiting
    if (app.auto_mode) {
        _ = ui.timer_cancel();
    }

    ui.write_console("top: exiting 43\n");
    ui.win_close(win);
    ui.exit_process(exit_status);
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "top: ProcessTable selection navigation and stats" {
    var pt = ProcessTable.init();
    pt.count = 3;
    pt.procs[0] = .{ .pid = 0, .state = .exited, .exit_status = 7, .name = "user-el0\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 8 };
    pt.procs[1] = .{ .pid = 1, .state = .running, .exit_status = 0, .name = "KERNEL.BIN\x00\x00\x00\x00\x00\x00".*, .name_len = 10 };
    pt.procs[2] = .{ .pid = 2, .state = .running, .exit_status = 0, .name = "TOP.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 7 };

    try std.testing.expectEqual(@as(usize, 2), pt.count_running());

    try std.testing.expectEqual(@as(?usize, null), pt.selected_row);
    pt.select_next();
    try std.testing.expectEqual(@as(?usize, 0), pt.selected_row);
    pt.select_next();
    try std.testing.expectEqual(@as(?usize, 1), pt.selected_row);
    pt.select_next();
    try std.testing.expectEqual(@as(?usize, 2), pt.selected_row);
    pt.select_next();
    try std.testing.expectEqual(@as(?usize, 2), pt.selected_row);

    pt.select_prev();
    try std.testing.expectEqual(@as(?usize, 1), pt.selected_row);
}

test "top: ProcessTable auto-selects the first running process" {
    var pt = ProcessTable.init();
    pt.count = 3;
    pt.procs[0] = .{ .pid = 0, .state = .exited, .exit_status = 7, .name = "user-el0\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 8 };
    pt.procs[1] = .{ .pid = 1, .state = .running, .exit_status = 0, .name = "COUNTER.BIN\x00\x00\x00\x00\x00".*, .name_len = 11 };
    pt.procs[2] = .{ .pid = 2, .state = .running, .exit_status = 0, .name = "TOP.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 7 };

    pt.select_default();
    try std.testing.expectEqual(@as(?usize, 1), pt.selected_row);

    pt.selected_row = 2;
    pt.select_default();
    try std.testing.expectEqual(@as(?usize, 2), pt.selected_row);

    var pt2 = ProcessTable.init();
    pt2.count = 1;
    pt2.procs[0] = .{ .pid = 0, .state = .exited, .exit_status = 7, .name = "user-el0\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 8 };
    pt2.select_default();
    try std.testing.expectEqual(@as(?usize, null), pt2.selected_row);
}

test "top: kill_selected and the 'k' key route to the selected pid" {
    var app = AppState.init();
    app.table.count = 2;
    app.table.procs[0] = .{ .pid = 0, .state = .exited, .exit_status = 7, .name = "user-el0\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 8 };
    app.table.procs[1] = .{ .pid = 1, .state = .running, .exit_status = 0, .name = "COUNTER.BIN\x00\x00\x00\x00\x00".*, .name_len = 11 };
    app.table.selected_row = 1;

    var ev_k = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x2e, .arg1 = 'k' };
    try std.testing.expect(app.handle_keyboard_event(&ev_k));

    app.table.selected_row = null;
    try std.testing.expect(!app.handle_keyboard_event(&ev_k));

    try std.testing.expect(!app.kill_selected(99));
}

test "top: history ring buffer wraps correctly" {
    var app = AppState.init();
    app.table.count = 5;
    _ = app.table.count_running();
    // Fill the history buffer
    var i: usize = 0;
    while (i < history_len + 5) : (i += 1) {
        app.table.count = @intCast(i % 10);
        app.push_history();
    }
    // Position should have wrapped around
    try std.testing.expect(app.history_pos < history_len);
    // All slots should have been written (non-zero after first write)
    try std.testing.expect(app.proc_history[0] != 0 or app.proc_history[1] != 0);
}

test "top: auto toggle arms and disarms timer" {
    var app = AppState.init();
    try std.testing.expect(!app.auto_mode);

    app.toggle_auto_refresh();
    try std.testing.expect(app.auto_mode);
    try std.testing.expectEqual(@as([]const u8, "Stop"), app.btn_auto.label);

    app.toggle_auto_refresh();
    try std.testing.expect(!app.auto_mode);
    try std.testing.expectEqual(@as([]const u8, "Auto"), app.btn_auto.label);
}
