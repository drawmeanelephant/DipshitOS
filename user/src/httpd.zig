//! DipshitOS In-Guest HTTP/1.1 Web Server — HTTPD.BIN
//!
//! Listens for incoming TCP connections (passive open), parses HTTP/1.1 requests,
//! serves an interactive HTML dashboard on `/`, dynamic JSON system telemetry
//! on `/api/status`, and static files from the FAT32 volume.

const std = @import("std");
const ui = @import("lib/ui.zig");

pub const default_port: u16 = 8080;
pub const max_req_len: usize = 1024;
pub const send_chunk_max: usize = 64;

pub const Method = enum {
    get,
    head,
    unsupported,
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    version: []const u8,
};

/// Parse an incoming raw HTTP request buffer.
pub fn parse_request(buf: []const u8) ?Request {
    if (buf.len < 4) return null;

    // Find end of request line (CRLF or LF)
    var line_end: usize = 0;
    while (line_end < buf.len and buf[line_end] != '\r' and buf[line_end] != '\n') : (line_end += 1) {}
    if (line_end == 0) return null;

    const line = buf[0..line_end];
    var iter = std.mem.splitScalar(u8, line, ' ');
    const method_str = iter.next() orelse return null;
    const path_str = iter.next() orelse return null;
    const ver_str = iter.next() orelse "HTTP/1.1";

    const method: Method = if (std.mem.eql(u8, method_str, "GET"))
        .get
    else if (std.mem.eql(u8, method_str, "HEAD"))
        .head
    else
        .unsupported;

    return Request{
        .method = method,
        .path = path_str,
        .version = ver_str,
    };
}

/// Sanitize URL path to prevent directory traversal attacks ("..").
pub fn sanitize_path(path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (std.mem.indexOf(u8, path, "..") != null) return null;

    var clean = path;
    while (clean.len > 0 and clean[0] == '/') {
        clean = clean[1..];
    }
    return clean;
}

/// Determine MIME Content-Type header based on file extension.
pub fn mime_for_path(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm")) {
        return "text/html; charset=utf-8";
    } else if (std.mem.endsWith(u8, path, ".txt") or std.mem.endsWith(u8, path, ".TXT")) {
        return "text/plain; charset=utf-8";
    } else if (std.mem.endsWith(u8, path, ".json")) {
        return "application/json";
    } else if (std.mem.endsWith(u8, path, ".bmp")) {
        return "image/bmp";
    } else if (std.mem.endsWith(u8, path, ".bin") or std.mem.endsWith(u8, path, ".BIN") or std.mem.endsWith(u8, path, ".elf") or std.mem.endsWith(u8, path, ".ELF")) {
        return "application/octet-stream";
    }
    return "text/plain";
}

pub fn read_cntpct() u64 {
    if (@import("builtin").cpu.arch != .aarch64) return 240000000;
    var val: u64 = 0;
    asm volatile ("mrs %[val], cntpct_el0"
        : [val] "=r" (val),
    );
    return val;
}

pub fn read_cntfrq() u64 {
    if (@import("builtin").cpu.arch != .aarch64) return 24000000;
    var val: u64 = 0;
    asm volatile ("mrs %[val], cntfrq_el0"
        : [val] "=r" (val),
    );
    return val;
}

