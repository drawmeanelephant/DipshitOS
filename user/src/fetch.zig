//! DipshitOS HTTP/1.0 Client — FETCH.BIN (Milestone 12, Card N3, Issue #150).
//!
//! Connects over TCP (slot 30), transmits HTTP/1.0 GET request (slot 31),
//! streams response headers and body to the console (slot 32 + slot 1),
//! cleanly tears down the connection (slot 33), and exits status 42 (slot 3).
//!
//! M26 N3 (issue #401): the terminal display now separates the response
//! into a "--- response headers ---" section (buffered through the bare
//! `\r\n\r\n` terminator) and a "--- response body ---" section streamed
//! as before, with serial markers `fetch: headers` and `fetch: body` for
//! the class-B gate. The splitter is a pure, host-tested function.

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("lib/ui.zig");
const netstatus = @import("lib/netstatus.zig");

pub const default_ip: u32 = 0x0a000002; // 10.0.0.2
pub const default_port: u16 = 80;
pub const exit_status: u32 = 42;
pub const header_scratch_max: usize = 1024;
/// M26 N13/N14: preflight exit statuses, distinct from the existing
/// connect/send failures (1/2) so the gate can tell a diagnosis from a
/// mid-session error.
pub const exit_offline: u32 = 3;
pub const exit_no_route: u32 = 4;

/// The fixed destination as bytes — the preflight classifier's input.
fn dest_ip_bytes() [4]u8 {
    return .{
        @truncate(default_ip >> 24),
        @truncate(default_ip >> 16),
        @truncate(default_ip >> 8),
        @truncate(default_ip),
    };
}

/// M26 N3: find the end of the HTTP header block (the first `\r\n\r\n`).
/// Returns the index ONE PAST the terminator, or null when not yet present.
/// Pure — host-tested.
pub fn header_end(buf: []const u8) ?usize {
    if (buf.len < 4) return null;
    var i: usize = 0;
    while (i + 3 < buf.len) : (i += 1) {
        if (buf[i] == '\r' and buf[i + 1] == '\n' and buf[i + 2] == '\r' and buf[i + 3] == '\n') {
            return i + 4;
        }
    }
    return null;
}

pub export fn _start() callconv(.c) noreturn {
    ui.write_console("fetch: starting\n");

    // M26 N13: network preflight — one sys_net_stats snapshot before the
    // connect. Offline/no-route exit FAST with the N14 message instead of
    // the bounded connect loop; on the host build (or a kernel without
    // slot 62) the verdict is .unknown and the legacy path is kept.
    if (builtin.os.tag == .freestanding) {
        const dest = dest_ip_bytes();
        const verdict = netstatus.check(dest);
        switch (verdict.diagnosis) {
            .offline_no_ip => {
                var buf: [128]u8 = undefined;
                ui.write_console(netstatus.format_message(&buf, "fetch", .offline_no_ip, dest));
                ui.exit_process(exit_offline);
            },
            .no_route => {
                var buf: [128]u8 = undefined;
                ui.write_console(netstatus.format_message(&buf, "fetch", .no_route, dest));
                ui.exit_process(exit_no_route);
            },
            .ready, .unknown => {},
        }
    }

    // 1. Connect to HTTP server (default 10.0.0.2:80)
    const conn_rc = ui.tcp_connect(default_ip, default_port);
    if (conn_rc < 0) {
        ui.write_console("fetch: connect failed\n");
        ui.exit_process(1);
    }
    ui.write_console("fetch: connected\n");

    // 2. Format & send HTTP/1.0 GET request
    const request = "GET / HTTP/1.0\r\nHost: 10.0.0.2\r\nUser-Agent: DipshitOS/1.0\r\n\r\n";
    const send_rc = ui.tcp_send(request);
    if (send_rc < 0) {
        ui.write_console("fetch: send failed\n");
        _ = ui.tcp_close();
        ui.exit_process(2);
    }
    ui.write_console("fetch: request sent\n");

    // 3. Receive & stream response. M26 N3: buffer the header block
    // through the bare `\r\n\r\n`, emit it as its own section, then
    // stream the body as it arrives.
    var header_buf: [header_scratch_max]u8 = undefined;
    var header_len: usize = 0;
    var headers_done = false;
    var rx_buf: [64]u8 = undefined;
    var total_bytes: usize = 0;
    var empty_polls: usize = 0;

    while (empty_polls < 50) {
        const n = ui.tcp_recv(&rx_buf);
        if (n > 0) {
            const count = @as(usize, @intCast(n));
            const chunk = rx_buf[0..count];

            if (!headers_done) {
                // Buffer up to the scratch cap, then the header section is
                // whatever we have (bounded honesty — never grow past it).
                const space = header_scratch_max - header_len;
                const take = @min(space, chunk.len);
                @memcpy(header_buf[header_len .. header_len + take], chunk[0..take]);
                header_len += take;

                if (header_end(header_buf[0..header_len])) |end| {
                    headers_done = true;
                    ui.write_console("fetch: headers\n");
                    ui.write_console("--- response headers ---\n");
                    ui.write_console(header_buf[0..end]);
                    ui.write_console("--- response body ---\n");
                    ui.write_console("fetch: body\n");
                    // Body bytes that already arrived inside this chunk
                    // (headers + body often share one TCP segment) belong
                    // to the body section, not the header buffer.
                    if (header_len > end) {
                        ui.write_console(header_buf[end..header_len]);
                        total_bytes += header_len - end;
                    }
                } else if (header_len >= header_scratch_max) {
                    // Oversized header: give up splitting, dump what we have.
                    headers_done = true;
                    ui.write_console("fetch: headers-overflow\n");
                    ui.write_console(header_buf[0..header_len]);
                    ui.write_console("\nfetch: body\n");
                }
            } else {
                ui.write_console(chunk);
                total_bytes += count;
            }
            empty_polls = 0;
        } else if (n == 0) {
            empty_polls += 1;
            if (total_bytes > 0 and empty_polls >= 5) {
                // Whole response received and socket is drained
                break;
            }
            ui.yield_task();
        } else {
            // Connection closed or error
            break;
        }
    }

    // 4. Close connection
    _ = ui.tcp_close();
    ui.write_console("\nfetch: done\n");

    // 5. Exit with milestone proof status 42
    ui.exit_process(exit_status);
}

test "fetch: header_end finds the bare CRLFCRLF terminator" {
    const hdr = "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expectEqual(@as(?usize, 38), header_end(hdr));
    const cut = header_end(hdr).?;
    try std.testing.expectEqualStrings("HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\n", hdr[0..cut]);
}

test "fetch: header_end null before the terminator" {
    try std.testing.expect(header_end("HTTP/1.0 200 OK\r\n") == null);
    try std.testing.expect(header_end("HTTP") == null);
    try std.testing.expect(header_end("") == null);
}

test "fetch: header_end handles bare LF and windowed searches" {
    // A terminator split across two 64-byte recv chunks still matches
    // because the search runs over the accumulated buffer.
    const early = "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r";
    try std.testing.expect(header_end(early) == null);
    const full = early ++ "\nbody";
    try std.testing.expectEqual(@as(?usize, 38), header_end(full));
}
