//! M46 RC3 (#1111) / RC3b (#1104): the shared net-front-end argv parser.
//!
//! Both `SH.BIN` (serial/remote shell) and `TERM.BIN` (windowed shell) accept
//! the same optional front-end argument, fixed by ADR 0020 Amendment B and
//! extended by ADR 0022 D3/D4:
//!
//!     <app>                          -> serial by default (SH) / window (TERM)
//!     <app> net [port] [secret] [allow-ip]
//!
//! `port` defaults to 2323; `secret` is the session's first-line credential
//! (empty = open); `allow-ip` is an optional source-IP allowlist as a
//! big-endian u32. The argv block is the kernel's card-3e 32-byte-per-slot
//! packaging (`argc` in x0, block VA in x1).

const std = @import("std");

/// The default TCP port when `net` gives no port (SH7).
pub const default_port: u16 = 2323;

pub const Args = struct {
    port: u16,
    secret: []const u8 = &.{},
    allow_ip: u32 = 0,
};

/// Read one 32-byte NUL-terminated argv slot from the kernel-packaged block.
pub fn argSlot(block: [*]const u8, i: usize) []const u8 {
    const slot = (block + i * 32)[0..32];
    var n: usize = 0;
    while (n < slot.len and slot[n] != 0) n += 1;
    return slot[0..n];
}

/// Parse a dotted-quad IPv4 into a big-endian u32 (the allowlist wire form).
pub fn parseIpv4(s: []const u8) ?u32 {
    var parts: [4]u8 = undefined;
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |p| {
        if (idx >= 4 or p.len == 0) return null;
        parts[idx] = std.fmt.parseInt(u8, p, 10) catch return null;
        idx += 1;
    }
    if (idx != 4) return null;
    return (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) |
        (@as(u32, parts[2]) << 8) | @as(u32, parts[3]);
}

/// `net [port] [secret] [allow-ip]` — null when the first argument is not
/// `net` (the caller then uses its default front-end). A malformed port or
/// allow-ip also returns null (the caller rejects the attach).
pub fn parse(argc: u64, argv_va: u64) ?Args {
    if (argc == 0 or argv_va == 0) return null;
    const block: [*]const u8 = @ptrFromInt(argv_va);
    if (!std.mem.eql(u8, argSlot(block, 0), "net")) return null;
    var port: u16 = default_port;
    if (argc >= 2) {
        const arg = argSlot(block, 1);
        if (arg.len > 0) port = std.fmt.parseInt(u16, arg, 10) catch return null;
    }
    var secret: []const u8 = &.{};
    if (argc >= 3) secret = argSlot(block, 2);
    var allow_ip: u32 = 0;
    if (argc >= 4) {
        const a = argSlot(block, 3);
        if (a.len > 0) allow_ip = parseIpv4(a) orelse return null;
    }
    return .{ .port = port, .secret = secret, .allow_ip = allow_ip };
}

test "netargs: parse defaults, port, secret, and allow-ip" {
    var block = [_]u8{0} ** 128;
    const write = struct {
        fn f(b: []u8, i: usize, s: []const u8) void {
            @memcpy(b[i * 32 ..][0..s.len], s);
        }
    }.f;
    // Just `net` -> default port, no auth.
    write(&block, 0, "net");
    const a = parse(1, @intFromPtr(&block)).?;
    try std.testing.expectEqual(default_port, a.port);
    try std.testing.expectEqual(@as(usize, 0), a.secret.len);
    try std.testing.expectEqual(@as(u32, 0), a.allow_ip);
    // `net 4444 s3cret 10.0.0.2`.
    @memset(&block, 0);
    write(&block, 0, "net");
    write(&block, 1, "4444");
    write(&block, 2, "s3cret");
    write(&block, 3, "10.0.0.2");
    const b = parse(4, @intFromPtr(&block)).?;
    try std.testing.expectEqual(@as(u16, 4444), b.port);
    try std.testing.expectEqualStrings("s3cret", b.secret);
    try std.testing.expectEqual(@as(u32, 0x0a000002), b.allow_ip);
    // A different first arg is not the net front-end.
    @memset(&block, 0);
    write(&block, 0, "exec");
    try std.testing.expect(parse(1, @intFromPtr(&block)) == null);
    // A bad allow-ip is rejected.
    @memset(&block, 0);
    write(&block, 0, "net");
    write(&block, 1, "4444");
    write(&block, 3, "999.1.1.1");
    try std.testing.expect(parse(4, @intFromPtr(&block)) == null);
}