pub const html_dashboard: []const u8 =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <title>DipshitOS Control Center</title>
    \\  <style>
    \\    :root { --bg: #0f172a; --card: #1e293b; --border: #334155; --text: #f8fafc; --muted: #94a3b8; --accent: #38bdf8; --green: #22c55e; --blue: #3b82f6; }
    \\    * { box-sizing: border-box; margin: 0; padding: 0; }
    \\    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace; background: var(--bg); color: var(--text); padding: 32px 24px; line-height: 1.5; }
    \\    .container { max-width: 960px; margin: 0 auto; }
    \\    header { display: flex; justify-content: space-between; align-items: center; border-bottom: 2px solid var(--border); padding-bottom: 16px; margin-bottom: 24px; }
    \\    h1 { font-size: 26px; color: var(--accent); letter-spacing: -0.5px; display: flex; align-items: center; gap: 10px; }
    \\    .pulse { width: 10px; height: 10px; border-radius: 50%; background: var(--green); box-shadow: 0 0 10px var(--green); display: inline-block; animation: pulse-anim 2s infinite; }
    \\    @keyframes pulse-anim { 0%, 100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.4; transform: scale(0.85); } }
    \\    .badge { background: #064e3b; color: #6ee7b7; border: 1px solid #059669; padding: 4px 10px; border-radius: 9999px; font-size: 12px; font-weight: bold; }
    \\    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; margin-bottom: 24px; }
    \\    .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.3); }
    \\    .card-title { font-size: 13px; text-transform: uppercase; color: var(--muted); letter-spacing: 0.5px; margin-bottom: 8px; }
    \\    .card-val { font-size: 24px; font-weight: bold; color: var(--text); font-variant-numeric: tabular-nums; }
    \\    .card-sub { font-size: 12px; color: var(--muted); margin-top: 4px; }
    \\    h2 { font-size: 18px; color: var(--text); margin: 24px 0 12px 0; display: flex; align-items: center; justify-content: space-between; }
    \\    table { width: 100%; border-collapse: collapse; background: var(--card); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; font-size: 14px; }
    \\    th, td { padding: 12px 16px; text-align: left; border-bottom: 1px solid var(--border); }
    \\    th { background: #0b1120; color: var(--muted); font-size: 12px; text-transform: uppercase; }
    \\    tr:hover { background: rgba(255,255,255,0.02); }
    \\    .btn { display: inline-flex; align-items: center; background: var(--blue); color: #fff; padding: 8px 14px; border-radius: 6px; text-decoration: none; font-size: 13px; font-weight: 500; transition: background 0.15s; }
    \\    .btn:hover { background: #2563eb; }
    \\    .btn-outline { background: transparent; border: 1px solid var(--border); color: var(--muted); }
    \\    .btn-outline:hover { background: var(--border); color: var(--text); }
    \\    .nav-bar { display: flex; gap: 10px; margin-top: 20px; }
    \\    footer { margin-top: 40px; border-top: 1px solid var(--border); padding-top: 16px; font-size: 12px; color: var(--muted); text-align: center; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <div class="container">
    \\    <header>
    \\      <h1><span class="pulse"></span> DipshitOS Control Center</h1>
    \\      <span class="badge">ONLINE &bull; PORT 8080</span>
    \\    </header>
    \\    <div class="grid">
    \\      <div class="card">
    \\        <div class="card-title">System Uptime</div>
    \\        <div class="card-val" id="uptime">-</div>
    \\        <div class="card-sub" id="ticks">Hardware timer</div>
    \\      </div>
    \\      <div class="card">
    \\        <div class="card-title">Active Processes</div>
    \\        <div class="card-val" id="procs_count">-</div>
    \\        <div class="card-sub">EL0 Tasks Scheduled</div>
    \\      </div>
    \\      <div class="card">
    \\        <div class="card-title">Architecture</div>
    \\        <div class="card-val">AArch64</div>
    \\        <div class="card-sub">Apple Silicon VZ</div>
    \\      </div>
    \\      <div class="card">
    \\        <div class="card-title">Kernel Mode</div>
    \\        <div class="card-val">Zero-Heap</div>
    \\        <div class="card-sub">Identity MMU + GICv3</div>
    \\      </div>
    \\    </div>
    \\    <h2>Active System Processes <span style="font-size:12px;color:var(--muted)" id="poll-indicator">Polling live...</span></h2>
    \\    <table>
    \\      <thead>
    \\        <tr><th>PID</th><th>Program Name</th><th>State</th><th>Exit Status</th></tr>
    \\      </thead>
    \\      <tbody id="procs-table">
    \\        <tr><td colspan="4" style="color:var(--muted)">Querying process table...</td></tr>
    \\      </tbody>
    \\    </table>
    \\    <h2>System Resources &amp; Management</h2>
    \\    <div class="nav-bar">
    \\      <a href="/files" class="btn">Explore Filesystem &rarr;</a>
    \\      <a href="/api/status" class="btn btn-outline" target="_blank">JSON Status API</a>
    \\      <a href="/api/procs" class="btn btn-outline" target="_blank">JSON Procs API</a>
    \\      <a href="/APPS.TXT" class="btn btn-outline" target="_blank">View APPS.TXT</a>
    \\    </div>
    \\    <footer>
    \\      DipshitOS v0.27.0 &bull; Freestanding Bare-Metal Operating System &bull; Built with Zig &amp; Swift
    \\    </footer>
    \\  </div>
    \\  <script>
    \\    async function updateTelemetry() {
    \\      try {
    \\        const [sRes, pRes] = await Promise.all([fetch('/api/status'), fetch('/api/procs')]);
    \\        if (sRes.ok) {
    \\          const s = await sRes.json();
    \\          const sec = s.uptime_seconds || 0;
    \\          const hrs = Math.floor(sec / 3600);
    \\          const mins = Math.floor((sec % 3600) / 60);
    \\          const secs = sec % 60;
    \\          document.getElementById('uptime').textContent = `${hrs}h ${mins}m ${secs}s`;
    \\          document.getElementById('ticks').textContent = `${(s.uptime_ticks || 0).toLocaleString()} ticks`;
    \\          document.getElementById('procs_count').textContent = s.procs_count || 0;
    \\        }
    \\        if (pRes.ok) {
    \\          const p = await pRes.json();
    \\          if (p.procs && p.procs.length > 0) {
    \\            let html = '';
    \\            for (const pr of p.procs) {
    \\              html += `<tr><td>${pr.pid}</td><td><strong>${pr.name}</strong></td><td><span style="color:${pr.state==='running'?'#22c55e':'#94a3b8'}">${pr.state}</span></td><td>${pr.exit_status}</td></tr>`;
    \\            }
    \\            document.getElementById('procs-table').innerHTML = html;
    \\          }
    \\        }
    \\        document.getElementById('poll-indicator').textContent = 'Live update ' + new Date().toLocaleTimeString();
    \\      } catch (err) {
    \\        document.getElementById('poll-indicator').textContent = 'Syncing...';
    \\      }
    \\    }
    \\    setInterval(updateTelemetry, 2000);
    \\    updateTelemetry();
    \\  </script>
    \\</body>
    \\</html>
;

/// Format dynamic JSON system status with live uptime and process count.
pub fn format_api_status(buf: []u8) []const u8 {
    const ticks = read_cntpct();
    const freq = read_cntfrq();
    const uptime_sec = if (freq > 0) ticks / freq else 0;

    var proc_raw: [16 * 40]u8 = undefined;
    const n_procs = ui.get_procs(&proc_raw);
    const proc_count: usize = if (n_procs > 0) @intCast(n_procs) else 0;

    return std.fmt.bufPrint(buf,
        \\{{
        \\  "os": "DipshitOS",
        \\  "arch": "aarch64",
        \\  "version": "0.27.0",
        \\  "status": "online",
        \\  "uptime_seconds": {d},
        \\  "uptime_ticks": {d},
        \\  "timer_freq_hz": {d},
        \\  "procs_count": {d},
        \\  "kernel": "freestanding-zero-heap",
        \\  "compositor": "driving-award",
        \\  "network": "virtio-net-rfc793"
        \\}}
        \\
    , .{
        uptime_sec,
        ticks,
        freq,
        proc_count,
    }) catch "{\n  \"os\": \"DipshitOS\",\n  \"status\": \"online\"\n}\n";
}

/// Format dynamic JSON process table endpoint.
pub fn format_api_procs(buf: []u8) []const u8 {
    var proc_raw: [16 * 40]u8 = undefined;
    const n_procs = ui.get_procs(&proc_raw);
    if (n_procs <= 0) {
        const fallback = "{\"count\":0,\"procs\":[]}\n";
        @memcpy(buf[0..fallback.len], fallback);
        return buf[0..fallback.len];
    }

    var proc_list: [16]ui.ProcInfo = undefined;
    const count = ui.parse_procs(&proc_raw, @intCast(n_procs), &proc_list);

    var off: usize = 0;
    const head = std.fmt.bufPrint(buf[off..], "{{\"count\":{d},\"procs\":[", .{count}) catch return "{\"count\":0,\"procs\":[]}\n";
    off += head.len;

    for (proc_list[0..count], 0..) |p, i| {
        const state_str = switch (p.state) {
            .created => "created",
            .running => "running",
            .exited => "exited",
            _ => "unknown",
        };
        const name_slice = p.name[0..p.name_len];
        if (i > 0 and off < buf.len) {
            buf[off] = ',';
            off += 1;
        }
        const row = std.fmt.bufPrint(buf[off..], "{{\"pid\":{d},\"name\":\"{s}\",\"state\":\"{s}\",\"exit_status\":{d}}}", .{
            p.pid,
            name_slice,
            state_str,
            p.exit_status,
        }) catch break;
        off += row.len;
    }
    if (off + 3 <= buf.len) {
        @memcpy(buf[off .. off + 3], "]}\n");
        off += 3;
    }
    return buf[0..off];
}

/// Format dynamic HTML file explorer listing volume files.
pub fn format_file_browser(buf: []u8) []const u8 {
    var entries: [32]ui.DirEntry = undefined;
    const count = ui.dir_list("", &entries);

    const head =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <title>DipshitOS Storage Explorer</title>
        \\  <style>
        \\    body { font-family: -apple-system, monospace; background: #0f172a; color: #f8fafc; padding: 32px 24px; line-height: 1.5; }
        \\    .container { max-width: 960px; margin: 0 auto; }
        \\    h1 { color: #38bdf8; margin-bottom: 16px; border-bottom: 2px solid #334155; padding-bottom: 8px; }
        \\    table { width: 100%; border-collapse: collapse; background: #1e293b; border: 1px solid #334155; border-radius: 8px; overflow: hidden; margin-top: 16px; }
        \\    th, td { text-align: left; padding: 12px 16px; border-bottom: 1px solid #334155; }
        \\    th { background: #0b1120; color: #94a3b8; font-size: 12px; text-transform: uppercase; }
        \\    tr:hover { background: rgba(255,255,255,0.02); }
        \\    a { color: #38bdf8; text-decoration: none; }
        \\    a:hover { text-decoration: underline; }
        \\    .btn { display: inline-block; background: #3b82f6; color: #fff; padding: 4px 10px; border-radius: 4px; font-size: 12px; font-weight: 500; }
        \\    .btn:hover { background: #2563eb; }
        \\    .back { display: inline-block; margin-bottom: 16px; color: #94a3b8; font-size: 14px; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="container">
        \\    <a href="/" class="back">&larr; Return to Control Center</a>
        \\    <h1>FAT32 Storage Explorer</h1>
        \\    <table>
        \\      <thead>
        \\        <tr><th>File Name</th><th>Size</th><th>Action</th></tr>
        \\      </thead>
        \\      <tbody>
    ;

    var off: usize = 0;
    if (head.len <= buf.len) {
        @memcpy(buf[0..head.len], head);
        off = head.len;
    } else {
        return "<!DOCTYPE html><html><body><h1>Storage Explorer</h1></body></html>";
    }

    if (count > 0) {
        const n: usize = @intCast(count);
        for (entries[0..n]) |entry| {
            var name_len: usize = 0;
            while (name_len < 32 and entry.name[name_len] != 0) : (name_len += 1) {}
            const name = entry.name[0..name_len];
            const row = std.fmt.bufPrint(buf[off..],
                \\        <tr>
                \\          <td><strong>{s}</strong></td>
                \\          <td>{d} B</td>
                \\          <td><a href="/{s}" class="btn" download>Download</a></td>
                \\        </tr>
                \\
            , .{ name, entry.size, name }) catch break;
            off += row.len;
        }
    }

    const tail =
        \\      </tbody>
        \\    </table>
        \\  </div>
        \\</body>
        \\</html>
    ;
    if (off + tail.len <= buf.len) {
        @memcpy(buf[off .. off + tail.len], tail);
        off += tail.len;
    }

    return buf[0..off];
}

/// Send an entire slice over TCP in 64-byte chunks.
pub fn send_all(data: []const u8) void {
    var offset: usize = 0;
    while (offset < data.len) {
        const chunk_size = @min(data.len - offset, send_chunk_max);
        const sent = ui.tcp_send(data[offset .. offset + chunk_size]);
        if (sent <= 0) break;
        offset += @as(usize, @intCast(sent));
    }
}

/// Send standard HTTP response headers.
pub fn send_headers(status_code: []const u8, content_type: []const u8, content_len: usize) void {
    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 {s}\r\nServer: DipshitOS\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status_code, content_type, content_len }) catch "HTTP/1.1 200 OK\r\nServer: DipshitOS\r\nConnection: close\r\n\r\n";
    send_all(hdr);
}

/// Handle a single parsed HTTP request.
pub fn handle_request(req: Request) void {
    if (req.method == .unsupported) {
        const err_body = "HTTP/1.1 405 Method Not Allowed\r\nServer: DipshitOS\r\nContent-Length: 22\r\nConnection: close\r\n\r\n405 Method Not Allowed\n";
        send_all(err_body);
        return;
    }

    if (std.mem.eql(u8, req.path, "/") or std.mem.eql(u8, req.path, "/index.html")) {
        send_headers("200 OK", "text/html; charset=utf-8", html_dashboard.len);
        if (req.method == .get) {
            send_all(html_dashboard);
        }
        return;
    }

    if (std.mem.eql(u8, req.path, "/api/status")) {
        var dyn_buf: [1024]u8 = undefined;
        const payload = format_api_status(&dyn_buf);
        send_headers("200 OK", "application/json", payload.len);
        if (req.method == .get) {
            send_all(payload);
        }
        return;
    }

    if (std.mem.eql(u8, req.path, "/api/procs")) {
        var dyn_buf: [2048]u8 = undefined;
        const payload = format_api_procs(&dyn_buf);
        send_headers("200 OK", "application/json", payload.len);
        if (req.method == .get) {
            send_all(payload);
        }
        return;
    }

    if (std.mem.eql(u8, req.path, "/files") or std.mem.eql(u8, req.path, "/browse")) {
        var dyn_buf: [4096]u8 = undefined;
        const payload = format_file_browser(&dyn_buf);
        send_headers("200 OK", "text/html; charset=utf-8", payload.len);
        if (req.method == .get) {
            send_all(payload);
        }
        return;
    }

    // Static file serving from FAT32
    const clean_path = sanitize_path(req.path);
    if (clean_path == null) {
        const err_400 = "HTTP/1.1 400 Bad Request\r\nServer: DipshitOS\r\nContent-Length: 16\r\nConnection: close\r\n\r\n400 Bad Request\n";
        send_all(err_400);
        return;
    }

    const file_path = clean_path.?;
    const fd = ui.file_open(file_path, ui.MODE_READ);
    if (fd < 0) {
        const not_found = "<!DOCTYPE html><html><body><h1>404 Not Found</h1><p>File not found on DipshitOS.</p></body></html>\n";
        send_headers("404 Not Found", "text/html; charset=utf-8", not_found.len);
        if (req.method == .get) {
            send_all(not_found);
        }
        return;
    }
    defer ui.file_close(@intCast(fd));

    const mime = mime_for_path(file_path);
    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nServer: DipshitOS\r\nContent-Type: {s}\r\nConnection: close\r\n\r\n", .{mime}) catch "HTTP/1.1 200 OK\r\nServer: DipshitOS\r\nConnection: close\r\n\r\n";
    send_all(hdr);

    if (req.method == .get) {
        var read_buf: [64]u8 = undefined;
        while (true) {
            const bytes_read = ui.file_read(@intCast(fd), &read_buf);
            if (bytes_read <= 0) break;
            const count: usize = @intCast(bytes_read);
            send_all(read_buf[0..count]);
            if (count < read_buf.len) break;
        }
    }
}

pub export fn _start() callconv(.c) noreturn {
    ui.write_console("httpd: starting\n");

    const port = default_port;
    const listen_rc = ui.tcp_listen(port);
    if (listen_rc < 0) {
        ui.write_console("httpd: listen failed\n");
        ui.exit_process(1);
    }
    ui.write_console("httpd: listening on port 8080\n");

    var rx_buf: [max_req_len]u8 = undefined;
    var req_len: usize = 0;

    while (true) {
        ui.yield_task();

        var chunk: [64]u8 = undefined;
        const n = ui.tcp_recv(&chunk);
        if (n > 0) {
            const count: usize = @intCast(n);
            const space = max_req_len - req_len;
            const take = @min(space, count);
            @memcpy(rx_buf[req_len .. req_len + take], chunk[0..take]);
            req_len += take;

            // Check if end of HTTP headers reached (\r\n\r\n or \n\n)
            const raw_req = rx_buf[0..req_len];
            if (std.mem.indexOf(u8, raw_req, "\r\n\r\n") != null or std.mem.indexOf(u8, raw_req, "\n\n") != null) {
                if (parse_request(raw_req)) |req| {
                    ui.write_console("httpd: request ");
                    ui.write_console(req.path);
                    ui.write_console("\n");
                    handle_request(req);
                    _ = ui.tcp_close();
                    ui.write_console("httpd: served\n");
                }
                req_len = 0;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Host tests
// ---------------------------------------------------------------------------

test "httpd: parse_request GET and HEAD" {
    const raw_get = "GET /api/status HTTP/1.1\r\nHost: 10.0.0.1\r\nUser-Agent: curl/8.0\r\n\r\n";
    const req1 = parse_request(raw_get);
    try std.testing.expect(req1 != null);
    try std.testing.expectEqual(Method.get, req1.?.method);
    try std.testing.expectEqualStrings("/api/status", req1.?.path);
    try std.testing.expectEqualStrings("HTTP/1.1", req1.?.version);

    const raw_head = "HEAD /README.TXT HTTP/1.0\r\n\r\n";
    const req2 = parse_request(raw_head);
    try std.testing.expect(req2 != null);
    try std.testing.expectEqual(Method.head, req2.?.method);
    try std.testing.expectEqualStrings("/README.TXT", req2.?.path);
}

test "httpd: sanitize_path prevents directory traversal" {
    try std.testing.expectEqualStrings("index.html", sanitize_path("/index.html").?);
    try std.testing.expectEqualStrings("README.TXT", sanitize_path("README.TXT").?);
    try std.testing.expectEqual(null, sanitize_path("/../etc/passwd"));
    try std.testing.expectEqual(null, sanitize_path("foo/../bar"));
}

test "httpd: mime_for_path maps known extensions" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mime_for_path("index.html"));
    try std.testing.expectEqualStrings("application/json", mime_for_path("data.json"));
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", mime_for_path("APPS.TXT"));
    try std.testing.expectEqualStrings("image/bmp", mime_for_path("screen.bmp"));
    try std.testing.expectEqualStrings("application/octet-stream", mime_for_path("CALC.BIN"));
}

test "httpd: format_api_status contains valid JSON keys" {
    var buf: [1024]u8 = undefined;
    const json = format_api_status(&buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"os\": \"DipshitOS\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"uptime_seconds\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"procs_count\":") != null);
}

test "httpd: format_api_procs contains valid JSON shape" {
    var buf: [1024]u8 = undefined;
    const json = format_api_procs(&buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"procs\":") != null);
}

test "httpd: format_file_browser generates HTML table" {
    var buf: [2048]u8 = undefined;
    const html = format_file_browser(&buf);
    try std.testing.expect(std.mem.indexOf(u8, html, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "FAT32 Storage Explorer") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "</table>") != null);
}
