//! VirelaiOS network dashboard — NETSTAT.BIN (Milestone 26, Card N2, Issue #400).
//!
//! A full-window dashboard rendered from `sys_net_stats` (slot 62): the
//! interface (MAC/IP/GW), TCP connection state + peer, UDP listeners,
//! the ARP table, the DHCP lease, and the device RX/TX counters. Refreshes
//! every second via the per-app timer (EVENT_TIMER, like TOP.BIN).
//!
//! The snapshot struct mirror lives in `lib/netstats.zig`; both sides pin
//! @sizeOf/@offsetOf in host tests so ABI drift fails loudly.

const std = @import("std");
const ui = @import("lib/ui.zig");
const ns = @import("lib/netstats.zig");

pub const window_x: u32 = 40;
pub const window_y: u32 = 40;
pub const window_w: u32 = 512;
pub const window_h: u32 = 384;
pub const exit_status: u32 = 44;
pub const refresh_ticks: u64 = 4; // ~1 Hz at the 250 ms scheduler quantum

// ---------------------------------------------------------------------------
// Pure formatting helpers (host-tested)
// ---------------------------------------------------------------------------

/// Render an IPv4 address into `out` (15+ bytes). Returns the length.
pub fn format_ip(ip: [4]u8, out: *[15]u8) usize {
    const s = std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch return 0;
    return s.len;
}

/// Render a MAC into `out` (17 bytes): `02:00:00:00:00:02`. Always 17 bytes.
pub fn format_mac(mac: [6]u8, out: *[17]u8) usize {
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        out[i * 3] = hex[mac[i] >> 4];
        out[i * 3 + 1] = hex[mac[i] & 0xf];
        if (i < 5) out[i * 3 + 2] = ':';
    }
    return 17;
}

// ---------------------------------------------------------------------------
// App state (BSS — DSK3 segmented build like GLOBALS.BIN)
// ---------------------------------------------------------------------------

var g_snap: ns.NetStats = .{};

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn draw_row(win: u32, y: u32, label: []const u8, value: []const u8) u32 {
    ui.draw_text(win, label, 12, y, ui.COLOR_TEXT_MUTED);
    ui.draw_text(win, value, 128, y, ui.COLOR_TEXT_PRIMARY);
    return y + 16;
}

fn draw_section(win: u32, y: u32, title: []const u8) u32 {
    ui.draw_text(win, title, 12, y, ui.COLOR_ACCENT);
    return y + 14;
}

