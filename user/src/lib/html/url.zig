//! VirelaiOS HTML URL helpers (M-web S4/S5, ADR 0028).
//!
//! Pure: relative href resolution, HTTP URL parse, HTTP/1.x status line,
//! GET request formatting, and a compact DNS A-record encode/parse so DOC
//! can fetch `http://host/path` without importing DNS.BIN (which exports
//! `_start`). No framebuffer, no syscalls.

const std = @import("std");

pub const max_host: usize = 128;
pub const max_path: usize = 96;

pub const Scheme = enum { none, http, other };

pub const ParsedUrl = struct {
    scheme: Scheme = .none,
    host: []const u8 = &.{},
    port: u16 = 80,
    path: []const u8 = "/",
    ipv4: ?[4]u8 = null,
};

pub fn isHttpUrl(s: []const u8) bool {
    return startsWithCi(s, "http://");
}

pub fn isExternalUrl(s: []const u8) bool {
    return startsWithCi(s, "http://") or startsWithCi(s, "https://") or startsWithCi(s, "mailto:");
}

pub fn parseHttpUrl(raw: []const u8) ?ParsedUrl {
    if (!startsWithCi(raw, "http://")) return null;
    const rest = raw[7..];
    if (rest.len == 0) return null;

    var host_end: usize = 0;
    while (host_end < rest.len and rest[host_end] != '/' and rest[host_end] != ':') : (host_end += 1) {}
    if (host_end == 0) return null;
    const host = rest[0..host_end];

    var port: u16 = 80;
    var path_at = host_end;
    if (host_end < rest.len and rest[host_end] == ':') {
        var i = host_end + 1;
        var n: u32 = 0;
        var digits: usize = 0;
        while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') : (i += 1) {
            n = n * 10 + (rest[i] - '0');
            digits += 1;
            if (n > 65535 or digits > 5) return null;
        }
        if (digits == 0) return null;
        port = @intCast(n);
        path_at = i;
    }
    const path: []const u8 = if (path_at >= rest.len) "/" else rest[path_at..];
    return .{
        .scheme = .http,
        .host = host,
        .port = port,
        .path = if (path.len == 0) "/" else path,
        .ipv4 = parseIpv4(host),
    };
}

pub fn parseIpv4(text: []const u8) ?[4]u8 {
    var parts: [4]u8 = .{ 0, 0, 0, 0 };
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
            parts[part_idx] = @intCast(cur);
            part_idx += 1;
            cur = 0;
            digits = 0;
        } else return null;
    }
    if (digits == 0 or part_idx != 3) return null;
    parts[3] = @intCast(cur);
    return parts;
}

pub fn ipv4ToU32(ip: [4]u8) u32 {
    return (@as(u32, ip[0]) << 24) | (@as(u32, ip[1]) << 16) | (@as(u32, ip[2]) << 8) | ip[3];
}

/// Directory of a document path (`/host/PAGE.HTML` → `/host`). Bare names
/// yield `"."`.
pub fn dirname(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') {
            if (i == 0) return path[0..1];
            return path[0..i];
        }
    }
    return ".";
}

/// Resolve `href` against the directory of `base_path`. Returns the number of
/// bytes written to `out`, or null if the result would not fit / is empty.
/// Fragments (`#...`) are stripped. `http://` and other external URLs are
/// copied through unchanged (S5 consumes them).
pub fn resolveHref(base_path: []const u8, href: []const u8, out: []u8) ?[]const u8 {
    var target = href;
    if (std.mem.indexOfScalar(u8, target, '#')) |hash| {
        target = target[0..hash];
    }
    if (target.len == 0) return null;
    if (isExternalUrl(target)) {
        if (target.len > out.len) return null;
        @memcpy(out[0..target.len], target);
        return out[0..target.len];
    }
    if (target[0] == '/') {
        if (target.len > out.len) return null;
        @memcpy(out[0..target.len], target);
        return out[0..target.len];
    }

    var dir = dirname(base_path);
    var rest = target;
    while (rest.len >= 2 and rest[0] == '.' and rest[1] == '/') {
        rest = rest[2..];
    }
    while (rest.len >= 3 and rest[0] == '.' and rest[1] == '.' and rest[2] == '/') {
        dir = dirname(dir);
        rest = rest[3..];
    }
    if (std.mem.eql(u8, rest, "..")) {
        dir = dirname(dir);
        rest = &.{};
    } else if (rest.len >= 2 and rest[0] == '.' and rest[1] == '.' and rest.len == 2) {
        dir = dirname(dir);
        rest = &.{};
    }

    if (rest.len == 0) {
        if (dir.len > out.len) return null;
        @memcpy(out[0..dir.len], dir);
        return out[0..dir.len];
    }
    if (std.mem.eql(u8, dir, ".")) {
        if (rest.len > out.len) return null;
        @memcpy(out[0..rest.len], rest);
        return out[0..rest.len];
    }
    const need = dir.len + 1 + rest.len;
    if (need > out.len) return null;
    @memcpy(out[0..dir.len], dir);
    out[dir.len] = '/';
    @memcpy(out[dir.len + 1 .. need], rest);
    return out[0..need];
}

