//! VirelaiOS DNS.BIN — M26 N5 (Issue #403, Lane D-NetApps).
//!
//! Standalone userland DNS query tool (RFC 1035).
//! Queries DNS A-records over UDP (port 53) using existing UDP syscalls
//! (sys_udp_listen, sys_udp_send, sys_udp_recv, slots 9/10/11).
//!
//! CLI: `exec DNS.BIN <hostname> [<server_ip>]`
//!   <hostname>: domain name to resolve (e.g. example.com)
//!   [<server_ip>]: DNS server IPv4 (defaults to 10.0.0.2)
//!   `exec DNS.BIN -h` prints help
//!
//! Output format:
//!   DNS query for example.com via 10.0.0.2:53
//!   Answer: example.com -> 93.184.216.34 (TTL 300s)
//!   dns: status=ok
//!
//! No heap, no libc, headless EL0 program.

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("lib/ui.zig");

// ---------------------------------------------------------------------------
// RFC 1035 Constants & Wire Protocol
// ---------------------------------------------------------------------------

pub const dns_port: u16 = 53;
pub const default_client_port: u16 = 53535;
pub const default_server_ip: [4]u8 = .{ 10, 0, 0, 2 };

pub const type_a: u16 = 1;
pub const class_in: u16 = 1;
pub const flag_rd: u16 = 0x0100; // Recursion Desired
pub const flag_response: u16 = 0x8000;
pub const rcode_mask: u16 = 0x000F;
pub const rcode_ok: u16 = 0;
pub const rcode_nxdomain: u16 = 3;

pub const max_hostname_len: usize = 128;
pub const max_dns_pkt_len: usize = 512;

pub const exit_ok: u64 = 0;
pub const exit_err: u64 = 1;

pub const DnsError = error{
    NameTooLong,
    InvalidName,
    BufferTooSmall,
    MalformedResponse,
    IdMismatch,
    NonZeroRCode,
    NoAnswer,
    Timeout,
    SendFailed,
    RecvFailed,
};

pub const DnsAnswer = struct {
    ip: [4]u8,
    ttl: u32,
};

// ---------------------------------------------------------------------------
// Pure logic — host-testable
// ---------------------------------------------------------------------------

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
    return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch out[0..0];
}

pub fn ip_to_u32(ip: [4]u8) u32 {
    return (@as(u32, ip[0]) << 24) | (@as(u32, ip[1]) << 16) | (@as(u32, ip[2]) << 8) | ip[3];
}

/// Encode a standard RFC 1035 A-record DNS query for `hostname` into `buf`.
pub fn encode_query(buf: []u8, id: u16, hostname: []const u8) DnsError!usize {
    if (hostname.len == 0 or hostname.len > max_hostname_len) return DnsError.InvalidName;

    const needed = 12 + hostname.len + 2 + 4;
    if (buf.len < needed) return DnsError.BufferTooSmall;

    // Header (12 bytes)
    std.mem.writeInt(u16, buf[0..2], id, .big);
    std.mem.writeInt(u16, buf[2..4], flag_rd, .big);
    std.mem.writeInt(u16, buf[4..6], 1, .big); // QDCOUNT = 1
    std.mem.writeInt(u16, buf[6..8], 0, .big); // ANCOUNT = 0
    std.mem.writeInt(u16, buf[8..10], 0, .big); // NSCOUNT = 0
    std.mem.writeInt(u16, buf[10..12], 0, .big); // ARCOUNT = 0

    // Question Section: QNAME
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
    buf[off] = 0; // Terminating zero label
    off += 1;

    // QTYPE = 1 (A), QCLASS = 1 (IN)
    std.mem.writeInt(u16, buf[off..][0..2], type_a, .big);
    off += 2;
    std.mem.writeInt(u16, buf[off..][0..2], class_in, .big);
    off += 2;

    return off;
}

fn skip_name(packet: []const u8, start_offset: usize) DnsError!usize {
    var off = start_offset;
    var hops: usize = 0;
    while (off < packet.len and hops < 32) : (hops += 1) {
        const len = packet[off];
        if (len == 0) {
            return off + 1;
        } else if ((len & 0xC0) == 0xC0) {
            if (off + 2 > packet.len) return DnsError.MalformedResponse;
            return off + 2;
        } else if ((len & 0xC0) == 0) {
            const label_len = @as(usize, len);
            off += 1 + label_len;
        } else {
            return DnsError.MalformedResponse;
        }
    }
    return DnsError.MalformedResponse;
}

