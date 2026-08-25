//! DipshitOS PING.BIN — M26 N1 (issue #399, Lane D-NetApps).
//!
//! Sends ICMP echo requests, displays RTT, packet loss, continuous mode.
//! Zero new syscall slots — this first cut is a pure userland CLI that
//! simulates the ping path (validates args, computes stats, drives the
//! existing monitor `net ping` counters in a future kernel wiring). The
//! host-testable pure logic (parse_ip, stats, arg parsing) is pinned so
//! the live gate can later swap the simulate path for a real device
//! round trip without changing the CLI shape.
//!
//! CLI: `exec PING.BIN [-c count] <a.b.c.d>`
//!   -c count: number of pings, 1..100 (default 5)
//!   <a.b.c.d>: dotted IPv4 address
//!   `exec PING.BIN -h` prints help
//!
//! Output shape (grep-able for verify-live-ping.sh):
//!   PING 10.0.0.2 (10.0.0.2): 56 data bytes
//!   64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=1 ms
//!   ...
//!   --- 10.0.0.2 ping statistics ---
//!   5 packets transmitted, 5 packets received, 0% packet loss
//!   round-trip min/avg/max = 1/1/1 ms
//!
//! No heap, no libc, no window — headless EL0 program using
//! sys_write (1), sys_sleep (4), sys_yield (2), sys_exit (3) plus the new
//! ICMP slots 59/60 `sys_ping_send` / `sys_ping_poll` (M26 N1). On the
//! host (non-freestanding test build) the syscalls stub to 0, so the
//! program falls back to the deterministic simulated RTT.

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("lib/ui.zig");

// ---------------------------------------------------------------------------
// Pure logic — host-testable
// ---------------------------------------------------------------------------

pub const default_count: u8 = 5;
pub const max_count: u8 = 100;
pub const exit_ok: u64 = 0;
pub const exit_usage: u64 = 1;

/// Parse dotted IPv4 "a.b.c.d" into bytes. Rejects leading zeros? No,
/// just decimal 0..255 per octet, exactly 3 dots.
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
            if (digits == 0) return null;
            if (part_idx >= 3) return null;
            parts[part_idx] = cur;
            part_idx += 1;
            cur = 0;
            digits = 0;
        } else return null;
    }
    if (digits == 0) return null;
    if (part_idx != 3) return null;
    parts[3] = cur;
    return .{
        @intCast(parts[0]),
        @intCast(parts[1]),
        @intCast(parts[2]),
        @intCast(parts[3]),
    };
}

pub fn format_ip(ip: [4]u8, out: []u8) []const u8 {
    const s = std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch return out[0..0];
    return s;
}

pub const PingArgs = struct {
    ip: [4]u8,
    count: u8,
    ip_str: []const u8,
};

/// Parse CLI args from an array of slices (host test) or from the
/// argv block. Returns null on usage error. First arg may be "-c".
pub fn parse_args_slices(args: []const []const u8) ?PingArgs {
    if (args.len == 0) return null;
    var idx: usize = 0;
    var count: u8 = default_count;
    if (args.len >= 2 and std.mem.eql(u8, args[0], "-c")) {
        const n = parse_u8(args[1]) orelse return null;
        if (n == 0 or n > max_count) return null;
        count = n;
        idx = 2;
    }
    if (args.len - idx != 1) return null;
    const ip_str = args[idx];
    const ip = parse_ipv4(ip_str) orelse return null;
    // Reject -h/--help here so caller can handle help
    if (std.mem.eql(u8, ip_str, "-h") or std.mem.eql(u8, ip_str, "--help")) return null;
    return .{ .ip = ip, .count = count, .ip_str = ip_str };
}

fn parse_u8(text: []const u8) ?u8 {
    if (text.len == 0) return null;
    var v: u16 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        if (v > 255) return null;
    }
    return @intCast(v);
}

pub const Stats = struct {
    sent: u32 = 0,
    received: u32 = 0,
    min_ms: u32 = std.math.maxInt(u32),
    max_ms: u32 = 0,
    sum_ms: u64 = 0,

    pub fn record(self: *Stats, rtt_ms: u32) void {
        self.sent += 1;
        self.received += 1;
        if (rtt_ms < self.min_ms) self.min_ms = rtt_ms;
        if (rtt_ms > self.max_ms) self.max_ms = rtt_ms;
        self.sum_ms += rtt_ms;
    }

    pub fn record_loss(self: *Stats) void {
        self.sent += 1;
    }

    pub fn loss_percent(self: *const Stats) u32 {
        if (self.sent == 0) return 0;
        const lost = self.sent - self.received;
        return lost * 100 / self.sent;
    }

    pub fn avg_ms(self: *const Stats) u32 {
        if (self.received == 0) return 0;
        return @intCast(self.sum_ms / self.received);
    }

    pub fn min(self: *const Stats) u32 {
        if (self.received == 0) return 0;
        return self.min_ms;
    }

    pub fn max(self: *const Stats) u32 {
        if (self.received == 0) return 0;
        return self.max_ms;
    }
};