/// Index one past `\r\n\r\n`, or null if the terminator is not yet present.
pub fn headerEnd(buf: []const u8) ?usize {
    if (buf.len < 4) return null;
    var i: usize = 0;
    while (i + 3 < buf.len) : (i += 1) {
        if (buf[i] == '\r' and buf[i + 1] == '\n' and buf[i + 2] == '\r' and buf[i + 3] == '\n') {
            return i + 4;
        }
    }
    return null;
}

/// HTTP status code from a response prefix, or null if the line is incomplete
/// / not HTTP.
pub fn parseStatusCode(buf: []const u8) ?u16 {
    if (!startsWithCi(buf, "HTTP/")) return null;
    var i: usize = 5;
    while (i < buf.len and buf[i] != ' ') : (i += 1) {}
    if (i >= buf.len or buf[i] != ' ') return null;
    i += 1;
    if (i + 3 > buf.len) return null;
    var code: u16 = 0;
    var d: usize = 0;
    while (d < 3) : (d += 1) {
        const c = buf[i + d];
        if (c < '0' or c > '9') return null;
        code = code * 10 + (c - '0');
    }
    return code;
}

/// Format `GET {path} HTTP/1.0` into `out`. Returns the written slice.
pub fn formatGetRequest(out: []u8, host: []const u8, path: []const u8) ?[]const u8 {
    const p = if (path.len == 0) "/" else path;
    return std.fmt.bufPrint(out, "GET {s} HTTP/1.0\r\nHost: {s}\r\nUser-Agent: VirelaiOS/1.0\r\n\r\n", .{ p, host }) catch null;
}

pub fn htmlNameForMarkdown(name: []const u8, out: []u8) ?[]const u8 {
    const stem = if (std.mem.endsWith(u8, name, ".md") or std.mem.endsWith(u8, name, ".MD"))
        name[0 .. name.len - 3]
    else if (std.mem.endsWith(u8, name, ".txt") or std.mem.endsWith(u8, name, ".TXT") or
        std.mem.endsWith(u8, name, ".markdown"))
    blk: {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse break :blk name;
        break :blk name[0..dot];
    } else return null;
    const need = stem.len + 5;
    if (need > out.len) return null;
    @memcpy(out[0..stem.len], stem);
    @memcpy(out[stem.len..need], ".html");
    return out[0..need];
}

pub fn isMarkdownName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") or std.mem.endsWith(u8, name, ".MD") or
        std.mem.endsWith(u8, name, ".markdown") or std.mem.endsWith(u8, name, ".txt") or
        std.mem.endsWith(u8, name, ".TXT");
}

// ---------------------------------------------------------------------------
// DNS A-record (copied shape of dns.zig, host-tested, no `_start`)
// ---------------------------------------------------------------------------

pub const DnsError = error{
    InvalidName,
    BufferTooSmall,
    MalformedResponse,
    IdMismatch,
    NonZeroRCode,
    NoAnswer,
};

pub fn encodeDnsQuery(buf: []u8, id: u16, hostname: []const u8) DnsError!usize {
    if (hostname.len == 0 or hostname.len > max_host) return DnsError.InvalidName;
    const needed = 12 + hostname.len + 2 + 4;
    if (buf.len < needed) return DnsError.BufferTooSmall;

    std.mem.writeInt(u16, buf[0..2], id, .big);
    std.mem.writeInt(u16, buf[2..4], 0x0100, .big); // RD
    std.mem.writeInt(u16, buf[4..6], 1, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 0, .big);
    std.mem.writeInt(u16, buf[10..12], 0, .big);

    var off: usize = 12;
    var start: usize = 0;
    while (start < hostname.len) {
        var end = start;
        while (end < hostname.len and hostname[end] != '.') : (end += 1) {}
        const label_len = end - start;
        if (label_len == 0 or label_len > 63) return DnsError.InvalidName;
        buf[off] = @truncate(label_len);
        off += 1;
        @memcpy(buf[off .. off + label_len], hostname[start..end]);
        off += label_len;
        start = if (end < hostname.len and hostname[end] == '.') end + 1 else end;
    }
    buf[off] = 0;
    off += 1;
    std.mem.writeInt(u16, buf[off..][0..2], 1, .big); // A
    off += 2;
    std.mem.writeInt(u16, buf[off..][0..2], 1, .big); // IN
    off += 2;
    return off;
}

