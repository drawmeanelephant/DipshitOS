//! VirelaiOS HTTP Download Manager — DOWNLOAD.BIN (M26 N11, Issue #438).
//!
//! Connects over TCP (slot 30), transmits HTTP/1.0 GET request (slot 31),
//! parses HTTP response headers, streams the response body directly into a
//! file on disk via userland filesystem syscalls (slots 23, 25, 26),
//! displays download progress, tears down the connection (slot 33), and exits.
//!
//! Pure helper functions (URL parsing, header splitting, content-length
//! extraction, status-code parsing) are host-tested.

const std = @import("std");
const ui = @import("lib/ui.zig");

pub const default_ip: u32 = 0x0a000002; // 10.0.0.2
pub const default_port: u16 = 80;
pub const default_path: []const u8 = "/file.bin";
pub const default_dest: []const u8 = "/host/DOWNLOAD.OUT"; // M34 HF5 (#739): downloads land in the host folder
pub const header_scratch_max: usize = 1024;

pub const ParsedUrl = struct {
    ip: u32,
    port: u16,
    path: []const u8,
    dest_filename: []const u8,
};

/// Parse a decimal IPv4 string like "10.0.0.2" into big-endian u32.
pub fn parse_ipv4(str: []const u8) ?u32 {
    if (str.len == 0) return null;
    var octets: [4]u8 = undefined;
    var oct_idx: usize = 0;
    var cur_val: u32 = 0;
    var has_digit = false;

    for (str) |c| {
        if (c >= '0' and c <= '9') {
            cur_val = cur_val * 10 + (c - '0');
            if (cur_val > 255) return null;
            has_digit = true;
        } else if (c == '.') {
            if (!has_digit or oct_idx >= 3) return null;
            octets[oct_idx] = @intCast(cur_val);
            oct_idx += 1;
            cur_val = 0;
            has_digit = false;
        } else {
            return null;
        }
    }
    if (!has_digit or oct_idx != 3) return null;
    octets[3] = @intCast(cur_val);

    return (@as(u32, octets[0]) << 24) |
        (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) |
        @as(u32, octets[3]);
}

/// Derive a filename from a URL path, e.g. "/file.bin" -> "FILE.BIN", "/" -> "DOWNLOAD.OUT".
pub fn filename_from_path(path: []const u8) []const u8 {
    if (path.len == 0 or (path.len == 1 and path[0] == '/')) {
        return "DOWNLOAD.OUT";
    }
    var last_slash: ?usize = null;
    for (path, 0..) |c, idx| {
        if (c == '/') last_slash = idx;
    }
    if (last_slash) |idx| {
        const candidate = path[idx + 1 ..];
        if (candidate.len > 0) return candidate;
    }
    return "DOWNLOAD.OUT";
}

/// Parse an HTTP URL like "http://10.0.0.2:80/file.bin" or "10.0.0.2/file.bin".
pub fn parse_url(url_str: []const u8) ?ParsedUrl {
    if (url_str.len == 0) return null;
    var rest = url_str;

    if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
    }

    var host_part: []const u8 = undefined;
    var path_part: []const u8 = "/";

    if (std.mem.indexOfScalar(u8, rest, '/')) |slash_idx| {
        host_part = rest[0..slash_idx];
        if (rest.len > slash_idx) {
            path_part = rest[slash_idx..];
        }
    } else {
        host_part = rest;
    }

    var ip_part = host_part;
    var port: u16 = default_port;

    if (std.mem.indexOfScalar(u8, host_part, ':')) |colon_idx| {
        ip_part = host_part[0..colon_idx];
        const port_str = host_part[colon_idx + 1 ..];
        var p: u32 = 0;
        for (port_str) |c| {
            if (c >= '0' and c <= '9') {
                p = p * 10 + (c - '0');
                if (p > 65535) return null;
            } else {
                return null;
            }
        }
        if (p == 0) return null;
        port = @intCast(p);
    }

    const ip = parse_ipv4(ip_part) orelse default_ip;
    const dest = filename_from_path(path_part);

    return ParsedUrl{
        .ip = ip,
        .port = port,
        .path = path_part,
        .dest_filename = dest,
    };
}

/// Find the end of HTTP header block (`\r\n\r\n`). Returns index 1 past terminator.
pub fn find_header_end(buf: []const u8) ?usize {
    if (buf.len < 4) return null;
    var i: usize = 0;
    while (i + 3 < buf.len) : (i += 1) {
        if (buf[i] == '\r' and buf[i + 1] == '\n' and buf[i + 2] == '\r' and buf[i + 3] == '\n') {
            return i + 4;
        }
    }
    return null;
}