// ---------------------------------------------------------------------------
// EL0 helpers — console + argv block
// ---------------------------------------------------------------------------

fn cli_arg(block: [*]u8, i: usize) []const u8 {
    const slot = block + i * 32;
    var len: usize = 0;
    while (len < 32 and slot[len] != 0) len += 1;
    return slot[0..len];
}

fn write_line(msg: []const u8) void {
    ui.write_console(msg);
    // ui.write_console doesn't append newline, so caller includes it
}

fn print_help() void {
    ui.write_console("PING.BIN - DipshitOS ICMP ping (M26 N1)\n" ++
        "usage: exec PING.BIN [-c count] <a.b.c.d>\n" ++
        "       exec PING.BIN -h   show this help\n" ++
        "  -c count  number of pings, 1..100 (default 5)\n" ++
        "example: exec PING.BIN -c 5 10.0.0.2\n");
}

fn format_u32(buf: []u8, v: u32) []const u8 {
    var tmp: [12]u8 = undefined;
    var n: usize = 0;
    var vv = v;
    if (vv == 0) {
        tmp[0] = '0';
        n = 1;
    } else {
        while (vv > 0) : (vv /= 10) {
            tmp[n] = @intCast('0' + vv % 10);
            n += 1;
        }
        // reverse
        var i: usize = 0;
        while (i < n / 2) : (i += 1) {
            const t = tmp[i];
            tmp[i] = tmp[n - 1 - i];
            tmp[n - 1 - i] = t;
        }
    }
    const take = @min(n, buf.len);
    @memcpy(buf[0..take], tmp[0..n]);
    return buf[0..take];
}

fn ip_to_u32(ip: [4]u8) u32 {
    return (@as(u32, ip[0]) << 24) | (@as(u32, ip[1]) << 16) | (@as(u32, ip[2]) << 8) | ip[3];
}

// ---------------------------------------------------------------------------
// CLI main — called from _start when argc>0
// ---------------------------------------------------------------------------

fn cli_main(argc: usize, argv_va: u64) noreturn {
    const block: [*]u8 = @ptrFromInt(argv_va);

    // Collect args into slices for parse_args_slices
    var args_buf: [8][]const u8 = undefined;
    var args_len: usize = 0;
    var i: usize = 0;
    while (i < argc and args_len < args_buf.len) : (i += 1) {
        const s = cli_arg(block, i);
        // Check help
        if (std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "--help")) {
            print_help();
            ui.exit_process(exit_ok);
        }
        args_buf[args_len] = s;
        args_len += 1;
    }

    const parsed = parse_args_slices(args_buf[0..args_len]) orelse {
        ui.write_console("ping: usage: exec PING.BIN [-c count] <a.b.c.d>\n");
        ui.exit_process(exit_usage);
    };

    run_ping(parsed);
}

fn run_ping(cfg: PingArgs) noreturn {
    var ip_txt: [16]u8 = undefined;
    const ip_s = format_ip(cfg.ip, &ip_txt);

    // Header
    {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "PING {s} ({s}): 56 data bytes\n", .{ ip_s, ip_s }) catch "";
        ui.write_console(s);
    }

    var stats = Stats{};
    const use_real = builtin.os.tag == .freestanding;
    const ip_u32 = ip_to_u32(cfg.ip);

    var seq: u32 = 1;
    while (seq <= cfg.count) : (seq += 1) {
        var got = false;
        var rtt: u32 = 1 + (seq % 3); // fallback simulated

        if (use_real) {
            const prev_poll = ui.ping_poll();
            const rc = ui.ping_send(ip_u32);
            if (rc == 0) {
                // Poll for pong — up to 50 iterations with yield
                var polls: usize = 0;
                while (polls < 50) : (polls += 1) {
                    const poll = ui.ping_poll();
                    if (poll != 0 and poll != prev_poll) {
                        got = true;
                        rtt = @intCast(polls + 1); // ~10 ms per poll
                        break;
                    }
                    ui.yield_task();
                }
                if (got) {
                    stats.record(rtt);
                } else {
                    stats.record_loss();
                    var buf: [96]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "no answer from {s}: icmp_seq={d}\n", .{ ip_s, seq }) catch "";
                    ui.write_console(s);
                    if (seq < cfg.count) ui.sleep_ticks(1);
                    continue;
                }
            } else {
                // Send refused — peer not in ARP, no IP, or no device. Honest loss.
                var buf: [96]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "ping: send to {s} failed ({d})\n", .{ ip_s, rc }) catch "";
                ui.write_console(s);
                stats.record_loss();
                if (seq < cfg.count) ui.sleep_ticks(1);
                continue;
            }
        } else {
            stats.record(rtt);
        }

        // Per-ping line — grep-able (real or simulated)
        {
            var buf: [96]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "64 bytes from {s}: icmp_seq={d} ttl=64 time={d} ms\n", .{ ip_s, seq, rtt }) catch "";
            ui.write_console(s);
        }

        // 1-second interval between pings (except after last)
        if (seq < cfg.count) {
            ui.sleep_ticks(1);
        }
    }

    // Footer — statistics
    {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "--- {s} ping statistics ---\n", .{ip_s}) catch "";
        ui.write_console(s);
    }
    {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d} packets transmitted, {d} packets received, {d}% packet loss\n", .{ stats.sent, stats.received, stats.loss_percent() }) catch "";
        ui.write_console(s);
    }
    {
        var buf: [96]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "round-trip min/avg/max = {d}/{d}/{d} ms\n", .{ stats.min(), stats.avg_ms(), stats.max() }) catch "";
        ui.write_console(s);
    }

    ui.exit_process(exit_ok);
}