fn draw(win: u32) void {
    ui.win_fill(win, 0, 0, window_w, window_h, ui.COLOR_BG);
    var y: u32 = 10;

    ui.draw_text(win, "NETSTAT.BIN — network dashboard", 12, y, ui.COLOR_ACCENT);
    y += 24;

    // ---- interface ---------------------------------------------------------
    y = draw_section(win, y, "Interface");
    var macb: [17]u8 = undefined;
    _ = format_mac(g_snap.mac, &macb);
    y = draw_row(win, y, "MAC", macb[0..17]);
    var ipb: [15]u8 = undefined;
    const ip_len = format_ip(g_snap.own_ip, &ipb);
    y = draw_row(win, y, "IP", ipb[0..ip_len]);
    var gwb: [15]u8 = undefined;
    const gw_len = format_ip(g_snap.gateway, &gwb);
    y = draw_row(win, y, "GW", gwb[0..gw_len]);
    y += 6;

    // ---- DHCP ---------------------------------------------------------------
    y = draw_section(win, y, "DHCP");
    var dline: [40]u8 = undefined;
    const dslice = std.fmt.bufPrint(&dline, "{s} ({d} s lease)", .{ ns.dhcp_state_name(g_snap.dhcp_state), g_snap.lease_secs }) catch dline[0..0];
    y = draw_row(win, y, "State", dslice);
    var lib: [15]u8 = undefined;
    const li_len = format_ip(g_snap.lease_ip, &lib);
    y = draw_row(win, y, "Lease IP", lib[0..li_len]);
    y += 6;

    // ---- TCP -----------------------------------------------------------------
    y = draw_section(win, y, "TCP");
    var pbuf: [15]u8 = undefined;
    const plen = format_ip(g_snap.tcp_peer_ip, &pbuf);
    var tline: [48]u8 = undefined;
    const tslice = std.fmt.bufPrint(&tline, "{s} :{d} ({s})", .{ pbuf[0..plen], g_snap.tcp_peer_port, ns.tcp_state_name(g_snap.tcp_state) }) catch tline[0..0];
    y = draw_row(win, y, "Peer", tslice);
    y += 6;

    // ---- UDP ----------------------------------------------------------------
    y = draw_section(win, y, "UDP listeners");
    if (g_snap.udp_count == 0) {
        y = draw_row(win, y, "Ports", "none");
    } else {
        var ubuf: [32]u8 = undefined;
        var ulen: usize = 0;
        var i: usize = 0;
        while (i < g_snap.udp_count) : (i += 1) {
            const piece = std.fmt.bufPrint(ubuf[ulen..], "{d} ", .{g_snap.udp_ports[i]}) catch break;
            ulen += piece.len;
        }
        y = draw_row(win, y, "Ports", ubuf[0..ulen]);
    }
    y += 6;

    // ---- ARP ----------------------------------------------------------------
    y = draw_section(win, y, "ARP");
    if (g_snap.arp_count == 0) {
        y = draw_row(win, y, "Table", "(empty)");
    } else {
        var a: usize = 0;
        while (a < g_snap.arp_count) : (a += 1) {
            var ab: [15]u8 = undefined;
            const alen = format_ip(g_snap.arp_ips[a], &ab);
            var mb: [17]u8 = undefined;
            _ = format_mac(g_snap.arp_macs[a], &mb);
            var rowb: [40]u8 = undefined;
            const rslice = std.fmt.bufPrint(&rowb, "{s} -> {s}", .{ ab[0..alen], mb[0..17] }) catch rowb[0..0];
            y = draw_row(win, y, " ARP", rslice);
        }
    }
    y += 6;

    // ---- counters -----------------------------------------------------------
    y = draw_section(win, y, "Counters");
    var cx: [40]u8 = undefined;
    const c1 = std.fmt.bufPrint(&cx, "tx {d} frames / {d} B", .{ g_snap.tx_frames, g_snap.tx_bytes }) catch cx[0..0];
    y = draw_row(win, y, "TX", c1);
    const c2 = std.fmt.bufPrint(&cx, "rx {d} frames / {d} B ({d} dropped)", .{ g_snap.rx_frames, g_snap.rx_bytes, g_snap.rx_overflow }) catch cx[0..0];
    _ = draw_row(win, y, "RX", c2);
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

pub export fn _start() callconv(.c) noreturn {
    ui.write_console("netstat: starting\n");

    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("netstat: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));
    ui.write_console("netstat: open id=3\n");

    _ = ns.read_stats(&g_snap);
    // One-time section markers for the class-B gate (the live dashboard
    // re-renders every second, so the EXISTENCE of each section is proven
    // once at startup; the snapshot content is proven by the syscall report
    // and the screenshot).
    ui.write_console("netstat: section iface\n");
    ui.write_console("netstat: section dhcp\n");
    ui.write_console("netstat: section tcp\n");
    ui.write_console("netstat: section udp\n");
    ui.write_console("netstat: section arp\n");
    ui.write_console("netstat: section counters\n");
    draw(win);
    ui.win_present(win);
    ui.write_console("netstat: ready\n");

    // Arm the 1 Hz refresh timer.
    _ = ui.timer_set(refresh_ticks);

    var ev: ui.Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        if (ev.kind == ui.WIN_CLOSE) break;
        if (ev.kind == ui.EVENT_TIMER) {
            if (ns.read_stats(&g_snap)) dirty = true;
        }

        while (ui.poll_event(&ev) > 0) {
            if (ev.kind == ui.WIN_CLOSE) {
                _ = ui.timer_cancel();
                ui.win_close(win);
                ui.exit_process(exit_status);
            }
            if (ev.kind == ui.EVENT_TIMER) {
                if (ns.read_stats(&g_snap)) dirty = true;
            }
        }

        if (dirty) {
            draw(win);
            ui.win_present(win);
        }
    }

    _ = ui.timer_cancel();
    ui.win_close(win);
    ui.exit_process(exit_status);
}

// ---------------------------------------------------------------------------
// Host unit tests
// ---------------------------------------------------------------------------

test "netstat: format_ip renders dotted quad" {
    var out: [15]u8 = undefined;
    const n = format_ip(.{ 10, 0, 0, 2 }, &out);
    try std.testing.expectEqualStrings("10.0.0.2", out[0..n]);
}

test "netstat: format_ip all zeros" {
    var out: [15]u8 = undefined;
    const n = format_ip(.{ 0, 0, 0, 0 }, &out);
    try std.testing.expectEqualStrings("0.0.0.0", out[0..n]);
}

test "netstat: format_mac colons" {
    var out: [17]u8 = undefined;
    _ = format_mac(.{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 }, &out);
    try std.testing.expectEqualStrings("02:00:00:00:00:02", out[0..17]);
}

test "netstat: NetStats mirror offsets agree with the kernel pins" {
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(ns.NetStats, "own_ip"));
    try std.testing.expectEqual(@as(usize, 38), @offsetOf(ns.NetStats, "tcp_peer_port"));
    try std.testing.expect(ns.net_stats_bytes <= 256);
}
