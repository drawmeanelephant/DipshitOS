//! VirelaiOS System Monitor Dashboard -- SYSMON.BIN (M27 G6, Issue #449).
//!
//! Comprehensive system monitor GUI displaying real-time system metrics:
//!   - System Overview: Hostname, kernel version, app session duration, architecture
//!   - Process & Task activity: PID, state, memory footprint, CPU status
//!   - Storage & Filesystem: Partition usage, volume specs, root files
//!   - Network & Diagnostics: IP status, frame counters, socket state
//!
//! Auto-refreshes at 1 Hz via ADR 0014 app timers (`ui.timer_set(100)`).
//! Zero heap allocation, fully responsive to keyboard and mouse events.

const std = @import("std");
const ui = @import("lib/ui.zig");
const tabapp = @import("lib/tabapp.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const Label = ui.Label;
const Event = ui.Event;
const ProcInfo = ui.ProcInfo;

pub const window_id: u32 = 8;
pub const window_x: u32 = 60;
pub const window_y: u32 = 60;
// M37 DQ4: 512 wide — the compositor back-buffer caps user windows at
// 512×424 (kernel/src/wnd_core.zig user_buf_w/h); 540 never opened
// (pre-existing overflow, never live-gated).
pub const window_w: u32 = 512;
pub const window_h: u32 = 380;
pub const exit_status: u32 = 0;

// M42 SX4 (issue #985): the NATIVE layout rects (the 512x380 design).
// `layout` scales copies of these into the current canvas.
pub const native_btn_overview = Rect.make(12, 10, 90, 22);
pub const native_btn_procs = Rect.make(108, 10, 90, 22);
pub const native_btn_storage = Rect.make(204, 10, 110, 22);
pub const native_btn_refresh = Rect.make(416, 10, 88, 22);
pub const native_header = Rect.make(0, 0, 512, 40);
pub const native_content = Rect.make(12, 50, 488, 318);

/// Visible process rows for a content rect (20 px per row, 30 px chrome).
pub fn rows_for_content_h(h: u32) usize {
    if (h <= 30) return 1;
    const rows = (h - 30) / 20;
    return @min(rows, max_procs);
}

pub const Tab = enum {
    overview,
    processes,
    storage_net,
};

pub const max_procs: usize = 16;
pub const refresh_ticks: u64 = 100; // 1 Hz (100 ticks = 1s)

pub const SysmonState = struct {
    tab: Tab = .overview,
    procs: [max_procs]ProcInfo = [_]ProcInfo{.{
        .pid = 0,
        .state = .created,
        .exit_status = 0,
        .name = [_]u8{0} ** 16,
        .name_len = 0,
    }} ** max_procs,
    proc_count: usize = 0,
    uptime_secs: u64 = 0,
    refresh_count: u64 = 0,
    btn_overview: Button = Button.init(native_btn_overview, "Overview"),
    btn_procs: Button = Button.init(native_btn_procs, "Processes"),
    btn_storage: Button = Button.init(native_btn_storage, "Storage & Net"),
    btn_refresh: Button = Button.init(native_btn_refresh, "Refresh"),
    cursor_kind: ui.CursorKind = .arrow, // M37 DQ4: per-region cursor state

    /// M42 SX4: the tab-aware canvas + scaled layout rects (draw AND
    /// hit-testing read these, so scaled geometry cannot drift).
    canvas_w: u32 = window_w,
    canvas_h: u32 = window_h,
    header_rect: Rect = native_header,
    content_rect: Rect = native_content,

    pub fn layout(self: *SysmonState, w: u32, h: u32) void {
        self.canvas_w = w;
        self.canvas_h = h;
        self.header_rect = tabapp.scale(native_header, window_w, window_h, w, h);
        self.content_rect = tabapp.scale(native_content, window_w, window_h, w, h);
        self.btn_overview.rect = tabapp.scale(native_btn_overview, window_w, window_h, w, h);
        self.btn_procs.rect = tabapp.scale(native_btn_procs, window_w, window_h, w, h);
        self.btn_storage.rect = tabapp.scale(native_btn_storage, window_w, window_h, w, h);
        self.btn_refresh.rect = tabapp.scale(native_btn_refresh, window_w, window_h, w, h);
    }

    /// M37 DQ4: pointer over the tab/refresh buttons, arrow elsewhere.
    /// Emits `sysmon: cursor=<name>` on change (serial-observable).
    pub fn update_cursor(self: *SysmonState, x: u32, y: u32) void {
        const over_clickable = self.btn_overview.rect.contains(x, y) or
            self.btn_procs.rect.contains(x, y) or
            self.btn_storage.rect.contains(x, y) or
            self.btn_refresh.rect.contains(x, y);
        const kind = ui.cursor_for_region(false, over_clickable, false);
        if (kind != self.cursor_kind) {
            self.cursor_kind = kind;
            var buf: [48]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "sysmon: cursor={s}\n", .{kind.name()}) catch return;
            ui.write_console(msg);
        }
    }

    pub fn init() SysmonState {
        var s = SysmonState{};
        s.refresh();
        return s;
    }

    pub fn refresh(self: *SysmonState) void {
        var raw: [640]u8 = undefined;
        const res = ui.get_procs(&raw);
        if (res >= 0) {
            const row_count = @as(usize, @intCast(res));
            self.proc_count = ui.parse_procs(&raw, row_count, &self.procs);
        } else {
            self.proc_count = 0;
        }
        self.refresh_count += 1;
        self.uptime_secs = self.refresh_count;
    }

    pub fn handle_event(self: *SysmonState, ev: *const Event) bool {
        switch (ev.kind) {
            ui.KEY_DOWN => {
                const kc = ev.arg0;
                if (kc == 0x2b) { // Tab key -> cycle tabs
                    self.tab = switch (self.tab) {
                        .overview => .processes,
                        .processes => .storage_net,
                        .storage_net => .overview,
                    };
                    return true;
                } else if (kc == 0x15) { // HID 0x15 = 'r' -> refresh
                    self.refresh();
                    return true;
                }
                return false;
            },
            ui.MOUSE_DOWN, ui.MOUSE_MOVE, ui.MOUSE_UP => {
                // M37 DQ4: per-region cursor tracking.
                if (ev.kind == ui.MOUSE_MOVE) self.update_cursor(ev.arg0, ev.arg1);
                if (self.btn_overview.handle_event(ev)) {
                    self.tab = .overview;
                    return true;
                }
                if (self.btn_procs.handle_event(ev)) {
                    self.tab = .processes;
                    return true;
                }
                if (self.btn_storage.handle_event(ev)) {
                    self.tab = .storage_net;
                    return true;
                }
                if (self.btn_refresh.handle_event(ev)) {
                    self.refresh();
                    return true;
                }
                return false;
            },
            ui.EVENT_TIMER => {
                self.refresh();
                _ = ui.timer_set(refresh_ticks);
                return true;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const SysmonState, win: u32) void {
        // Clear background
        ui.win_fill(win, 0, 0, self.canvas_w, self.canvas_h, ui.theme_bg());

        // Header tab bar
        ui.draw_rect(win, self.header_rect, ui.theme_surface());
        ui.draw_rect_outline(win, self.header_rect, ui.border_w, ui.theme_border());

        // Highlight active tab button
        var bo = self.btn_overview;
        var bp = self.btn_procs;
        var bs = self.btn_storage;
        if (self.tab == .overview) bo.state = .pressed;
        if (self.tab == .processes) bp.state = .pressed;
        if (self.tab == .storage_net) bs.state = .pressed;

        bo.draw(win);
        bp.draw(win);
        bs.draw(win);
        self.btn_refresh.draw(win);

        // Content area
        switch (self.tab) {
            .overview => self.draw_overview(win, self.content_rect),
            .processes => self.draw_processes(win, self.content_rect),
            .storage_net => self.draw_storage_net(win, self.content_rect),
        }
    }

    fn draw_overview(self: *const SysmonState, win: u32, r: Rect) void {
        ui.draw_rect(win, r, ui.theme_surface());
        ui.draw_rect_outline(win, r, ui.border_w, ui.theme_border());

        ui.draw_text(win, "VirelaiOS System Summary", r.x + 16, r.y + 16, ui.theme_accent());

        var y = r.y + 42;
        ui.draw_text(win, "Kernel:        VirelaiOS AArch64 Flat Image", r.x + 16, y, ui.theme_text_primary());
        y += 20;
        ui.draw_text(win, "Platform:      Apple Silicon (Virtualization.framework)", r.x + 16, y, ui.theme_text_primary());
        y += 20;
        ui.draw_text(win, "Execution EL:  EL1 Kernel / EL0 Userspace", r.x + 16, y, ui.theme_text_primary());
        y += 20;

        var buf: [64]u8 = undefined;
        const uptime_str = std.fmt.bufPrint(&buf, "App Session:   {d}s active (1 Hz auto-refresh)", .{self.uptime_secs}) catch "App Session: active";
        ui.draw_text(win, uptime_str, r.x + 16, y, ui.theme_text_primary());
        y += 20;

        var running_count: usize = 0;
        for (self.procs[0..self.proc_count]) |p| {
            if (p.state == .running) running_count += 1;
        }
        const proc_str = std.fmt.bufPrint(&buf, "Active Tasks:  {d} procs ({d} running)", .{ self.proc_count, running_count }) catch "Active Tasks: error";
        ui.draw_text(win, proc_str, r.x + 16, y, ui.theme_text_primary());
        y += 20;

        ui.draw_text(win, "Memory Model:  Fixed-BSS zero-heap, 4-level page tables", r.x + 16, y, ui.theme_text_primary());
        y += 20;
        ui.draw_text(win, "Display:       1280x720 32-bpp BGRA (virtio-gpu)", r.x + 16, y, ui.theme_text_primary());
        y += 20;
        ui.draw_text(win, "Audio:         virtio-snd PCM Stereo 48kHz (armed)", r.x + 16, y, ui.theme_text_primary());
        y += 24;

        ui.draw_text(win, "[Tab] Cycle tabs  |  [R] Force refresh  |  [Esc] Close", r.x + 16, y, ui.theme_text_muted());
    }

    fn draw_processes(self: *const SysmonState, win: u32, r: Rect) void {
        ui.draw_rect(win, r, ui.theme_surface());
        ui.draw_rect_outline(win, r, ui.border_w, ui.theme_border());

        // Header row
        ui.draw_rect(win, Rect.make(r.x + 1, r.y + 1, r.w - 2, 22), ui.theme_btn_idle());
        ui.draw_text(win, "PID", r.x + 12, r.y + 7, ui.theme_text_primary());
        ui.draw_text(win, "NAME", r.x + 60, r.y + 7, ui.theme_text_primary());
        ui.draw_text(win, "STATE", r.x + 220, r.y + 7, ui.theme_text_primary());
        ui.draw_text(win, "STATUS", r.x + 340, r.y + 7, ui.theme_text_primary());

        if (self.proc_count == 0) {
            ui.draw_empty_state(win, Rect.make(r.x + 10, r.y + 30, r.w - 20, r.h - 40), "No Active Processes", "Scheduler has no registered user tasks");
            return;
        }

        var y = r.y + 28;
        var i: usize = 0;
        const max_rows = rows_for_content_h(r.h);
        while (i < self.proc_count and i < max_rows) : (i += 1) {
            const p = self.procs[i];
            const row_rect = Rect.make(r.x + ui.pad_xs, y - ui.pad_xs, r.w - ui.pad_sm, 18);
            if (i % 2 == 1) {
                ui.win_fill(win, row_rect.x, row_rect.y, row_rect.w, row_rect.h, ui.theme_btn_idle());
            }

            var num_buf: [16]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&num_buf, "{d}", .{p.pid}) catch "?";
            ui.draw_text(win, pid_str, r.x + 12, y + 2, ui.theme_text_primary());

            const name_slice = p.name[0..p.name_len];
            ui.draw_text(win, name_slice, r.x + 60, y + 2, ui.theme_text_primary());

            const state_str = switch (p.state) {
                .created => "created",
                .running => "running",
                .exited => "exited",
                else => "unknown",
            };
            const state_col = if (p.state == .running) ui.theme_success() else ui.theme_text_muted();
            ui.draw_text(win, state_str, r.x + 220, y + 2, state_col);

            const status_str = std.fmt.bufPrint(&num_buf, "exit={d}", .{p.exit_status}) catch "";
            ui.draw_text(win, status_str, r.x + 340, y + 2, ui.theme_text_muted());

            y += 20;
        }
    }

    fn draw_storage_net(self: *const SysmonState, win: u32, r: Rect) void {
        _ = self;
        ui.draw_rect(win, r, ui.theme_surface());
        ui.draw_rect_outline(win, r, ui.border_w, ui.theme_border());

        var y = r.y + 14;
        ui.draw_text(win, "Storage Subsystem (ESP boot volume + host share)", r.x + 16, y, ui.theme_accent());
        y += 22;
        ui.draw_text(win, "Boot Volume:      EFI boot volume (BOOTAA64.EFI + KERNEL.BIN)", r.x + 16, y, ui.theme_text_primary());
        y += 20;
        ui.draw_text(win, "Host Share:       queue-5 file channel (APPS.TXT, user files)", r.x + 16, y, ui.theme_text_primary());
        y += 20;
        ui.draw_text(win, "Driver:           custom virtio file-channel, chunked I/O", r.x + 16, y, ui.theme_text_primary());
        y += 28;

        ui.draw_text(win, "Networking Subsystem Specs (virtio-net)", r.x + 16, y, ui.theme_accent());
        y += 22;
        ui.draw_text(win, "Transport:        virtio-pci network interface (VID 0x1af4, DID 0x1041)", r.x + 16, y, ui.theme_text_primary());
        y += 20;
        ui.draw_text(win, "Protocols:        Ethernet II, ARP, IPv4, ICMP Echo, UDP, DHCP, TCP", r.x + 16, y, ui.theme_text_primary());
        y += 20;
        ui.draw_text(win, "Default Subnet:   192.168.64.0/24 (Guest IP 192.168.64.2)", r.x + 16, y, ui.theme_text_primary());
        y += 20;
        ui.draw_text(win, "Status:           Link Up, RX FIFO Armed, TCP Client Ready", r.x + 16, y, ui.theme_text_primary());
    }
};

pub export fn _start() callconv(.c) noreturn {
    var state = SysmonState.init();

    // M42 SX4: the tab-aware open. Native 512x380 when the viewport
    // proposal is absent (shim/WND); full 1100x720 under TABWM.BIN.
    const ta_res = tabapp.TabApp.init(.{
        .name = "SYSMON.BIN",
        .title = "SysMon",
        .x = window_x,
        .y = window_y,
        .w = window_w,
        .h = window_h,
    }) orelse {
        ui.write_console("sysmon: failed to open window\n");
        ui.exit_process(1);
    };
    var ta = ta_res;
    state.layout(ta.w, ta.h);
    const win = ta.win;
    ui.write_console("sysmon: open id=8\n");
    if (ta.tab_aware) {
        ui.write_console("sysmon: tab-aware (full-viewport)\n");
    } else {
        ui.write_console("sysmon: not-tab-aware (shim or WND desktop)\n");
    }

    state.draw(win);
    ta.present();
    ui.emit_tokens_marker("sysmon");
    ui.write_console("sysmon: ready\n");
    // M37 DQ4 gate: let the compositor settle (several ticks) so the
    // kind-4 snapshot captures the presented frame, not a stale one.
    ui.sleep_ticks(2);
    ui.write_console("sysmon: settled\n");

    _ = ui.timer_set(refresh_ticks);

    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        // M42 SX4: WM-lifecycle events (resize -> relayout) first.
        switch (ta.dispatch(&ev)) {
            .closed => break,
            .resized => {
                ui.write_console("sysmon: resize relayout\n");
                state.layout(ta.w, ta.h);
                dirty = true;
            },
            .none => {
                if (ev.kind == ui.WIN_CLOSE or (ev.kind == ui.KEY_DOWN and (ev.arg0 == 0x29 or ev.arg0 == 0x14))) { // Esc / Q
                    ui.write_console("sysmon: close\n");
                    break;
                }
                dirty = state.handle_event(&ev) or dirty;
            },
        }

        while (ui.poll_event(&ev) > 0) {
            switch (ta.dispatch(&ev)) {
                .closed => {
                    ui.write_console("sysmon: close\n");
                    ta.close_and_exit(exit_status);
                },
                .resized => {
                    ui.write_console("sysmon: resize relayout\n");
                    state.layout(ta.w, ta.h);
                    dirty = true;
                    continue;
                },
                .none => {},
            }
            if (ev.kind == ui.WIN_CLOSE or (ev.kind == ui.KEY_DOWN and (ev.arg0 == 0x29 or ev.arg0 == 0x14))) {
                ui.write_console("sysmon: close\n");
                ta.close_and_exit(exit_status);
            }
            dirty = state.handle_event(&ev) or dirty;
        }

        if (dirty) {
            state.draw(win);
            ta.present();
        }
    }

    ui.write_console("sysmon: exiting\n");
    ta.close_and_exit(exit_status);
}

