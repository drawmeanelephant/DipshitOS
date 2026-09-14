//! Host-side TLS 1.3 interop driver.
//!
//! A standalone program — not part of the guest build — that connects to a real
//! TLS server over a real socket, runs the in-tree client's handshake, sends a
//! request, reads the response, and prints one JSON ledger line. Every row of
//! the interop matrix is produced by this program actually talking to a peer.
//!
//! This Zig version has no `std.net`, so the driver links libc and uses raw
//! sockets with an IPv4 literal (the calling script resolves names and passes
//! the address). The library under test stays freestanding; only this harness
//! touches libc.
//!
//! Usage:
//!   zig build-exe user/src/lib/tls/interop_driver.zig \
//!     --dep crypto -Mcrypto=user/src/lib/crypto.zig -lc \
//!     --name driver
//!   ./driver <peer> <peer_version> <ipv4> <port> <servername> <root.der-or--> [request]

const std = @import("std");
const c = std.c;
const tls_client = @import("client.zig");
const trust_store = @import("trust_store.zig");
const pem = @import("pem.zig");

pub const std_options: std.Options = .{ .log_level = .warn };

fn parseIpv4(s: []const u8) ?u32 {
    var parts: [4]u8 = undefined;
    var n: usize = 0;
    var v: u32 = 0;
    var digits: usize = 0;
    for (s) |ch| {
        if (ch == '.') {
            if (digits == 0 or n == 3) return null;
            parts[n] = @intCast(v);
            n += 1;
            v = 0;
            digits = 0;
            continue;
        }
        if (ch < '0' or ch > '9') return null;
        v = v * 10 + (ch - '0');
        if (v > 255 or digits >= 3) return null;
        digits += 1;
    }
    if (digits == 0 or n != 3) return null;
    parts[3] = @intCast(v);
    return (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) | (@as(u32, parts[2]) << 8) | @as(u32, parts[3]);
}

const Sock = struct { fd: c.fd_t };

fn readFn(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
    const s: *Sock = @ptrCast(@alignCast(ctx.?));
    const n = c.read(s.fd, buf.ptr, buf.len);
    if (n < 0) return error.TransportError;
    return @intCast(n);
}

fn writeFn(ctx: ?*anyopaque, buf: []const u8) anyerror!usize {
    const s: *Sock = @ptrCast(@alignCast(ctx.?));
    const n = c.write(s.fd, buf.ptr, buf.len);
    if (n < 0) return error.TransportError;
    return @intCast(n);
}

fn entropy(out: []u8) void {
    // libc entropy for the host harness (the guest passes its own CSPRNG).
    c.arc4random_buf(out.ptr, out.len);
}

extern "c" fn clock_gettime(clock_id: c.clockid_t, tp: *c.timespec) c_int;