/// Parse HTTP status code from the response line (e.g. "HTTP/1.0 200 OK" -> 200).
pub fn parse_status_code(buf: []const u8) ?u16 {
    const first_line_end = std.mem.indexOf(u8, buf, "\r\n") orelse std.mem.indexOf(u8, buf, "\n") orelse buf.len;
    const line = buf[0..first_line_end];
    var space1: ?usize = null;
    for (line, 0..) |c, idx| {
        if (c == ' ') {
            space1 = idx;
            break;
        }
    }
    const s1 = space1 orelse return null;
    const rest = line[s1 + 1 ..];
    var code: u16 = 0;
    var digits: usize = 0;
    for (rest) |c| {
        if (c >= '0' and c <= '9') {
            code = code * 10 + (c - '0');
            digits += 1;
            if (digits == 3) break;
        } else {
            break;
        }
    }
    if (digits == 3) return code;
    return null;
}

/// Parse Content-Length header value if present. Case-insensitive search.
pub fn parse_content_length(headers: []const u8) ?usize {
    const key = "content-length:";
    var i: usize = 0;
    while (i + key.len <= headers.len) : (i += 1) {
        var match = true;
        for (key, 0..) |kc, kidx| {
            const hc = headers[i + kidx];
            const lower_hc = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            if (lower_hc != kc) {
                match = false;
                break;
            }
        }
        if (match) {
            var val_idx = i + key.len;
            while (val_idx < headers.len and (headers[val_idx] == ' ' or headers[val_idx] == '\t')) : (val_idx += 1) {}
            var len_val: usize = 0;
            var has_digit = false;
            while (val_idx < headers.len) : (val_idx += 1) {
                const c = headers[val_idx];
                if (c >= '0' and c <= '9') {
                    len_val = len_val * 10 + (c - '0');
                    has_digit = true;
                } else if (c == '\r' or c == '\n') {
                    break;
                } else {
                    break;
                }
            }
            if (has_digit) return len_val;
        }
    }
    return null;
}

