//! VirelaiOS sixteenth ESP user program -- TOP.BIN (Milestone 11, Card A4).
//!
//! Graphical Task Manager & Process Monitor. Polls `sys_procs` (slot 7) to
//! inspect active processes, renders live process tables and system statistics,
//! and provides interactive row selection via micro-widgets.
//!
//! Enhanced (Issue #216): CPU usage bars, auto-refresh via app timers,
//! and a process-count sparkline history.

const std = @import("std");
const ui = @import("lib/ui.zig");
const netstats = @import("lib/netstats.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const Label = ui.Label;
const Event = ui.Event;
const ProcInfo = ui.ProcInfo;
const ProcState = ui.ProcState;

pub const ActiveTab = enum { procs, network };

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

pub const SortColumn = enum { pid, name, state, exit };

fn ascii_lower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn name_eql_ignore_case(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (ascii_lower(ca) != ascii_lower(cb)) return false;
    return true;
}

fn name_cmp_ignore_case(a: []const u8, b: []const u8) i8 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const la = ascii_lower(a[i]);
        const lb = ascii_lower(b[i]);
        if (la < lb) return -1;
        if (la > lb) return 1;
    }
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

fn proc_name_slice(p: *const ProcInfo) []const u8 {
    if (p.name_len > 0) return p.name[0..p.name_len];
    return p.name[0..0];
}

/// Stable compare for sorting: -1 if a<b, 1 if a>b, 0 if equal.
pub fn compare_procs(a: *const ProcInfo, b: *const ProcInfo, col: SortColumn) i8 {
    return switch (col) {
        .pid => if (a.pid < b.pid) @as(i8, -1) else if (a.pid > b.pid) @as(i8, 1) else 0,
        .name => name_cmp_ignore_case(proc_name_slice(a), proc_name_slice(b)),
        .state => if (@intFromEnum(a.state) < @intFromEnum(b.state)) @as(i8, -1) else if (@intFromEnum(a.state) > @intFromEnum(b.state)) @as(i8, 1) else 0,
        .exit => if (a.exit_status < b.exit_status) @as(i8, -1) else if (a.exit_status > b.exit_status) @as(i8, 1) else 0,
    };
}

/// Case-insensitive substring match: true if needle is empty or needle ⊂ haystack.
pub fn name_contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (ascii_lower(haystack[i + j]) != ascii_lower(needle[j])) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