pub fn parseDnsA(packet: []const u8, expected_id: u16) DnsError![4]u8 {
    if (packet.len < 12) return DnsError.MalformedResponse;
    const id = std.mem.readInt(u16, packet[0..2], .big);
    if (id != expected_id) return DnsError.IdMismatch;
    const flags = std.mem.readInt(u16, packet[2..4], .big);
    if ((flags & 0x8000) == 0) return DnsError.MalformedResponse;
    if ((flags & 0x000F) != 0) return DnsError.NonZeroRCode;
    const qdcount = std.mem.readInt(u16, packet[4..6], .big);
    const ancount = std.mem.readInt(u16, packet[6..8], .big);
    if (ancount == 0) return DnsError.NoAnswer;

    var off: usize = 12;
    var q: usize = 0;
    while (q < qdcount) : (q += 1) {
        off = try skipDnsName(packet, off);
        if (off + 4 > packet.len) return DnsError.MalformedResponse;
        off += 4;
    }
    var a: usize = 0;
    while (a < ancount and off < packet.len) : (a += 1) {
        off = try skipDnsName(packet, off);
        if (off + 10 > packet.len) return DnsError.MalformedResponse;
        const atype = std.mem.readInt(u16, packet[off..][0..2], .big);
        const aclass = std.mem.readInt(u16, packet[off + 2 ..][0..2], .big);
        const rdlength = std.mem.readInt(u16, packet[off + 8 ..][0..2], .big);
        off += 10;
        if (off + rdlength > packet.len) return DnsError.MalformedResponse;
        if (atype == 1 and aclass == 1 and rdlength == 4) {
            var ip: [4]u8 = undefined;
            @memcpy(&ip, packet[off .. off + 4]);
            return ip;
        }
        off += rdlength;
    }
    return DnsError.NoAnswer;
}

fn skipDnsName(packet: []const u8, start_offset: usize) DnsError!usize {
    var off = start_offset;
    var hops: usize = 0;
    while (off < packet.len and hops < 32) : (hops += 1) {
        const len = packet[off];
        if (len == 0) return off + 1;
        if ((len & 0xC0) == 0xC0) {
            if (off + 2 > packet.len) return DnsError.MalformedResponse;
            return off + 2;
        }
        if ((len & 0xC0) == 0) {
            off += 1 + @as(usize, len);
        } else return DnsError.MalformedResponse;
    }
    return DnsError.MalformedResponse;
}

fn startsWithCi(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

test "html url: parse dotted http url" {
    const u = parseHttpUrl("http://10.0.0.2:8080/docs/a.html").?;
    try std.testing.expectEqualStrings("10.0.0.2", u.host);
    try std.testing.expectEqual(@as(u16, 8080), u.port);
    try std.testing.expectEqualStrings("/docs/a.html", u.path);
    try std.testing.expectEqual(@as(u8, 10), u.ipv4.?[0]);
    try std.testing.expect(parseHttpUrl("https://example.com/") == null);
    try std.testing.expect(isHttpUrl("HTTP://10.0.0.2/"));
}

test "html url: resolve relative hrefs" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/host/other.html",
        resolveHref("/host/PAGE.HTML", "other.html", &buf).?,
    );
    try std.testing.expectEqualStrings(
        "/host/x.html",
        resolveHref("/host/PAGE.HTML", "./x.html", &buf).?,
    );
    try std.testing.expectEqualStrings(
        "/host/x.html",
        resolveHref("/host/sub/PAGE.HTML", "../x.html", &buf).?,
    );
    try std.testing.expectEqualStrings(
        "/abs.html",
        resolveHref("/host/PAGE.HTML", "/abs.html", &buf).?,
    );
    try std.testing.expectEqualStrings(
        "http://10.0.0.2/a.html",
        resolveHref("/host/PAGE.HTML", "http://10.0.0.2/a.html", &buf).?,
    );
    try std.testing.expect(resolveHref("/host/PAGE.HTML", "#top", &buf) == null);
}

test "html url: status line and header terminator" {
    const resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<body>";
    try std.testing.expectEqual(@as(u16, 200), parseStatusCode(resp).?);
    try std.testing.expectEqual(@as(?u16, 404), parseStatusCode("HTTP/1.0 404 Not Found\r\n"));
    try std.testing.expect(parseStatusCode("not http") == null);
    try std.testing.expectEqual(@as(usize, 44), headerEnd(resp).?);
}

test "html url: GET request and markdown names" {
    var buf: [160]u8 = undefined;
    const req = formatGetRequest(&buf, "10.0.0.2", "/page.html").?;
    try std.testing.expect(std.mem.indexOf(u8, req, "GET /page.html HTTP/1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Host: 10.0.0.2") != null);
    try std.testing.expect(isMarkdownName("notes.md"));
    try std.testing.expectEqualStrings("notes.html", htmlNameForMarkdown("notes.md", &buf).?);
    try std.testing.expectEqualStrings("a.html", htmlNameForMarkdown("a.txt", &buf).?);
}

test "html url: dns query round-trip of the QNAME" {
    var q: [256]u8 = undefined;
    const n = try encodeDnsQuery(&q, 0x1234, "example.com");
    try std.testing.expect(n > 12);
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, q[0..2], .big));
    // QNAME: 7example3com0
    try std.testing.expectEqual(@as(u8, 7), q[12]);
    try std.testing.expectEqualStrings("example", q[13..20]);
}