// ---------------------------------------------------------------------------
// Entry — exec passes argc in x0, argv block VA in x1
// ---------------------------------------------------------------------------

pub export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    if (argc > 0 and argv_va != 0) {
        cli_main(@intCast(argc), argv_va);
    }
    // No args: print help
    print_help();
    ui.exit_process(exit_ok);
}

// ---------------------------------------------------------------------------
// Host tests — pure logic, no device
// ---------------------------------------------------------------------------

test "ping: parse_ipv4 valid" {
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 1 }, parse_ipv4("10.0.0.1").?);
    try std.testing.expectEqual([4]u8{ 192, 168, 64, 5 }, parse_ipv4("192.168.64.5").?);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, parse_ipv4("0.0.0.0").?);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, parse_ipv4("255.255.255.255").?);
}

test "ping: parse_ipv4 invalid" {
    try std.testing.expect(parse_ipv4("") == null);
    try std.testing.expect(parse_ipv4("10.0.0") == null);
    try std.testing.expect(parse_ipv4("10.0.0.1.2") == null);
    try std.testing.expect(parse_ipv4("10.0.0.256") == null);
    try std.testing.expect(parse_ipv4("10.0.0.-1") == null);
    try std.testing.expect(parse_ipv4("abc") == null);
    try std.testing.expect(parse_ipv4("10..0.1") == null);
    try std.testing.expect(parse_ipv4("10.0.0.1 ") == null);
}

test "ping: parse_args defaults" {
    const a = parse_args_slices(&.{"10.0.0.2"}).?;
    try std.testing.expectEqual(@as(u8, 5), a.count);
    try std.testing.expectEqualSlices(u8, "10.0.0.2", a.ip_str);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 2 }, a.ip);
}

test "ping: parse_args -c" {
    const a = parse_args_slices(&.{ "-c", "3", "10.0.0.2" }).?;
    try std.testing.expectEqual(@as(u8, 3), a.count);
    const b = parse_args_slices(&.{ "-c", "1", "10.0.0.1" }).?;
    try std.testing.expectEqual(@as(u8, 1), b.count);
}

test "ping: parse_args errors" {
    try std.testing.expect(parse_args_slices(&.{}) == null);
    try std.testing.expect(parse_args_slices(&.{ "-c", "0", "10.0.0.2" }) == null);
    try std.testing.expect(parse_args_slices(&.{ "-c", "101", "10.0.0.2" }) == null);
    try std.testing.expect(parse_args_slices(&.{ "-c", "abc", "10.0.0.2" }) == null);
    try std.testing.expect(parse_args_slices(&.{ "10.0.0.2", "extra" }) == null);
    try std.testing.expect(parse_args_slices(&.{"not-an-ip"}) == null);
}

test "ping: Stats" {
    var s = Stats{};
    s.record(10);
    s.record(20);
    s.record(30);
    try std.testing.expectEqual(@as(u32, 3), s.sent);
    try std.testing.expectEqual(@as(u32, 3), s.received);
    try std.testing.expectEqual(@as(u32, 10), s.min());
    try std.testing.expectEqual(@as(u32, 30), s.max());
    try std.testing.expectEqual(@as(u32, 20), s.avg_ms());
    try std.testing.expectEqual(@as(u32, 0), s.loss_percent());
    s.record_loss();
    try std.testing.expectEqual(@as(u32, 4), s.sent);
    try std.testing.expectEqual(@as(u32, 25), s.loss_percent()); // 1/4=25%
}

test "ping: format_ip" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("10.0.0.2", format_ip(.{ 10, 0, 0, 2 }, &buf));
}

test "ping: module compiles and exports _start" {
    _ = @intFromPtr(&_start);
}
