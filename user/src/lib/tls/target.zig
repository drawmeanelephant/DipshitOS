//! Target resolution for the HTTPS consumer (card TLS13-C11).
//!
//! Pure, `ui`-free and therefore host-testable: the consumer binary cannot be
//! unit-tested on the host because it links the kernel ABI, but the rules that
//! decide *what it dials* should not be out of reach of a test.
//!
//! An IPv4 literal is required rather than a hostname: DNS is deliberately a
//! later slice, and `fetch.zig` makes the same choice. A name that is not a
//! dotted quad is rejected rather than resolved to something arbitrary.

const std = @import("std");

/// The host gateway, the same destination `fetch.zig` and `download.zig` use.
pub const default_ip: u32 = 0x0a000002;
pub const default_port: u16 = 443;
/// The name the peer's certificate must match (SNI + hostname check).
pub const default_name: []const u8 = "leaf.example.com";

pub const Target = struct {
    ip: u32,
    port: u16,
    name: []const u8,
};

/// Parse a dotted-quad IPv4 literal. Rejects empty octets (including a
/// trailing dot), more than four, values over 255, leading junk, and names.
pub fn parseIpv4(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var acc: u32 = 0;
    var octets: usize = 0;
    var octet: u32 = 0;
    var have = false;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == '.') {
            if (!have) return null;
            if (octets == 4) return null;
            acc = (acc << 8) | octet;
            octets += 1;
            octet = 0;
            have = false;
            continue;
        }
        const c = s[i];
        if (c < '0' or c > '9') return null;
        octet = octet * 10 + (c - '0');
        if (octet > 255) return null;
        have = true;
    }
    if (octets != 4) return null;
    return acc;
}

/// Parse a decimal port in 1..65535. Port 0 is not a destination.
pub fn parsePort(s: []const u8) ?u16 {
    if (s.len == 0 or s.len > 5) return null;
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    if (v == 0 or v > 65535) return null;
    return @intCast(v);
}

/// Resolve the target from the argument vector, copying the name into
/// `name_out` so the returned slice does not alias the kernel's argv block.
pub fn resolve(args: []const []const u8, name_out: []u8) ?Target {
    const ip = if (args.len >= 1) parseIpv4(args[0]) orelse return null else default_ip;
    const port = if (args.len >= 2) parsePort(args[1]) orelse return null else default_port;
    const name = if (args.len >= 3) args[2] else default_name;
    if (name.len == 0 or name.len > name_out.len) return null;
    @memcpy(name_out[0..name.len], name);
    return .{ .ip = ip, .port = port, .name = name_out[0..name.len] };
}

test "target: dotted-quad parsing accepts only real addresses" {
    try std.testing.expectEqual(@as(?u32, 0x0a000002), parseIpv4("10.0.0.2"));
    try std.testing.expectEqual(@as(?u32, 0x7f000001), parseIpv4("127.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 0xffffffff), parseIpv4("255.255.255.255"));
    try std.testing.expectEqual(@as(?u32, 0x00000000), parseIpv4("0.0.0.0"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4(""));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4("10.0.0"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4("10.0.0.2.5"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4("256.0.0.1"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4("10.0.0."));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4(".10.0.0.2"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4("10..0.2"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4("example.com"));
}

test "target: port parsing rejects 0, overflow and junk" {
    try std.testing.expectEqual(@as(?u16, 443), parsePort("443"));
    try std.testing.expectEqual(@as(?u16, 1), parsePort("1"));
    try std.testing.expectEqual(@as(?u16, 65535), parsePort("65535"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("0"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("65536"));
    try std.testing.expectEqual(@as(?u16, null), parsePort(""));
    try std.testing.expectEqual(@as(?u16, null), parsePort("44a"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("999999"));
}

test "target: defaults, overrides, and refusal of bad input" {
    var buf: [128]u8 = undefined;
    const d = resolve(&.{}, &buf).?;
    try std.testing.expectEqual(default_ip, d.ip);
    try std.testing.expectEqual(default_port, d.port);
    try std.testing.expectEqualStrings("leaf.example.com", d.name);

    var buf2: [128]u8 = undefined;
    const o = resolve(&.{ "127.0.0.1", "24533" }, &buf2).?;
    try std.testing.expectEqual(@as(u32, 0x7f000001), o.ip);
    try std.testing.expectEqual(@as(u16, 24533), o.port);
    // The name still defaults when only the address is given.
    try std.testing.expectEqualStrings("leaf.example.com", o.name);

    var buf3: [128]u8 = undefined;
    const n = resolve(&.{ "10.0.0.2", "443", "other.example.com" }, &buf3).?;
    try std.testing.expectEqualStrings("other.example.com", n.name);

    var buf4: [128]u8 = undefined;
    try std.testing.expectEqual(@as(?Target, null), resolve(&.{"nope"}, &buf4));
    var buf5: [128]u8 = undefined;
    try std.testing.expectEqual(@as(?Target, null), resolve(&.{ "10.0.0.2", "0" }, &buf5));
    var buf6: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?Target, null), resolve(&.{ "10.0.0.2", "443", "a-very-long-name" }, &buf6));
}