pub export fn _start() callconv(.c) noreturn {
    ui.write_console("download: starting\n");

    // Default configuration (or parse arguments when available)
    const target_ip = default_ip;
    const target_port = default_port;
    const target_path = default_path;
    const dest_name = default_dest;

    // 1. Connect over TCP
    const conn_rc = ui.tcp_connect(target_ip, target_port);
    if (conn_rc < 0) {
        ui.write_console("download: connect failed\n");
        ui.exit_process(1);
    }
    ui.write_console("download: connected\n");

    // 2. Transmit HTTP/1.0 GET request
    var req_buf: [256]u8 = undefined;
    const req_str = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.0\r\nHost: 10.0.0.2\r\nUser-Agent: VirelaiOS/1.0\r\nConnection: close\r\n\r\n", .{target_path}) catch "GET / HTTP/1.0\r\nHost: 10.0.0.2\r\nUser-Agent: VirelaiOS/1.0\r\n\r\n";

    const send_rc = ui.tcp_send(req_str);
    if (send_rc < 0) {
        ui.write_console("download: send failed\n");
        _ = ui.tcp_close();
        ui.exit_process(2);
    }
    ui.write_console("download: request sent\n");

    // 3. Open output file on the host share (MODE_WRITE | MODE_CREATE)
    const fd_res = ui.file_open(dest_name, ui.MODE_WRITE | ui.MODE_CREATE);
    if (fd_res < 0) {
        ui.write_console("download: file open failed\n");
        _ = ui.tcp_close();
        ui.exit_process(3);
    }
    const fd: u32 = @intCast(fd_res);
    ui.write_console("download: file opened\n");

    // 4. Stream response headers and body
    var header_buf: [header_scratch_max]u8 = undefined;
    var header_len: usize = 0;
    var headers_done = false;
    var total_body_bytes: usize = 0;
    var expected_length: ?usize = null;
    var rx_buf: [128]u8 = undefined;
    var empty_polls: usize = 0;

    while (empty_polls < 50) {
        const n = ui.tcp_recv(&rx_buf);
        if (n > 0) {
            const count = @as(usize, @intCast(n));
            const chunk = rx_buf[0..count];

            if (!headers_done) {
                const space = header_scratch_max - header_len;
                const take = @min(space, chunk.len);
                @memcpy(header_buf[header_len .. header_len + take], chunk[0..take]);
                header_len += take;

                if (find_header_end(header_buf[0..header_len])) |end| {
                    headers_done = true;
                    if (parse_status_code(header_buf[0..end])) |code| {
                        if (code == 200) {
                            ui.write_console("download: status 200\n");
                        } else {
                            ui.write_console("download: status other\n");
                        }
                    }
                    expected_length = parse_content_length(header_buf[0..end]);

                    ui.write_console("download: saving to file\n");

                    // Write body tail of initial segment
                    if (header_len > end) {
                        const body_tail = header_buf[end..header_len];
                        _ = ui.file_write(fd, body_tail);
                        total_body_bytes += body_tail.len;
                    }
                } else if (header_len >= header_scratch_max) {
                    headers_done = true;
                    ui.write_console("download: headers overflow\n");
                }
            } else {
                // Stream directly to file
                _ = ui.file_write(fd, chunk);
                total_body_bytes += chunk.len;
            }
            empty_polls = 0;
        } else if (n == 0) {
            empty_polls += 1;
            if (headers_done and total_body_bytes > 0 and empty_polls >= 5) {
                // Whole response received and socket is drained
                break;
            }
            ui.yield_task();
        } else {
            // Socket closed or error
            break;
        }
    }

    // 5. Close file and connection
    ui.file_close(fd);
    _ = ui.tcp_close();

    var summary_buf: [64]u8 = undefined;
    if (std.fmt.bufPrint(&summary_buf, "download: received {d} bytes\n", .{total_body_bytes})) |msg| {
        ui.write_console(msg);
    } else |_| {
        ui.write_console("download: received bytes\n");
    }
    ui.write_console("download: complete\n");

    ui.exit_process(0);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "download: parse_ipv4 valid and invalid" {
    try std.testing.expectEqual(@as(?u32, 0x0a000002), parse_ipv4("10.0.0.2"));
    try std.testing.expectEqual(@as(?u32, 0x7f000001), parse_ipv4("127.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 0xc0a80101), parse_ipv4("192.168.1.1"));
    try std.testing.expectEqual(@as(?u32, null), parse_ipv4(""));
    try std.testing.expectEqual(@as(?u32, null), parse_ipv4("256.0.0.1"));
    try std.testing.expectEqual(@as(?u32, null), parse_ipv4("10.0.0"));
}

test "download: filename_from_path" {
    try std.testing.expectEqualStrings("file.bin", filename_from_path("/file.bin"));
    try std.testing.expectEqualStrings("image.iso", filename_from_path("/path/to/image.iso"));
    try std.testing.expectEqualStrings("DOWNLOAD.OUT", filename_from_path("/"));
    try std.testing.expectEqualStrings("DOWNLOAD.OUT", filename_from_path(""));
}

test "download: parse_url" {
    const url1 = parse_url("http://10.0.0.2:8080/data/test.bin");
    try std.testing.expect(url1 != null);
    try std.testing.expectEqual(@as(u32, 0x0a000002), url1.?.ip);
    try std.testing.expectEqual(@as(u16, 8080), url1.?.port);
    try std.testing.expectEqualStrings("/data/test.bin", url1.?.path);
    try std.testing.expectEqualStrings("test.bin", url1.?.dest_filename);

    const url2 = parse_url("10.0.0.2/file.bin");
    try std.testing.expect(url2 != null);
    try std.testing.expectEqual(@as(u32, 0x0a000002), url2.?.ip);
    try std.testing.expectEqual(@as(u16, 80), url2.?.port);
    try std.testing.expectEqualStrings("/file.bin", url2.?.path);
}

test "download: find_header_end and parse_status_code" {
    const raw = "HTTP/1.0 200 OK\r\nContent-Length: 42\r\n\r\nHello Body";
    const end = find_header_end(raw);
    try std.testing.expect(end != null);
    try std.testing.expectEqual(@as(usize, 39), end.?);
    try std.testing.expectEqualStrings("Hello Body", raw[end.?..]);

    try std.testing.expectEqual(@as(?u16, 200), parse_status_code(raw));
    try std.testing.expectEqual(@as(?usize, 42), parse_content_length(raw));
}

test "download: parse_content_length case insensitive" {
    const raw = "HTTP/1.1 200 OK\r\ncontent-length: 1048576\r\nServer: Test\r\n\r\n";
    try std.testing.expectEqual(@as(?usize, 1048576), parse_content_length(raw));
}