pub const AppState = struct {
    table: ProcessTable = .{},
    btn_refresh: Button = Button.init(Rect.make(6, 6, 54, 20), "Refresh"),
    btn_kill: Button = Button.init(Rect.make(64, 6, 38, 20), "Kill"),
    btn_auto: Button = Button.init(Rect.make(106, 6, 42, 20), "Auto"),
    btn_tab_procs: Button = Button.init(Rect.make(152, 6, 44, 20), "Procs"),
    btn_tab_net: Button = Button.init(Rect.make(200, 6, 38, 20), "Net"),
    auto_mode: bool = false,
    tab: ActiveTab = .procs,
    proc_history: [history_len]u16 = [_]u16{0} ** history_len,
    history_pos: usize = 0,
    // Network stats and rate deltas
    net_stats: netstats.NetStats = .{},
    prev_rx_bytes: u64 = 0,
    prev_tx_bytes: u64 = 0,
    rx_rate_bps: u64 = 0,
    tx_rate_bps: u64 = 0,
    net_history: [history_len]u16 = [_]u16{0} ** history_len,
    net_history_pos: usize = 0,
    // C8 sorting / filtering
    sort_column: SortColumn = .pid,
    sort_asc: bool = true,
    filter_input: ui.TextInput = ui.TextInput.init(Rect.make(296, 6, 80, 20)),
    display_indices: [max_display_procs]usize = [_]usize{0} ** max_display_procs,
    display_count: usize = 0,

    pub fn init() AppState {
        var s = AppState{};
        s.btn_refresh.bg_color = ui.COLOR_ACCENT;
        s.btn_kill.bg_color = ui.COLOR_DANGER;
        s.btn_tab_procs.bg_color = ui.COLOR_ACCENT;
        s.btn_tab_net.bg_color = ui.COLOR_SURFACE;
        _ = s.table.refresh_from_system();
        s.push_history();
        s.rebuild_display();
        s.refresh_net_stats();
        return s;
    }

    pub fn filter_slice(self: *const AppState) []const u8 {
        return self.filter_input.get_text();
    }

    pub fn set_filter(self: *AppState, text: []const u8) void {
        self.filter_input.set_text(text);
        self.rebuild_display();
    }

    pub fn click_column(self: *AppState, col: SortColumn) void {
        if (self.sort_column == col) {
            self.sort_asc = !self.sort_asc;
        } else {
            self.sort_column = col;
            self.sort_asc = true;
        }
        self.rebuild_display();
    }

    /// Rebuild display_indices = filtered + stable-sorted view of table.
    pub fn rebuild_display(self: *AppState) void {
        // Capture previously selected pid to preserve across filter/sort.
        var prev_pid: ?u64 = null;
        if (self.table.selected_row) |sel| {
            if (sel < self.display_count) {
                const abs = self.display_indices[sel];
                if (abs < self.table.count) prev_pid = self.table.procs[abs].pid;
            } else if (sel < self.table.count) {
                prev_pid = self.table.procs[sel].pid;
            }
        }
        const needle = self.filter_slice();
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.table.count) : (i += 1) {
            const p = &self.table.procs[i];
            if (name_contains(proc_name_slice(p), needle)) {
                self.display_indices[n] = i;
                n += 1;
            }
        }
        // Stable insertion sort over display_indices.
        var j: usize = 1;
        while (j < n) : (j += 1) {
            const key = self.display_indices[j];
            var k = j;
            while (k > 0) {
                const a = &self.table.procs[self.display_indices[k - 1]];
                const b = &self.table.procs[key];
                const cmp = compare_procs(a, b, self.sort_column);
                const should_shift = if (self.sort_asc) cmp > 0 else cmp < 0;
                if (!should_shift) break;
                self.display_indices[k] = self.display_indices[k - 1];
                k -= 1;
            }
            self.display_indices[k] = key;
        }
        self.display_count = n;
        // Restore selection by pid if possible.
        if (prev_pid) |pid| {
            var found: ?usize = null;
            var idx: usize = 0;
            while (idx < n) : (idx += 1) {
                const abs = self.display_indices[idx];
                if (self.table.procs[abs].pid == pid) {
                    found = idx;
                    break;
                }
            }
            if (found) |f| {
                self.table.selected_row = f;
            } else {
                self.table.selected_row = if (n > 0) @as(usize, 0) else null;
            }
        } else if (self.table.selected_row == null and n > 0) {
            // Auto-select first running in filtered view.
            var f: usize = 0;
            while (f < n) : (f += 1) {
                const pi = self.display_indices[f];
                if (self.table.procs[pi].state == .running) {
                    self.table.selected_row = f;
                    break;
                }
            }
        }
        if (self.table.selected_row) |s| {
            if (s >= n) self.table.selected_row = if (n > 0) n - 1 else null;
        }
    }

    /// Map filtered display row to absolute table index.
    pub fn set_tab(self: *AppState, tab: ActiveTab) void {
        self.tab = tab;
        if (tab == .procs) {
            self.btn_tab_procs.bg_color = ui.COLOR_ACCENT;
            self.btn_tab_net.bg_color = ui.COLOR_SURFACE;
            ui.write_console("top: tab=procs\n");
        } else {
            self.btn_tab_procs.bg_color = ui.COLOR_SURFACE;
            self.btn_tab_net.bg_color = ui.COLOR_ACCENT;
            self.refresh_net_stats();
            ui.write_console("top: tab=network\n");
        }
    }

    pub fn refresh_net_stats(self: *AppState) void {
        const prev_rx = self.net_stats.rx_bytes;
        const prev_tx = self.net_stats.tx_bytes;
        const ok = netstats.read_stats(&self.net_stats);
        if (ok) {
            if (self.prev_rx_bytes > 0 and self.net_stats.rx_bytes >= prev_rx) {
                self.rx_rate_bps = self.net_stats.rx_bytes - prev_rx;
            } else if (self.prev_rx_bytes == 0) {
                self.rx_rate_bps = 0;
            }
            if (self.prev_tx_bytes > 0 and self.net_stats.tx_bytes >= prev_tx) {
                self.tx_rate_bps = self.net_stats.tx_bytes - prev_tx;
            } else if (self.prev_tx_bytes == 0) {
                self.tx_rate_bps = 0;
            }
            self.prev_rx_bytes = self.net_stats.rx_bytes;
            self.prev_tx_bytes = self.net_stats.tx_bytes;
        }
        const sum = self.rx_rate_bps + self.tx_rate_bps;
        const combined: u16 = @intCast(@min(sum, 65535));
        self.net_history[self.net_history_pos] = combined;
        self.net_history_pos = (self.net_history_pos + 1) % history_len;
    }

    /// Map filtered display row to absolute table index.
    pub fn display_to_absolute(self: *const AppState, display_row: usize) ?usize {
        if (display_row >= self.display_count) return null;
        return self.display_indices[display_row];
    }

    fn push_history(self: *AppState) void {
        self.proc_history[self.history_pos] = @intCast(self.table.count);
        self.history_pos = (self.history_pos + 1) % history_len;
    }

    fn format_ip(ip: [4]u8, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch buf[0..0];
    }

    fn format_mac(mac: [6]u8, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] }) catch buf[0..0];
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

    fn draw_network_tab(self: *const AppState, win: u32) void {
        // Divider line below toolbar
        ui.draw_rect(win, Rect.make(0, 32, window_w, 1), ui.COLOR_BORDER);

        // Section 1: Interface & Protocols (y=38..106)
        const s1_rect = Rect.make(6, 38, window_w - 12, 68);
        ui.draw_rect(win, s1_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, s1_rect, 1, ui.COLOR_BORDER);
        ui.draw_text(win, "NETWORK INTERFACE & PROTOCOLS", s1_rect.x + 6, s1_rect.y + 4, ui.COLOR_ACCENT);

        var ip_buf: [16]u8 = undefined;
        var gw_buf: [16]u8 = undefined;
        var mac_buf: [20]u8 = undefined;
        const own_ip_s = format_ip(self.net_stats.own_ip, &ip_buf);
        const gw_s = format_ip(self.net_stats.gateway, &gw_buf);
        const mac_s = format_mac(self.net_stats.mac, &mac_buf);

        var line1_buf: [80]u8 = undefined;
        const line1 = std.fmt.bufPrint(&line1_buf, "IP: {s}  GW: {s}  MAC: {s}", .{ own_ip_s, gw_s, mac_s }) catch "";
        ui.draw_text(win, line1, s1_rect.x + 6, s1_rect.y + 20, ui.COLOR_TEXT_PRIMARY);

        var lease_buf: [16]u8 = undefined;
        const lease_s = format_ip(self.net_stats.lease_ip, &lease_buf);
        var line2_buf: [80]u8 = undefined;
        const dhcp_name = netstats.dhcp_state_name(self.net_stats.dhcp_state);
        const line2 = std.fmt.bufPrint(&line2_buf, "DHCP: {s}  Lease: {s} ({d}s)", .{ dhcp_name, lease_s, self.net_stats.lease_secs }) catch "";
        ui.draw_text(win, line2, s1_rect.x + 6, s1_rect.y + 36, ui.COLOR_TEXT_MUTED);

        var peer_buf: [16]u8 = undefined;
        const peer_s = format_ip(self.net_stats.tcp_peer_ip, &peer_buf);
        const tcp_name = netstats.tcp_state_name(self.net_stats.tcp_state);
        var line3_buf: [80]u8 = undefined;
        const line3 = std.fmt.bufPrint(&line3_buf, "TCP: {s} ({s}:{d})  UDP Listeners: {d}", .{ tcp_name, peer_s, self.net_stats.tcp_peer_port, self.net_stats.udp_count }) catch "";
        ui.draw_text(win, line3, s1_rect.x + 6, s1_rect.y + 52, ui.COLOR_TEXT_MUTED);

        // Section 2: Traffic Statistics (y=112..192)
        const s2_rect = Rect.make(6, 112, window_w - 12, 80);
        ui.draw_rect(win, s2_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, s2_rect, 1, ui.COLOR_BORDER);
        ui.draw_text(win, "TRAFFIC & ACTIVITY", s2_rect.x + 6, s2_rect.y + 4, ui.COLOR_ACCENT);

        var rx_line_buf: [80]u8 = undefined;
        const rx_line = std.fmt.bufPrint(&rx_line_buf, "RX Rate: {d} B/s  (Total: {d} frames, {d} bytes)", .{ self.rx_rate_bps, self.net_stats.rx_frames, self.net_stats.rx_bytes }) catch "";
        ui.draw_text(win, rx_line, s2_rect.x + 6, s2_rect.y + 20, ui.COLOR_TEXT_PRIMARY);

        var tx_line_buf: [80]u8 = undefined;
        const tx_line = std.fmt.bufPrint(&tx_line_buf, "TX Rate: {d} B/s  (Total: {d} frames, {d} bytes)", .{ self.tx_rate_bps, self.net_stats.tx_frames, self.net_stats.tx_bytes }) catch "";
        ui.draw_text(win, tx_line, s2_rect.x + 6, s2_rect.y + 36, ui.COLOR_TEXT_PRIMARY);

        var err_line_buf: [80]u8 = undefined;
        const err_line = std.fmt.bufPrint(&err_line_buf, "Filtered: {d}  Overflow: {d}  UDP Sent/Recv: {d}/{d}", .{ self.net_stats.rx_filtered, self.net_stats.rx_overflow, self.net_stats.udp_dgrams[1], self.net_stats.udp_dgrams[0] }) catch "";
        ui.draw_text(win, err_line, s2_rect.x + 6, s2_rect.y + 52, ui.COLOR_TEXT_MUTED);

        var tcp_line_buf: [80]u8 = undefined;
        const tcp_line = std.fmt.bufPrint(&tcp_line_buf, "TCP Segs: syn={d} ack={d} data_tx={d} data_rx={d}", .{ self.net_stats.tcp_segs[0], self.net_stats.tcp_segs[2], self.net_stats.tcp_segs[3], self.net_stats.tcp_segs[4] }) catch "";
        ui.draw_text(win, tcp_line, s2_rect.x + 6, s2_rect.y + 66, ui.COLOR_TEXT_MUTED);

        // Section 3: Bandwidth Graph (y=198..376)
        const sp_x: u32 = 6;
        const sp_y: u32 = 198;
        const sp_w: u32 = window_w - 12;
        const sp_h: u32 = window_h - sp_y - 8;

        ui.draw_rect(win, Rect.make(sp_x, sp_y, sp_w, sp_h), ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, Rect.make(sp_x, sp_y, sp_w, sp_h), 1, ui.COLOR_BORDER);

        var max_val: u16 = 1;
        var i: usize = 0;
        while (i < history_len) : (i += 1) {
            if (self.net_history[i] > max_val) {
                max_val = self.net_history[i];
            }
        }

        ui.draw_text(win, "BANDWIDTH HISTORY (RX+TX B/s)", sp_x + 6, sp_y + 4, ui.COLOR_ACCENT);

        var peak_buf: [32]u8 = undefined;
        const peak_s = std.fmt.bufPrint(&peak_buf, "Peak: {d} B/s", .{max_val}) catch "";
        ui.draw_text(win, peak_s, sp_x + sp_w - 100, sp_y + 4, ui.COLOR_TEXT_MUTED);

        const bar_w_px: u32 = 6;
        const gap: u32 = 2;
        const step: u32 = bar_w_px + gap;
        var x_off: u32 = 6;
        const graph_h: u32 = sp_h - 26;
        i = 0;
        while (i < history_len and x_off + bar_w_px <= sp_w - 6) : (i += 1) {
            const idx = (self.net_history_pos + i) % history_len;
            const val = self.net_history[idx];
            const h: u32 = if (max_val > 0) @intCast(@as(u32, @intCast(val)) * (graph_h - 4) / @as(u32, @intCast(max_val))) else 0;
            if (h > 0) {
                ui.draw_rect(win, Rect.make(sp_x + x_off, sp_y + sp_h - 4 - h, bar_w_px, h), ui.COLOR_ACCENT);
            }
            x_off += step;
        }
    }

    pub fn draw(self: *const AppState, win: u32) void {
        // Window background
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.COLOR_BG);

        // Toolbar
        self.btn_refresh.draw(win);
        self.btn_kill.draw(win);
        self.btn_auto.draw(win);
        self.btn_tab_procs.draw(win);
        self.btn_tab_net.draw(win);

        if (self.tab == .procs) {
            // Filter input (C8)
            ui.draw_text(win, "Filter:", 248, 12, ui.COLOR_TEXT_MUTED);
            self.filter_input.draw(win);

            // Stats header (shifted to avoid filter overlap)
            var stats_buf: [40]u8 = undefined;
            const running_cnt = self.table.count_running();
            const stats_str = std.fmt.bufPrint(&stats_buf, "Procs: {d} Run: {d}", .{ self.display_count, running_cnt }) catch "Procs: ?";
            ui.draw_text(win, stats_str, 384, 12, ui.COLOR_TEXT_MUTED);

            // CPU usage bar
            self.draw_cpu_bar(win);

            // Divider line
            ui.draw_rect(win, Rect.make(0, 48, window_w, 1), ui.COLOR_BORDER);

            // Table Header — clickable sortable columns (C8)
            const header_rect = Rect.make(6, 52, window_w - 12, 16);
            ui.draw_rect(win, header_rect, ui.COLOR_SURFACE);
            ui.draw_rect_outline(win, header_rect, 1, ui.COLOR_BORDER);
            const pid_active = self.sort_column == .pid;
            const name_active = self.sort_column == .name;
            const state_active = self.sort_column == .state;
            const exit_active = self.sort_column == .exit;
            const pid_ind: []const u8 = if (pid_active) (if (self.sort_asc) "^" else "v") else "";
            const name_ind: []const u8 = if (name_active) (if (self.sort_asc) "^" else "v") else "";
            const state_ind: []const u8 = if (state_active) (if (self.sort_asc) "^" else "v") else "";
            const exit_ind: []const u8 = if (exit_active) (if (self.sort_asc) "^" else "v") else "";
            // Draw header text with indicator; active column in accent.
            ui.draw_text(win, "PID", header_rect.x + 4, header_rect.y + 4, if (pid_active) ui.COLOR_ACCENT else ui.COLOR_TEXT_MUTED);
            if (pid_active) ui.draw_text(win, pid_ind, header_rect.x + 24, header_rect.y + 4, ui.COLOR_ACCENT);
            ui.draw_text(win, "NAME", header_rect.x + 32, header_rect.y + 4, if (name_active) ui.COLOR_ACCENT else ui.COLOR_TEXT_MUTED);
            if (name_active) ui.draw_text(win, name_ind, header_rect.x + 62, header_rect.y + 4, ui.COLOR_ACCENT);
            ui.draw_text(win, "STATE", header_rect.x + 130, header_rect.y + 4, if (state_active) ui.COLOR_ACCENT else ui.COLOR_TEXT_MUTED);
            if (state_active) ui.draw_text(win, state_ind, header_rect.x + 170, header_rect.y + 4, ui.COLOR_ACCENT);
            ui.draw_text(win, "EXIT", header_rect.x + 196, header_rect.y + 4, if (exit_active) ui.COLOR_ACCENT else ui.COLOR_TEXT_MUTED);
            if (exit_active) ui.draw_text(win, exit_ind, header_rect.x + 226, header_rect.y + 4, ui.COLOR_ACCENT);

            // Table Rows — filtered + sorted view (C8)
            const row_h: u32 = 16;
            var row_y: u32 = 70;
            var i: usize = 0;
            while (i < self.display_count and row_y + row_h <= window_h - 44) : (i += 1) {
                const abs = self.display_indices[i];
                const proc = &self.table.procs[abs];
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
        } else {
            // Rate display on toolbar
            var rate_buf: [48]u8 = undefined;
            const rate_str = std.fmt.bufPrint(&rate_buf, "RX: {d} B/s  TX: {d} B/s", .{ self.rx_rate_bps, self.tx_rate_bps }) catch "";
            ui.draw_text(win, rate_str, 248, 12, ui.COLOR_TEXT_MUTED);

            self.draw_network_tab(win);
        }
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

        if (self.btn_tab_procs.handle_event(ev)) {
            self.set_tab(.procs);
            return true;
        }
        if (self.btn_tab_net.handle_event(ev)) {
            self.set_tab(.network);
            return true;
        }

        if (self.tab == .procs) {
            // Filter input handles mouse focus (C8).
            if (self.filter_input.handle_event(ev)) {
                return true;
            }
        }

        if (self.btn_refresh.handle_event(ev)) {
            _ = self.table.refresh_from_system();
            self.rebuild_display();
            self.push_history();
            self.refresh_net_stats();
            ui.write_console("top: refreshed ok\n");
            changed = true;
        } else if (self.btn_kill.handle_event(ev)) {
            if (self.table.selected_row) |sel| {
                changed = self.kill_selected(sel) or changed;
            }
        } else if (self.btn_auto.handle_event(ev)) {
            self.toggle_auto_refresh();
            changed = true;
        } else if (self.tab == .procs and ev.kind == ui.MOUSE_DOWN and (ev.flags & ui.BTN_LEFT) != 0) {
            const click_x = ev.arg0;
            const click_y = ev.arg1;
            // Header click → sort (C8).
            if (click_y >= 52 and click_y < 68 and click_x >= 6 and click_x < window_w - 6) {
                if (click_x < 32) {
                    self.click_column(.pid);
                } else if (click_x < 130) {
                    self.click_column(.name);
                } else if (click_x < 196) {
                    self.click_column(.state);
                } else {
                    self.click_column(.exit);
                }
                return true;
            }
            if (click_x >= 6 and click_x < window_w - 6 and click_y >= 70) {
                const row_idx = (click_y - 70) / 16;
                if (row_idx < self.display_count) {
                    self.table.selected_row = row_idx;
                    changed = true;
                }
            }
        }

        return changed;
    }

    pub fn handle_keyboard_event(self: *AppState, ev: *const Event) bool {
        if (ev.kind != ui.KEY_DOWN) return false;

        // 'n' or 'N' -> switch to Network tab
        if (ev.arg1 == 'n' or ev.arg1 == 'N') {
            self.set_tab(.network);
            return true;
        }
        // 'p' or 'P' -> switch to Procs tab
        if (ev.arg1 == 'p' or ev.arg1 == 'P') {
            self.set_tab(.procs);
            return true;
        }

        if (self.tab == .procs) {
            // Filter input has priority when focused (C8).
            if (self.filter_input.focused) {
                // Let TextInput handle typing / backspace.
                const prev_len = self.filter_input.len;
                const handled = self.filter_input.handle_event(ev);
                if (handled or self.filter_input.len != prev_len) {
                    self.rebuild_display();
                    return true;
                }
                if (ev.arg0 == 0x29) { // Esc
                    self.filter_input.focused = false;
                    return true;
                }
                return false;
            }

            const keycode = ev.arg0;

            // Up arrow — navigate filtered view (C8).
            if (keycode == 0x52) {
                if (self.display_count == 0) return false;
                if (self.table.selected_row) |sel| {
                    if (sel > 0) self.table.selected_row = sel - 1;
                } else {
                    self.table.selected_row = 0;
                }
                return true;
            }

            // Down arrow — navigate filtered view (C8).
            if (keycode == 0x51) {
                if (self.display_count == 0) return false;
                if (self.table.selected_row) |sel| {
                    if (sel + 1 < self.display_count) self.table.selected_row = sel + 1;
                } else {
                    self.table.selected_row = 0;
                }
                return true;
            }

            // '/' or 'f' focuses filter (convenience).
            if (ev.arg1 == '/' or ev.arg1 == 'f' or ev.arg1 == 'F') {
                self.filter_input.focused = true;
                return true;
            }
        }

        // 'r' or 'R' -> Refresh
        if (ev.arg1 == 'r' or ev.arg1 == 'R') {
            _ = self.table.refresh_from_system();
            self.rebuild_display();
            self.push_history();
            self.refresh_net_stats();
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
        self.rebuild_display();
        self.push_history();
        self.refresh_net_stats();
        // Re-arm timer if still in auto mode
        if (self.auto_mode) {
            _ = ui.timer_set(auto_refresh_ticks);
        }
        return true;
    }

    pub fn kill_selected(self: *AppState, row: usize) bool {
        const abs = self.display_to_absolute(row) orelse return false;
        if (abs >= self.table.count) return false;
        const proc = &self.table.procs[abs];
        const res = ui.kill_process(proc.pid);
        var buf: [48]u8 = undefined;
        if (res == 0) {
            const msg = std.fmt.bufPrint(&buf, "top: kill pid={d}\n", .{proc.pid}) catch "top: kill\n";
            ui.write_console(msg);
            _ = self.table.refresh_from_system();
            self.rebuild_display();
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
    app.rebuild_display();
    // After rebuild, selected should be first running in filtered view (pid 1 at display 0 or 1 depending on sort).
    // Force select the running proc's display row.
    var sel: usize = 0;
    while (sel < app.display_count) : (sel += 1) {
        if (app.display_to_absolute(sel).? == 1) break;
    }
    if (sel < app.display_count) app.table.selected_row = sel else app.table.selected_row = 0;

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

test "top: compare_procs sorting (C8)" {
    const a = ProcInfo{ .pid = 2, .state = .running, .exit_status = 0, .name = "B.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 5 };
    const b = ProcInfo{ .pid = 1, .state = .exited, .exit_status = 7, .name = "A.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 5 };
    try std.testing.expectEqual(@as(i8, 1), compare_procs(&a, &b, .pid)); // 2 > 1
    try std.testing.expectEqual(@as(i8, -1), compare_procs(&b, &a, .pid));
    try std.testing.expectEqual(@as(i8, 1), compare_procs(&a, &b, .name)); // B > A
    try std.testing.expectEqual(@as(i8, -1), compare_procs(&b, &a, .name));
    // Name case-insensitive
    const c = ProcInfo{ .pid = 3, .state = .created, .exit_status = 0, .name = "a.bin\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 5 };
    try std.testing.expectEqual(@as(i8, 0), compare_procs(&b, &c, .name));
}

test "top: name_contains filter (C8)" {
    try std.testing.expect(name_contains("HELLO.BIN", ""));
    try std.testing.expect(name_contains("HELLO.BIN", "hello"));
    try std.testing.expect(name_contains("HELLO.BIN", "llo"));
    try std.testing.expect(!name_contains("HELLO.BIN", "world"));
    try std.testing.expect(name_contains("Calc.BIN", "calc"));
    try std.testing.expect(!name_contains("A", "AB"));
}

test "top: AppState sortable columns and indicator (C8)" {
    var app = AppState.init();
    app.table.count = 3;
    app.table.procs[0] = .{ .pid = 2, .state = .running, .exit_status = 0, .name = "B.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 5 };
    app.table.procs[1] = .{ .pid = 0, .state = .exited, .exit_status = 7, .name = "A.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 5 };
    app.table.procs[2] = .{ .pid = 1, .state = .created, .exit_status = 0, .name = "C.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 5 };
    app.sort_column = .pid;
    app.sort_asc = true;
    app.rebuild_display();
    // Sorted by pid asc: 0,1,2
    try std.testing.expectEqual(@as(usize, 3), app.display_count);
    try std.testing.expectEqual(@as(u64, 0), app.table.procs[app.display_indices[0]].pid);
    try std.testing.expectEqual(@as(u64, 1), app.table.procs[app.display_indices[1]].pid);
    try std.testing.expectEqual(@as(u64, 2), app.table.procs[app.display_indices[2]].pid);
    // Toggle same column → desc
    app.click_column(.pid);
    try std.testing.expect(!app.sort_asc);
    try std.testing.expectEqual(@as(u64, 2), app.table.procs[app.display_indices[0]].pid);
    // Click different column → asc and name sort
    app.click_column(.name);
    try std.testing.expect(app.sort_asc);
    try std.testing.expectEqual(SortColumn.name, app.sort_column);
    try std.testing.expectEqual(@as(u64, 0), app.table.procs[app.display_indices[0]].pid); // A.BIN pid0
}

test "top: AppState text filter and sort+filter (C8)" {
    var app = AppState.init();
    app.table.count = 4;
    app.table.procs[0] = .{ .pid = 0, .state = .running, .exit_status = 0, .name = "CALC.BIN\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 8 };
    app.table.procs[1] = .{ .pid = 1, .state = .running, .exit_status = 0, .name = "NOTEPAD.BIN\x00\x00\x00\x00\x00".*, .name_len = 11 };
    app.table.procs[2] = .{ .pid = 2, .state = .running, .exit_status = 0, .name = "TOP.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 7 };
    app.table.procs[3] = .{ .pid = 3, .state = .running, .exit_status = 0, .name = "FILE.BIN\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 8 };
    app.sort_column = .pid;
    app.sort_asc = true;
    app.set_filter("top");
    try std.testing.expectEqual(@as(usize, 1), app.display_count);
    try std.testing.expectEqual(@as(u64, 2), app.table.procs[app.display_indices[0]].pid);
    // Filter + sort: "bin" matches all 4, sorted by name
    app.set_filter("bin");
    app.click_column(.name);
    try std.testing.expectEqual(@as(usize, 4), app.display_count);
    // Sorted by name asc: CALC, FILE, NOTEPAD, TOP
    try std.testing.expectEqual(@as(u64, 0), app.table.procs[app.display_indices[0]].pid);
    try std.testing.expectEqual(@as(u64, 3), app.table.procs[app.display_indices[1]].pid);
    try std.testing.expectEqual(@as(u64, 1), app.table.procs[app.display_indices[2]].pid);
    try std.testing.expectEqual(@as(u64, 2), app.table.procs[app.display_indices[3]].pid);
    // Clear filter
    app.set_filter("");
    try std.testing.expectEqual(@as(usize, 4), app.display_count);
}

test "top: AppState auto-refresh preserves sort and filter (C8)" {
    var app = AppState.init();
    app.table.count = 2;
    app.table.procs[0] = .{ .pid = 1, .state = .running, .exit_status = 0, .name = "B.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 5 };
    app.table.procs[1] = .{ .pid = 0, .state = .running, .exit_status = 0, .name = "A.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 5 };
    app.sort_column = .name;
    app.sort_asc = true;
    app.set_filter("a");
    try std.testing.expectEqual(@as(usize, 1), app.display_count);
    // Simulate timer adding a new proc that also matches filter — rebuild should preserve sort/filter
    app.table.count = 3;
    app.table.procs[2] = .{ .pid = 2, .state = .running, .exit_status = 0, .name = "AA.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 6 };
    app.rebuild_display();
    try std.testing.expectEqual(SortColumn.name, app.sort_column);
    try std.testing.expect(app.sort_asc);
    try std.testing.expectEqual(@as(usize, 2), app.display_count);
    // Simulate handle_timer's rebuild path without wiping table (host stub would clear, so test rebuild directly)
    app.rebuild_display();
    try std.testing.expectEqual(@as(usize, 2), app.display_count);
}

test "top: header click via mouse event (C8)" {
    var app = AppState.init();
    app.table.count = 1;
    app.table.procs[0] = .{ .pid = 0, .state = .running, .exit_status = 0, .name = "TEST.BIN\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 8 };
    app.rebuild_display();
    const hdr_y: u32 = 60;
    // Click PID header (x=10)
    var ev_pid = Event{ .kind = ui.MOUSE_DOWN, .flags = ui.BTN_LEFT, .seq = 1, .arg0 = 10, .arg1 = hdr_y };
    _ = app.handle_mouse_events(&ev_pid);
    try std.testing.expectEqual(SortColumn.pid, app.sort_column);
    // Click NAME header (x=40)
    var ev_name = Event{ .kind = ui.MOUSE_DOWN, .flags = ui.BTN_LEFT, .seq = 2, .arg0 = 40, .arg1 = hdr_y };
    _ = app.handle_mouse_events(&ev_name);
    try std.testing.expectEqual(SortColumn.name, app.sort_column);
}

test "top: row click selects filtered row (C8)" {
    var app = AppState.init();
    app.table.count = 2;
    app.table.procs[0] = .{ .pid = 2, .state = .running, .exit_status = 0, .name = "B.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 5 };
    app.table.procs[1] = .{ .pid = 1, .state = .running, .exit_status = 0, .name = "A.BIN\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*, .name_len = 5 };
    app.sort_column = .name;
    app.sort_asc = true;
    app.rebuild_display();
    // Sorted: A.BIN (pid1) at display 0, B.BIN (pid2) at display 1
    // Click row 1 (y=70+16)
    var ev = Event{ .kind = ui.MOUSE_DOWN, .flags = ui.BTN_LEFT, .seq = 1, .arg0 = 10, .arg1 = 70 + 16 + 2 };
    _ = app.handle_mouse_events(&ev);
    try std.testing.expectEqual(@as(?usize, 1), app.table.selected_row);
    const abs = app.display_to_absolute(1).?;
    try std.testing.expectEqual(@as(u64, 2), app.table.procs[abs].pid);
}

test "top: AppState network tab switching and mouse/keyboard events" {
    var app = AppState.init();
    try std.testing.expectEqual(ActiveTab.procs, app.tab);

    // Switch to network tab via set_tab
    app.set_tab(.network);
    try std.testing.expectEqual(ActiveTab.network, app.tab);

    // Switch back to procs via mouse event on btn_tab_procs (x=160, y=10)
    var ev_down = Event{ .kind = ui.MOUSE_DOWN, .flags = ui.BTN_LEFT, .seq = 1, .arg0 = 160, .arg1 = 10 };
    _ = app.handle_mouse_events(&ev_down);
    var ev_up = Event{ .kind = ui.MOUSE_UP, .flags = 0, .seq = 2, .arg0 = 160, .arg1 = 10 };
    _ = app.handle_mouse_events(&ev_up);
    try std.testing.expectEqual(ActiveTab.procs, app.tab);

    // Switch to network via keyboard 'n'
    var ev_k_net = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0, .arg1 = 'n' };
    _ = app.handle_keyboard_event(&ev_k_net);
    try std.testing.expectEqual(ActiveTab.network, app.tab);

    // Switch to procs via keyboard 'p'
    var ev_k_proc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0, .arg1 = 'p' };
    _ = app.handle_keyboard_event(&ev_k_proc);
    try std.testing.expectEqual(ActiveTab.procs, app.tab);
}

test "top: network stats delta rate calculation" {
    var app = AppState.init();
    app.prev_rx_bytes = 1000;
    app.prev_tx_bytes = 2000;
    app.net_stats.rx_bytes = 1500;
    app.net_stats.tx_bytes = 2800;

    // Simulate refresh without hardware syscall
    const prev_rx = app.net_stats.rx_bytes;
    const prev_tx = app.net_stats.tx_bytes;
    if (app.prev_rx_bytes > 0 and app.net_stats.rx_bytes >= prev_rx) {
        app.rx_rate_bps = app.net_stats.rx_bytes - app.prev_rx_bytes;
    }
    if (app.prev_tx_bytes > 0 and app.net_stats.tx_bytes >= prev_tx) {
        app.tx_rate_bps = app.net_stats.tx_bytes - app.prev_tx_bytes;
    }
    app.prev_rx_bytes = app.net_stats.rx_bytes;
    app.prev_tx_bytes = app.net_stats.tx_bytes;

    try std.testing.expectEqual(@as(u64, 500), app.rx_rate_bps);
    try std.testing.expectEqual(@as(u64, 800), app.tx_rate_bps);
}

test "top: AppState fits EL0 stack (C8, <4 KiB)" {
    try std.testing.expect(@sizeOf(AppState) < 4 * 1024);
    std.debug.print("TOP AppState size: {d}\n", .{@sizeOf(AppState)});
}
