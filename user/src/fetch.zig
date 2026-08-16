//! DipshitOS HTTP/1.0 Client — FETCH.BIN (Milestone 12, Card N3, Issue #150).
//!
//! Connects over TCP (slot 30), transmits HTTP/1.0 GET request (slot 31),
//! streams response headers and body to the console (slot 32 + slot 1),
//! cleanly tears down the connection (slot 33), and exits status 42 (slot 3).

const std = @import("std");
const ui = @import("lib/ui.zig");

pub const default_ip: u32 = 0x0a000002; // 10.0.0.2
pub const default_port: u16 = 80;
pub const exit_status: u32 = 42;

pub export fn _start() callconv(.c) noreturn {
    ui.write_console("fetch: starting\n");

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

    // 3. Receive & stream response
    var rx_buf: [64]u8 = undefined;
    var total_bytes: usize = 0;
    var empty_polls: usize = 0;

    while (empty_polls < 50) {
        const n = ui.tcp_recv(&rx_buf);
        if (n > 0) {
            const count = @as(usize, @intCast(n));
            ui.write_console(rx_buf[0..count]);
            total_bytes += count;
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
