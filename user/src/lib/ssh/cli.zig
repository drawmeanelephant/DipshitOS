//! M51 SSH4 (#1171, ADR 0025 D2): the `SSH.BIN` command-line grammar.
//!
//! `SSH.BIN [user@]host[:port] [command ...]` — pure parsing, no syscalls,
//! so the whole grammar is class-A host-tested.
//!
//! - `host` must be a **numeric IPv4 literal** (the gate pins an IP). DNS
//!   resolution is deliberately deferred: a hostname fails usage here rather
//!   than silently dialing nothing (ADR 0025 D8 / the scoping note).
//! - `user` defaults to `virelai` (the guest's principal name in the M50
//!   key-store story); `port` defaults to 22.
//! - `command` is the remaining argv tokens joined by single spaces into the
//!   caller's `cmd_buf`. No command selects the interactive `shell` mode.
//! - The host text is returned verbatim for the `SSH/KNOWN_HOSTS` pin lookup,
//!   so `host:port` in the file is compared against what the user typed.

const std = @import("std");

pub const default_user = "virelai";
pub const default_port: u16 = 22;
pub const user_max: usize = 64;
pub const host_max: usize = 255;
pub const cmd_max: usize = 512;
pub const target_max: usize = user_max + host_max + 8;

pub const Target = struct {
    /// The SSH user name (borrows the CLI arg, or `default_user`).
    user: []const u8,
    /// The host text as the user typed it (a numeric IPv4 literal), for the
    /// pin lookup.
    host: []const u8,
    /// The parsed IPv4 address (big-endian u32, the `sys_tcp_connect` shape).
    ip: u32,
    port: u16 = default_port,
    /// The joined remote command, or null for `shell`.
    cmd: ?[]const u8 = null,
};

/// Parse `args[0]` as `[user@]host[:port]` and `args[1..]` as the command.
/// Returns null on any grammar error (the caller prints usage).
pub fn parse(args: []const []const u8, cmd_buf: []u8) ?Target {
    if (args.len == 0) return null;

    var user: []const u8 = default_user;
    var rest = args[0];

    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        if (at == 0 or at > user_max) return null;
        user = rest[0..at];
        rest = rest[at + 1 ..];
    }

    var port: u16 = default_port;
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
        const port_text = rest[colon + 1 ..];
        port = parsePort(port_text) orelse return null;
        rest = rest[0..colon];
    }
    if (rest.len == 0 or rest.len > host_max) return null;
    const host = rest;
    const ip = parseIpv4(host) orelse return null;
    if (user.len == 0 or user.len > user_max) return null;

    var cmd: ?[]const u8 = null;
    if (args.len > 1) {
        var w: usize = 0;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const part = args[i];
            if (part.len > cmd_max) return null;
            if (i != 1) {
                if (w >= cmd_buf.len) return null;
                cmd_buf[w] = ' ';
                w += 1;
            }
            if (w + part.len > cmd_buf.len) return null;
            @memcpy(cmd_buf[w .. w + part.len], part);
            w += part.len;
        }
        cmd = cmd_buf[0..w];
    }

    return .{ .user = user, .host = host, .ip = ip, .port = port, .cmd = cmd };
}

/// Strict dotted-quad: exactly four 1..3-digit decimal octets, each ≤ 255.
pub fn parseIpv4(text: []const u8) ?u32 {
    if (text.len == 0 or text.len > 15) return null;
    var octets: [4]u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part| {
        if (n == 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        var v: u16 = 0;
        for (part) |c| {
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
        }
        if (v > 255) return null;
        octets[n] = @intCast(v);
        n += 1;
    }
    if (n != 4) return null;
    return (@as(u32, octets[0]) << 24) | (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) | octets[3];
}

/// `1..65535`, decimal, no sign/whitespace.
pub fn parsePort(text: []const u8) ?u16 {
    if (text.len == 0 or text.len > 5) return null;
    var v: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        if (v > 65535) return null;
    }
    if (v == 0) return null;
    return @intCast(v);
}