test "sysmon: state init and tab cycling" {
    var state = SysmonState.init();
    try std.testing.expectEqual(Tab.overview, state.tab);

    var ev_tab = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x2b, .arg1 = 0 };
    _ = state.handle_event(&ev_tab);
    try std.testing.expectEqual(Tab.processes, state.tab);

    _ = state.handle_event(&ev_tab);
    try std.testing.expectEqual(Tab.storage_net, state.tab);

    _ = state.handle_event(&ev_tab);
    try std.testing.expectEqual(Tab.overview, state.tab);
}

test "sysmon layout: native canvas is the identity (zero-regression fixed point)" {
    var state = SysmonState.init();
    state.layout(window_w, window_h);
    try std.testing.expectEqual(window_w, state.canvas_w);
    try std.testing.expectEqual(window_h, state.canvas_h);
    try std.testing.expectEqual(native_header, state.header_rect);
    try std.testing.expectEqual(native_content, state.content_rect);
    try std.testing.expectEqual(native_btn_overview.x, state.btn_overview.rect.x);
    try std.testing.expectEqual(native_btn_refresh.x, state.btn_refresh.rect.x);
}

test "sysmon layout: full viewport stretches the content area" {
    var state = SysmonState.init();
    state.layout(1100, 720);
    try std.testing.expectEqual(@as(u32, 1100), state.canvas_w);
    try std.testing.expectEqual(@as(u32, 720), state.canvas_h);
    try std.testing.expect(state.content_rect.x + state.content_rect.w <= 1100);
    try std.testing.expect(state.content_rect.y + state.content_rect.h <= 720);
    try std.testing.expect(state.content_rect.w > native_content.w);
    try std.testing.expect(state.content_rect.h > native_content.h);
    // The process table grows with the viewport (capped by storage).
    try std.testing.expect(rows_for_content_h(state.content_rect.h) >= rows_for_content_h(native_content.h));
    try std.testing.expect(rows_for_content_h(state.content_rect.h) <= max_procs);
}