/// Monotonic milliseconds, via libc (this Zig version has no std.time.milliTimestamp).
fn monoMs() i64 {
    var ts: c.timespec = undefined;
    if (clock_gettime(c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

var bundle_buf: [768 * 1024]u8 = undefined;
/// Stable storage for each root's DER, so store entries do not point at a
/// reused scratch buffer.
var der_pool: [512][4096]u8 = undefined;
/// The host store: large enough for a full system bundle. A global because it
/// is far too big for the stack (the guest uses the 64-entry default).
var g_store: trust_store.SystemStore = .{};

/// Read stdin to the end (for a PEM root bundle, which does not fit in argv).
fn readStdin(buf: []u8) usize {
    var off: usize = 0;
    while (off < buf.len) {
        const n = c.read(0, buf.ptr + off, buf.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    return off;
}

/// Add every certificate block in a PEM bundle to the store.
fn loadBundle(store: *trust_store.SystemStore, text: []const u8) usize {
    var rest = text;
    var count: usize = 0;
    while (std.mem.indexOf(u8, rest, "-----BEGIN ")) |at| {
        rest = rest[at..];
        if (count >= der_pool.len) break;
        var scratch: [8192]u8 = undefined;
        const blk = pem.decodeFirst(rest, &scratch) catch break;
        if (blk.der.len > der_pool[count].len) {
            count += 1;
            continue;
        }
        @memcpy(der_pool[count][0..blk.der.len], blk.der);
        store.addRoot(der_pool[count][0..blk.der.len]) catch {};
        count += 1;
        const end_at = std.mem.indexOf(u8, rest, "-----END ") orelse break;
        rest = rest[end_at + 5 ..];
        if (std.mem.indexOf(u8, rest, "-----")) |dash| rest = rest[dash + 5 ..] else break;
    }
    return count;
}

fn emit(line: []const u8) void {
    _ = c.write(1, line.ptr, line.len);
}

/// A tiny manual line builder — this Zig version has no std.io.fixedBufferStream.
const B = struct {
    buf: []u8,
    n: usize = 0,

    fn put(self: *B, s: []const u8) void {
        if (self.n >= self.buf.len) return;
        const k = @min(s.len, self.buf.len - self.n);
        @memcpy(self.buf[self.n..][0..k], s[0..k]);
        self.n += k;
    }

    fn esc(self: *B, s: []const u8) void {
        for (s) |ch| {
            switch (ch) {
                '"' => self.put("\\\""),
                '\\' => self.put("\\\\"),
                '\n' => self.put("\\n"),
                '\r' => self.put("\\r"),
                else => {
                    if (ch < 0x20) {
                        var tmp: [8]u8 = undefined;
                        const hex = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{ch}) catch return;
                        self.put(hex);
                    } else {
                        const one = [_]u8{ch};
                        self.put(&one);
                    }
                },
            }
        }
    }

    fn int(self: *B, v: i64) void {
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
        self.put(s);
    }
};

fn isoFrom(secs: i64, buf: []u8) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch "1970-01-01T00:00:00Z";
}

fn ledger(
    peer: []const u8,
    peer_version: []const u8,
    endpoint: []const u8,
    servername: []const u8,
    now_iso: []const u8,
    outcome: []const u8,
    detail: []const u8,
    handshake_ms: i64,
    response_bytes: usize,
    command: []const u8,
) void {
    var storage: [8192]u8 = undefined;
    var b = B{ .buf = &storage };
    b.put("{\"peer\":\"");
    b.esc(peer);
    b.put("\",\"peer_version\":\"");
    b.esc(peer_version);
    b.put("\",\"endpoint\":\"");
    b.esc(endpoint);
    b.put("\",\"servername\":\"");
    b.esc(servername);
    b.put("\",\"tls_version\":\"TLS1.3\",\"cipher_suite\":\"TLS_AES_128_GCM_SHA256\",\"timestamp\":\"");
    b.esc(now_iso);
    b.put("\",\"outcome\":\"");
    b.esc(outcome);
    b.put("\",\"detail\":\"");
    b.esc(detail);
    b.put("\",\"handshake_ms\":");
    b.int(handshake_ms);
    b.put(",\"response_bytes\":");
    b.int(@intCast(response_bytes));
    b.put(",\"command\":\"");
    b.esc(command);
    b.put("\"}\n");
    emit(b.buf[0..b.n]);
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    var argv: [16][]const u8 = undefined;
    var argc: usize = 0;
    var it = std.process.Args.Iterator.init(init.args);
    while (it.next()) |a| {
        if (argc < argv.len) {
            argv[argc] = a;
            argc += 1;
        }
    }
    if (argc < 8) {
        std.debug.print("usage: driver <peer> <peer_version> <epoch_secs> <ipv4> <port> <servername> <root_hex|-> [request]\n", .{});
        return 1;
    }
    const peer = argv[1];
    const peer_version = argv[2];
    const now_secs = std.fmt.parseInt(i64, argv[3], 10) catch 0;
    var now_buf: [40]u8 = undefined;
    const now_iso = isoFrom(now_secs, &now_buf);
    const ip_s = argv[4];
    const port = std.fmt.parseInt(u16, argv[5], 10) catch return 1;
    const servername = argv[6];
    const root_hex = argv[7];
    const request = if (argc > 8) argv[8] else "GET / HTTP/1.0\r\nHost: ";

    var ep_buf: [128]u8 = undefined;
    const endpoint = std.fmt.bufPrint(&ep_buf, "{s}:{d}", .{ ip_s, port }) catch "?";
    var cmd_buf: [512]u8 = undefined;
    const command = std.fmt.bufPrint(&cmd_buf, "./driver {s} '{s}' {s} {s} {d} {s} <root.der hex>", .{ peer, peer_version, now_iso, ip_s, port, servername }) catch "";

    const ip = parseIpv4(ip_s) orelse {
        ledger(peer, peer_version, endpoint, servername, now_iso, "setup_error", "host is not an IPv4 literal", -1, 0, command);
        return 2;
    };

    // Trust store: the caller passes the root DER as hex ("-" for none).
    var store = &g_store;
    store.setVersion("interop-fixtures");
    if (std.mem.eql(u8, root_hex, "@stdin")) {
        const n = readStdin(&bundle_buf);
        const roots = loadBundle(store, bundle_buf[0..n]);
        if (roots == 0) {
            ledger(peer, peer_version, endpoint, servername, now_iso, "setup_error", "no roots on stdin", -1, 0, command);
            return 2;
        }
    } else if (!std.mem.eql(u8, root_hex, "-")) {
        var der: [8192]u8 = undefined;
        const dlen = root_hex.len / 2;
        _ = std.fmt.hexToBytes(der[0..dlen], root_hex) catch {
            ledger(peer, peer_version, endpoint, servername, now_iso, "setup_error", "bad hex root", -1, 0, command);
            return 2;
        };
        store.addRoot(der[0..dlen]) catch {
            ledger(peer, peer_version, endpoint, servername, now_iso, "setup_error", "root refused", -1, 0, command);
            return 2;
        };
    }

    // Connect.
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) {
        ledger(peer, peer_version, endpoint, servername, now_iso, "connect_error", "socket() failed", -1, 0, command);
        return 2;
    }
    var sa = c.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, ip) };
    if (c.connect(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)) != 0) {
        ledger(peer, peer_version, endpoint, servername, now_iso, "connect_error", "connect() failed", -1, 0, command);
        return 2;
    }
    var sock = Sock{ .fd = fd };
    defer _ = c.close(fd);

    var client = tls_client.Client(trust_store.SystemStore).init(
        .{ .ctx = &sock, .readFn = readFn, .writeFn = writeFn },
        .{
            .host = servername,
            .store = store,
            .now = now_secs,
            .entropy = entropy,
        },
    );

    const t0 = monoMs();
    client.handshake() catch |e| {
        const t1 = monoMs();
        var d: [128]u8 = undefined;
        const detail = std.fmt.bufPrint(&d, "handshake failed: {s} (validation={s}, roots={d}, inter={d}, leaf_issuer_cn={s})", .{
            @errorName(e), @tagName(client.last_validation), store.rootCount(), client.peer_intermediate_len,
            if (client.last_cert_error) |ce| @errorName(ce) else (client.server_cert.issuer_cn orelse "?"),
        }) catch "handshake failed";
        ledger(peer, peer_version, endpoint, servername, now_iso, "handshake_failed", detail, t1 - t0, 0, command);
        return 2;
    };
    const t_hs = monoMs();

    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "{s}{s}\r\n\r\n", .{ request, servername }) catch return 1;
    client.write(req) catch {
        ledger(peer, peer_version, endpoint, servername, now_iso, "write_failed", "application write failed", t_hs - t0, 0, command);
        return 2;
    };

    var resp: [8192]u8 = undefined;
    const n = client.read(&resp) catch {
        ledger(peer, peer_version, endpoint, servername, now_iso, "read_failed", "application read failed", t_hs - t0, 0, command);
        return 2;
    };

    var d2: [300]u8 = undefined;
    const detail = std.fmt.bufPrint(&d2, "first bytes: {s}", .{resp[0..@min(n, 48)]}) catch "ok";
    ledger(peer, peer_version, endpoint, servername, now_iso, "ok", detail, t_hs - t0, n, command);
    return 0;
}