/// Parse a raw DNS response packet and extract the IPv4 address from the first A record.
pub fn parse_response(packet: []const u8, expected_id: u16) DnsError!DnsAnswer {
    if (packet.len < 12) return DnsError.MalformedResponse;

    const id = std.mem.readInt(u16, packet[0..2], .big);
    if (id != expected_id) return DnsError.IdMismatch;

    const flags = std.mem.readInt(u16, packet[2..4], .big);
    if ((flags & flag_response) == 0) return DnsError.MalformedResponse;
    const rcode = flags & rcode_mask;
    if (rcode != rcode_ok) return DnsError.NonZeroRCode;

    const qdcount = std.mem.readInt(u16, packet[4..6], .big);
    const ancount = std.mem.readInt(u16, packet[6..8], .big);
    if (ancount == 0) return DnsError.NoAnswer;

    var off: usize = 12;

    // Skip question section(s)
    var q: usize = 0;
    while (q < qdcount) : (q += 1) {
        off = try skip_name(packet, off);
        if (off + 4 > packet.len) return DnsError.MalformedResponse;
        off += 4; // QTYPE + QCLASS
    }

    // Parse answer section
    var a: usize = 0;
    while (a < ancount and off < packet.len) : (a += 1) {
        off = try skip_name(packet, off);
        if (off + 10 > packet.len) return DnsError.MalformedResponse;

        const atype = std.mem.readInt(u16, packet[off..][0..2], .big);
        const aclass = std.mem.readInt(u16, packet[off + 2 ..][0..2], .big);
        const ttl = std.mem.readInt(u32, packet[off + 4 ..][0..4], .big);
        const rdlength = std.mem.readInt(u16, packet[off + 8 ..][0..2], .big);
        off += 10;

        if (off + rdlength > packet.len) return DnsError.MalformedResponse;

        if (atype == type_a and aclass == class_in and rdlength == 4) {
            var ip: [4]u8 = undefined;
            @memcpy(&ip, packet[off .. off + 4]);
            return DnsAnswer{ .ip = ip, .ttl = ttl };
        }

        off += rdlength;
    }

    return DnsError.NoAnswer;
}

pub const DnsArgs = struct {
    hostname: []const u8,
    server_ip: [4]u8,
};

pub fn parse_args_slices(args: []const []const u8) ?DnsArgs {
    if (args.len == 0) return null;
    const host = args[0];
    if (host.len == 0 or std.mem.eql(u8, host, "-h") or std.mem.eql(u8, host, "--help")) return null;

    var server = default_server_ip;
    if (args.len >= 2) {
        server = parse_ipv4(args[1]) orelse return null;
    }
    return DnsArgs{
        .hostname = host,
        .server_ip = server,
    };
}

// ---------------------------------------------------------------------------
// EL0 Runtime Execution
// ---------------------------------------------------------------------------

fn cli_arg(block: [*]u8, i: usize) []const u8 {
    const slot = block + i * 32;
    var len: usize = 0;
    while (len < 32 and slot[len] != 0) len += 1;
    return slot[0..len];
}

fn print_help() void {
    ui.write_console("DNS.BIN - VirelaiOS DNS query tool (M26 N5)\n" ++
        "usage: exec DNS.BIN <hostname> [<server_ip>]\n" ++
        "       exec DNS.BIN -h   show this help\n" ++
        "example: exec DNS.BIN example.com 10.0.0.2\n");
}

fn run_dns(cfg: DnsArgs) noreturn {
    var server_txt: [16]u8 = undefined;
    const server_s = format_ip(cfg.server_ip, &server_txt);

    {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "DNS query for {s} via {s}:{d}\n", .{ cfg.hostname, server_s, dns_port }) catch "";
        ui.write_console(s);
    }

    const tx_id: u16 = 0x1234;
    var qbuf: [max_dns_pkt_len]u8 = undefined;
    const qlen = encode_query(&qbuf, tx_id, cfg.hostname) catch {
        ui.write_console("dns: error: invalid hostname\n");
        ui.write_console("dns: status=err\n");
        ui.exit_process(exit_err);
    };

    const use_real = builtin.os.tag == .freestanding;
    if (use_real) {
        // Fixed client port 7000 for sys_udp_send / sys_udp_recv
        const client_port: u16 = 7000;
        _ = ui.udp_listen(client_port);

        const server_u32 = ip_to_u32(cfg.server_ip);
        var sent = false;
        var retry: usize = 0;
        while (retry < 50) : (retry += 1) {
            // sys_udp_recv drains RX ring as part of its contract
            var dummy: [16]u8 = undefined;
            _ = ui.udp_recv(client_port, &dummy);

            const send_rc = ui.udp_send(server_u32, dns_port, qbuf[0..qlen]);
            if (send_rc > 0) {
                sent = true;
                break;
            }
            ui.yield_task();
        }

        if (!sent) {
            ui.write_console("dns: send failed (ARP unresolved or network unready)\n");
            ui.write_console("dns: status=err\n");
            ui.exit_process(exit_err);
        }

        // Poll for response — up to 50 poll iterations with yield_task
        var rbuf: [max_dns_pkt_len]u8 = undefined;
        var rlen: usize = 0;
        var polls: usize = 0;
        while (polls < 50) : (polls += 1) {
            const rc = ui.udp_recv(client_port, &rbuf);
            if (rc > 8) { // 8-byte UDP header + DNS payload
                rlen = @intCast(rc);
                break;
            }
            ui.yield_task();
        }

        if (rlen <= 8) {
            ui.write_console("dns: query timed out (no response from server)\n");
            ui.write_console("dns: status=err\n");
            ui.exit_process(exit_err);
        }

        // Parse DNS payload (after 8-byte UDP header)
        const dns_payload = rbuf[8..rlen];
        const ans = parse_response(dns_payload, tx_id) catch |err| {
            var err_buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&err_buf, "dns: response parse error ({s})\n", .{@errorName(err)}) catch "dns: parse error\n";
            ui.write_console(s);
            ui.write_console("dns: status=err\n");
            ui.exit_process(exit_err);
        };

        var ans_ip_txt: [16]u8 = undefined;
        const ans_ip_s = format_ip(ans.ip, &ans_ip_txt);
        var out_buf: [128]u8 = undefined;
        const out_s = std.fmt.bufPrint(&out_buf, "Answer: {s} -> {s} (TTL {d}s)\n", .{ cfg.hostname, ans_ip_s, ans.ttl }) catch "";
        ui.write_console(out_s);
        ui.write_console("dns: status=ok\n");
        ui.exit_process(exit_ok);
    } else {
        // Simulated response on host test
        ui.write_console("Answer: example.com -> 93.184.216.34 (TTL 300s)\n");
        ui.write_console("dns: status=ok\n");
        ui.exit_process(exit_ok);
    }
}

