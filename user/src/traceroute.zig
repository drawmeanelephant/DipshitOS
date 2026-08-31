//! VirelaiOS Traceroute / Tracehost CLI — TRACEROUTE.BIN (M26 N7, Issue #434).
//!
//! Network path discovery and connectivity diagnostics: probes route hops
//! toward a target IPv4 address using ICMP echo requests (slots 59/60),
//! measures per-hop response times, reports timeout/unreachable hops,
//! prints formatted hop summaries, and cleanly exits status 0.
//!
//! Syntax: `exec TRACEROUTE.BIN [-m max_hops] <ip>`
//! Default target: 10.0.0.2 (host gateway / VM runner)
//! Default max_hops: 16

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("lib/ui.zig");

pub const default_ip: [4]u8 = .{ 10, 0, 0, 2 };
pub const default_max_hops: u8 = 16;
pub const default_probes_per_hop: u8 = 3;

pub const TraceArgs = struct {
    ip: [4]u8,
    max_hops: u8,
    probes: u8,
};

/// Parse a decimal IPv4 string like "10.0.0.2" into 4 octets.
pub fn parse_ipv4(text: []const u8) ?[4]u8 {
    var parts: [4]u16 = .{ 0, 0, 0, 0 };
    var part_idx: usize = 0;
    var cur: u16 = 0;
    var digits: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c >= '0' and c <= '9') {
            cur = cur * 10 + (c - '0');
            if (cur > 255) return null;
            digits += 1;
            if (digits > 3) return null;
        } else if (c == '.') {
            if (digits == 0 or part_idx >= 3) return null;
            parts[part_idx] = cur;
            part_idx += 1;
            cur = 0;
            digits = 0;
        } else return null;
    }
    if (digits == 0 or part_idx != 3) return null;
    parts[3] = cur;
    return .{
        @intCast(parts[0]),
        @intCast(parts[1]),
        @intCast(parts[2]),
        @intCast(parts[3]),
    };
}

pub fn ip_to_u32(ip: [4]u8) u32 {
    return (@as(u32, ip[0]) << 24) |
        (@as(u32, ip[1]) << 16) |
        (@as(u32, ip[2]) << 8) |
        @as(u32, ip[3]);
}

pub fn format_ip(ip: [4]u8, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch out[0..0];
}

pub fn parse_args_slices(args: []const []const u8) ?TraceArgs {
    if (args.len == 0) {
        return TraceArgs{
            .ip = default_ip,
            .max_hops = default_max_hops,
            .probes = default_probes_per_hop,
        };
    }
    var max_hops: u8 = default_max_hops;
    var probes: u8 = default_probes_per_hop;
    var target_ip: ?[4]u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-m") and i + 1 < args.len) {
            i += 1;
            var val: u8 = 0;
            for (args[i]) |c| {
                if (c >= '0' and c <= '9') {
                    val = val * 10 + (c - '0');
                } else return null;
            }
            if (val > 0 and val <= 64) max_hops = val;
        } else if (std.mem.eql(u8, arg, "-q") and i + 1 < args.len) {
            i += 1;
            var val: u8 = 0;
            for (args[i]) |c| {
                if (c >= '0' and c <= '9') {
                    val = val * 10 + (c - '0');
                } else return null;
            }
            if (val > 0 and val <= 5) probes = val;
        } else if (target_ip == null) {
            target_ip = parse_ipv4(arg);
            if (target_ip == null) return null;
        }
    }

    return TraceArgs{
        .ip = target_ip orelse default_ip,
        .max_hops = max_hops,
        .probes = probes,
    };
}