// ---------------------------------------------------------------------------
// Host tests (class A; pure)
// ---------------------------------------------------------------------------

test "cli: default user/port, numeric IPv4, command join" {
    var buf: [cmd_max]u8 = undefined;
    const t = parse(&.{"10.0.0.2"}, &buf).?;
    try std.testing.expectEqualStrings(default_user, t.user);
    try std.testing.expectEqualStrings("10.0.0.2", t.host);
    try std.testing.expectEqual(@as(u32, 0x0a000002), t.ip);
    try std.testing.expectEqual(@as(u16, 22), t.port);
    try std.testing.expect(t.cmd == null);

    const t2 = parse(&.{ "alice@192.168.1.9:2222", "uname", "-a" }, &buf).?;
    try std.testing.expectEqualStrings("alice", t2.user);
    try std.testing.expectEqualStrings("192.168.1.9", t2.host);
    try std.testing.expectEqual(@as(u32, 0xc0a80109), t2.ip);
    try std.testing.expectEqual(@as(u16, 2222), t2.port);
    try std.testing.expectEqualStrings("uname -a", t2.cmd.?);

    // A single-token command.
    const t3 = parse(&.{ "10.0.0.2", "id" }, &buf).?;
    try std.testing.expectEqualStrings("id", t3.cmd.?);
}

test "cli: malformed targets are refused (hostnames deferred, not guessed)" {
    var buf: [cmd_max]u8 = undefined;
    try std.testing.expect(parse(&.{}, &buf) == null);
    try std.testing.expect(parse(&.{"host.example"}, &buf) == null);
    try std.testing.expect(parse(&.{"10.0.0"}, &buf) == null);
    try std.testing.expect(parse(&.{"10.0.0.2.3"}, &buf) == null);
    try std.testing.expect(parse(&.{"256.0.0.1"}, &buf) == null);
    try std.testing.expect(parse(&.{"10.0.0.x"}, &buf) == null);
    try std.testing.expect(parse(&.{"@"}, &buf) == null);
    try std.testing.expect(parse(&.{"@10.0.0.2"}, &buf) == null);
    try std.testing.expect(parse(&.{"10.0.0.2:"}, &buf) == null);
    try std.testing.expect(parse(&.{"10.0.0.2:0"}, &buf) == null);
    try std.testing.expect(parse(&.{"10.0.0.2:65536"}, &buf) == null);
    try std.testing.expect(parse(&.{"10.0.0.2:22x"}, &buf) == null);
    try std.testing.expect(parse(&.{""}, &buf) == null);
    // The user part may not be empty or over-long.
    var long_user: [user_max + 2]u8 = undefined;
    @memset(&long_user, 'a');
    var arg_buf: [user_max + 2 + 16]u8 = undefined;
    const arg = std.fmt.bufPrint(&arg_buf, "{s}@10.0.0.2", .{long_user}) catch unreachable;
    try std.testing.expect(parse(&.{arg}, &buf) == null);
}

test "cli: the command buffer is bounded, never truncated" {
    var small: [4]u8 = undefined;
    try std.testing.expect(parse(&.{ "10.0.0.2", "uname" }, &small) == null);
    var exact: [5]u8 = undefined;
    try std.testing.expectEqualStrings("uname", parse(&.{ "10.0.0.2", "uname" }, &exact).?.cmd.?);
}

test "cli: parseIpv4 and parsePort bounds" {
    try std.testing.expectEqual(@as(u32, 0), parseIpv4("0.0.0.0").?);
    try std.testing.expectEqual(@as(u32, 0xffffffff), parseIpv4("255.255.255.255").?);
    try std.testing.expect(parseIpv4("") == null);
    try std.testing.expect(parseIpv4("1.2.3.4.5") == null);
    try std.testing.expectEqual(@as(u16, 1), parsePort("1").?);
    try std.testing.expectEqual(@as(u16, 65535), parsePort("65535").?);
    try std.testing.expect(parsePort("0") == null);
    try std.testing.expect(parsePort("") == null);
    try std.testing.expect(parsePort("-1") == null);
}