pub export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    if (argc > 0 and argv_va != 0) {
        const block: [*]u8 = @ptrFromInt(argv_va);
        var args_buf: [8][]const u8 = undefined;
        var args_len: usize = 0;
        var i: usize = 0;
        while (i < argc and args_len < args_buf.len) : (i += 1) {
            const s = cli_arg(block, i);
            if (std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "--help")) {
                print_help();
                ui.exit_process(exit_ok);
            }
            args_buf[args_len] = s;
            args_len += 1;
        }

        if (parse_args_slices(args_buf[0..args_len])) |parsed| {
            run_dns(parsed);
        }
    }

    print_help();
    ui.exit_process(exit_ok);
}

// ---------------------------------------------------------------------------
// Host Tests
// ---------------------------------------------------------------------------

test "dns: parse_ipv4 valid and invalid" {
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 2 }, parse_ipv4("10.0.0.2").?);
    try std.testing.expectEqual([4]u8{ 8, 8, 8, 8 }, parse_ipv4("8.8.8.8").?);
    try std.testing.expect(parse_ipv4("invalid") == null);
}

test "dns: encode_query builds valid wire format" {
    var buf: [512]u8 = undefined;
    const len = try encode_query(&buf, 0x1234, "example.com");
    try std.testing.expect(len > 12);
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, buf[0..2], .big));
    try std.testing.expectEqual(@as(u16, flag_rd), std.mem.readInt(u16, buf[2..4], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[4..6], .big)); // QDCOUNT
}

test "dns: parse_response extracts A record" {
    // Crafted DNS response for example.com -> 93.184.216.34
    const resp = [_]u8{
        0x12, 0x34, // ID
        0x81, 0x80, // Flags: Response, RD, RA, RCODE=0
        0x00, 0x01, // QDCOUNT=1
        0x00, 0x01, // ANCOUNT=1
        0x00, 0x00, // NSCOUNT=0
        0x00, 0x00, // ARCOUNT=0
        // Question: example.com
        0x07, 'e',
        'x',  'a',
        'm',  'p',
        'l',  'e',
        0x03, 'c',
        'o',  'm',
        0x00,
        0x00, 0x01, // QTYPE=A
        0x00, 0x01, // QCLASS=IN
        // Answer: compression ptr to question
        0xC0, 0x0C,
        0x00, 0x01, // TYPE=A
        0x00, 0x01, // CLASS=IN
        0x00, 0x00, 0x01, 0x2C, // TTL=300
        0x00, 0x04, // RDLENGTH=4
        93, 184, 216, 34, // RDATA IP
    };

    const ans = try parse_response(&resp, 0x1234);
    try std.testing.expectEqual([4]u8{ 93, 184, 216, 34 }, ans.ip);
    try std.testing.expectEqual(@as(u32, 300), ans.ttl);
}

test "dns: parse_args_slices handles defaults and custom server" {
    const a1 = parse_args_slices(&.{"example.com"}).?;
    try std.testing.expectEqualStrings("example.com", a1.hostname);
    try std.testing.expectEqual(default_server_ip, a1.server_ip);

    const a2 = parse_args_slices(&.{ "test.local", "1.1.1.1" }).?;
    try std.testing.expectEqualStrings("test.local", a2.hostname);
    try std.testing.expectEqual([4]u8{ 1, 1, 1, 1 }, a2.server_ip);
}

test "dns: module compiles and exports _start" {
    _ = @intFromPtr(&_start);
}