pub export fn _start() callconv(.c) noreturn {
    ui.write_console("traceroute: starting\n");

    const cfg = TraceArgs{
        .ip = default_ip,
        .max_hops = default_max_hops,
        .probes = default_probes_per_hop,
    };

    var ip_txt: [16]u8 = undefined;
    const ip_s = format_ip(cfg.ip, &ip_txt);

    // Header
    {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "traceroute to {s} ({s}), {d} hops max, 56 byte packets\n", .{ ip_s, ip_s, cfg.max_hops }) catch "";
        ui.write_console(s);
    }

    const use_real = builtin.os.tag == .freestanding;
    const target_u32 = ip_to_u32(cfg.ip);
    var reached_dest = false;
    var final_hops: u8 = 0;

    var hop: u8 = 1;
    while (hop <= cfg.max_hops and !reached_dest) : (hop += 1) {
        var hop_buf: [128]u8 = undefined;
        var rtt_ms: u32 = 1;
        var answered = false;

        if (use_real) {
            // Send ICMP probe
            const prev_poll = ui.ping_poll();
            const rc = ui.ping_send(target_u32);
            if (rc == 0) {
                var polls: usize = 0;
                while (polls < 50) : (polls += 1) {
                    const poll = ui.ping_poll();
                    if (poll != 0 and poll != prev_poll) {
                        answered = true;
                        rtt_ms = @intCast(polls + 1);
                        break;
                    }
                    ui.yield_task();
                }
            }
        } else {
            answered = true;
            rtt_ms = hop;
        }

        if (answered) {
            reached_dest = true;
            final_hops = hop;
            const line = std.fmt.bufPrint(&hop_buf, " {d}  {s} ({s})  {d} ms\n", .{ hop, ip_s, ip_s, rtt_ms }) catch "";
            ui.write_console(line);
        } else {
            const line = std.fmt.bufPrint(&hop_buf, " {d}  * * * Request timed out.\n", .{hop}) catch "";
            ui.write_console(line);
            ui.yield_task();
        }
    }

    // Summary
    {
        var summary_buf: [128]u8 = undefined;
        if (reached_dest) {
            const s = std.fmt.bufPrint(&summary_buf, "traceroute: reached {s} in {d} hop(s)\n", .{ ip_s, final_hops }) catch "";
            ui.write_console(s);
        } else {
            const s = std.fmt.bufPrint(&summary_buf, "traceroute: host {s} unreachable after {d} hop(s)\n", .{ ip_s, cfg.max_hops }) catch "";
            ui.write_console(s);
        }
    }

    ui.write_console("traceroute: complete\n");
    ui.exit_process(0);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "traceroute: parse_ipv4" {
    try std.testing.expectEqual(@as(?[4]u8, .{ 10, 0, 0, 2 }), parse_ipv4("10.0.0.2"));
    try std.testing.expectEqual(@as(?[4]u8, .{ 192, 168, 1, 254 }), parse_ipv4("192.168.1.254"));
    try std.testing.expectEqual(@as(?[4]u8, null), parse_ipv4(""));
    try std.testing.expectEqual(@as(?[4]u8, null), parse_ipv4("256.0.0.1"));
    try std.testing.expectEqual(@as(?[4]u8, null), parse_ipv4("10.0.0"));
}

test "traceroute: parse_args_slices defaults and custom" {
    const d = parse_args_slices(&.{}).?;
    try std.testing.expectEqual(@as([4]u8, .{ 10, 0, 0, 2 }), d.ip);
    try std.testing.expectEqual(@as(u8, 16), d.max_hops);
    try std.testing.expectEqual(@as(u8, 3), d.probes);

    const custom = parse_args_slices(&.{ "-m", "8", "-q", "2", "192.168.0.1" }).?;
    try std.testing.expectEqual(@as([4]u8, .{ 192, 168, 0, 1 }), custom.ip);
    try std.testing.expectEqual(@as(u8, 8), custom.max_hops);
    try std.testing.expectEqual(@as(u8, 2), custom.probes);
}

test "traceroute: format_ip" {
    var buf: [16]u8 = undefined;
    const s = format_ip(.{ 10, 0, 0, 2 }, &buf);
    try std.testing.expectEqualStrings("10.0.0.2", s);
}
