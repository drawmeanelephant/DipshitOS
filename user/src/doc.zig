//! VirelaiOS DOC.BIN — M-web in-guest HTML viewer (issues #1202–#1206, ADR 0028).
//!
//! `exec DOC.BIN /host/PAGE.HTML` or `exec DOC.BIN http://10.0.0.2/page.html`
//! parses and lays out a page (oliver output is the fixture of record) and
//! paints it through TabApp. No JS, no CSS cascade, no kernel changes.
//!
//! Parse/layout/url are the pure modules in `lib/html/`; this file is the
//! only one that touches the framebuffer, files, and TCP.

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("lib/ui.zig");
const tabapp = @import("lib/tabapp.zig");
const png = @import("lib/png.zig");
const qoi = @import("lib/qoi.zig");
const netstatus = @import("lib/netstatus.zig");
const html_parse = @import("lib/html/parse.zig");
const html_layout = @import("lib/html/layout.zig");
const html_url = @import("lib/html/url.zig");

const Event = ui.Event;
const Rect = ui.Rect;

pub const window_x: u32 = 40;
pub const window_y: u32 = 28;
pub const window_w: u32 = 512;
pub const window_h: u32 = 384;
pub const title_band_h: u32 = 16;
pub const status_h: u32 = 16;
pub const exit_status: u32 = 43;

pub const map_flags: u64 = ui.MAP_ANONYMOUS | ui.MAP_PRIVATE | ui.MAP_POPULATE;
pub const prot_rw: u64 = ui.PROT_READ | ui.PROT_WRITE;
pub const file_max: usize = 64 * 1024;
pub const path_max: usize = 96;
pub const img_slots: usize = 4;
pub const img_px_cap: usize = 16384;
pub const img_file_max: usize = 64 * 1024;
pub const dns_port: u16 = 53;
pub const dns_client_port: u16 = 7001;
pub const dns_server: [4]u8 = .{ 10, 0, 0, 2 };

pub const key_up: u32 = 0x52;
pub const key_down: u32 = 0x51;
pub const key_pageup: u32 = 0x4b;
pub const key_pagedown: u32 = 0x4e;
pub const key_home: u32 = 0x4a;
pub const key_end: u32 = 0x4d;
pub const key_quit_q: u32 = 0x14;
pub const key_escape: u32 = 0x29;

const ErrKind = enum {
    none,
    missing,
    read,
    too_large,
    mmap,
    dns,
    connect,
    timeout,
    refused,
    status,
    scheme,
};

const DecodedImg = struct {
    path_len: usize = 0,
    w: u32 = 0,
    h: u32 = 0,
    ok: bool = false,
    pixels: []u32 = &.{},
};

const State = struct {
    win: u32 = 0,
    win_w: u32 = window_w,
    win_h: u32 = window_h,
    scroll: u32 = 0,
    loaded: bool = false,
    err: ErrKind = .none,
    http_status: u16 = 0,
    path_buf: [path_max]u8 = [_]u8{0} ** path_max,
    path_len: usize = 0,
    hover_buf: [path_max]u8 = [_]u8{0} ** path_max,
    hover_len: usize = 0,
    file_len: usize = 0,
    parse_nodes: u16 = 0,
    layout_blocks: u16 = 0,
    layout_lines: u16 = 0,
    content_h: u32 = 0,
    truncated: bool = false,
    probe_h1: u16 = 0,
    probe_quote: u16 = 0,
    probe_pre: u16 = 0,
    probe_hr: u16 = 0,
    probe_table: u16 = 0,
    probe_h4: u16 = 0,
    probe_dt: u16 = 0,
    img_count: u8 = 0,
    nav_paint: bool = false,
};

var st: State = .{};
var file_bytes: []u8 = &.{};
var img_file: []u8 = &.{};
var png_idat: []u8 = &.{};
var png_decomp: []u8 = &.{};
var png_prev_row: [png.MAX_ROW_BYTES]u8 = [_]u8{0} ** png.MAX_ROW_BYTES;
var png_cur_row: [png.MAX_ROW_BYTES]u8 = [_]u8{0} ** png.MAX_ROW_BYTES;
var images: [img_slots]DecodedImg = [_]DecodedImg{.{}} ** img_slots;
var img_paths: [img_slots][path_max]u8 = undefined;
var nodes: [html_parse.max_nodes]html_parse.Node = undefined;
var text_buf: [html_parse.max_text]u8 = undefined;
var blocks: [html_layout.max_blocks]html_layout.Block = undefined;
var lines: [html_layout.max_lines]html_layout.Line = undefined;
var spans: [html_layout.max_spans]html_layout.Span = undefined;
var doc: html_parse.Document = .{
    .nodes = nodes[0..],
    .node_count = 0,
    .text = text_buf[0..],
    .text_len = 0,
    .truncated = false,
};
var lay: html_layout.Layout = .{
    .blocks = blocks[0..],
    .block_count = 0,
    .lines = lines[0..],
    .line_count = 0,
    .spans = spans[0..],
    .span_count = 0,
    .text = &.{},
    .content_h = 0,
    .truncated = false,
};

fn guestMeasure(text: []const u8, mono: bool, size: u32) u32 {
    if (mono) return ui.measure_text_mono(text);
    return ui.measure_text_sized(text, size);
}

fn guestImageSize(src: []const u8) html_layout.ImageMetrics {
    if (findImage(src)) |img| {
        if (img.ok and img.w > 0 and img.h > 0) {
            return .{ .w = img.w, .h = img.h, .ok = true };
        }
    }
    return .{ .w = html_layout.placeholder_w, .h = html_layout.placeholder_h, .ok = false };
}

fn findImage(src: []const u8) ?*DecodedImg {
    var i: u8 = 0;
    while (i < st.img_count) : (i += 1) {
        if (std.mem.eql(u8, img_paths[i][0..images[i].path_len], src)) return &images[i];
    }
    return null;
}

fn map_region(len: usize) []u8 {
    const va = ui.mmap(0, len, prot_rw, map_flags);
    if (va == 0 or va > std.math.maxInt(usize)) {
        ui.write_console("doc: mmap failed\n");
        return &.{};
    }
    return @as([*]u8, @ptrFromInt(@as(usize, @intCast(va))))[0..len];
}

fn map_pixels(len: usize) []u32 {
    const bytes = map_region(len * @sizeOf(u32));
    if (bytes.len < len * @sizeOf(u32)) return &.{};
    const ptr: [*]u32 = @ptrCast(@alignCast(bytes.ptr));
    return ptr[0..len];
}

fn basename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return path[i + 1 ..];
    }
    return path;
}

fn setPath(path: []const u8) void {
    const take = @min(path.len, path_max);
    @memcpy(st.path_buf[0..take], path[0..take]);
    st.path_len = take;
}

fn fail(kind: ErrKind, marker: []const u8) void {
    st.err = kind;
    st.loaded = false;
    ui.write_console(marker);
}

fn readFileInto(path: []const u8, dest: []u8) ?usize {
    const fd = ui.file_open(path, ui.MODE_READ);
    if (fd < 0) return null;
    const handle: u32 = @intCast(fd);
    defer ui.file_close(handle);
    var total: usize = 0;
    var staging: [2048]u8 = undefined;
    while (total < dest.len) {
        const n = ui.file_read(handle, staging[0..]);
        if (n < 0) return null;
        if (n == 0) break;
        const take = @min(@as(usize, @intCast(n)), dest.len - total);
        @memcpy(dest[total .. total + take], staging[0..take]);
        total += take;
        if (take < @as(usize, @intCast(n))) break;
    }
    if (total == dest.len) {
        if (ui.file_read(handle, staging[0..1]) > 0) return std.math.maxInt(usize);
    }
    return total;
}

fn parseAndLayout(bytes: []const u8) void {
    st.probe_h1 = 0;
    st.probe_quote = 0;
    st.probe_pre = 0;
    st.probe_hr = 0;
    st.probe_table = 0;
    st.probe_h4 = 0;
    st.probe_dt = 0;
    doc = html_parse.parse(bytes, nodes[0..], text_buf[0..]);
    st.parse_nodes = doc.node_count;
    st.truncated = doc.truncated;
    var pbuf: [80]u8 = undefined;
    const pline = std.fmt.bufPrint(&pbuf, "doc: parse nodes={d} text={d} truncated={d}\n", .{
        doc.node_count, doc.text_len, @intFromBool(doc.truncated),
    }) catch "doc: parse\n";
    ui.write_console(pline);

    loadImages();

    const content_w = if (st.win_w > 0) st.win_w else window_w;
    lay = html_layout.layoutWith(doc, content_w, blocks[0..], lines[0..], spans[0..], guestMeasure, guestImageSize);
    st.layout_blocks = lay.block_count;
    st.layout_lines = lay.line_count;
    st.content_h = lay.content_h;
    st.truncated = st.truncated or lay.truncated;
    captureProbes();

    var lbuf: [96]u8 = undefined;
    const lline = std.fmt.bufPrint(&lbuf, "doc: layout blocks={d} lines={d} h={d}\n", .{
        lay.block_count, lay.line_count, lay.content_h,
    }) catch "doc: layout\n";
    ui.write_console(lline);

    var qbuf: [80]u8 = undefined;
    const qline = std.fmt.bufPrint(&qbuf, "doc: probe h1={d} quote={d} pre={d} hr={d}\n", .{
        st.probe_h1, st.probe_quote, st.probe_pre, st.probe_hr,
    }) catch "doc: probe\n";
    ui.write_console(qline);

    var q2buf: [80]u8 = undefined;
    const q2line = std.fmt.bufPrint(&q2buf, "doc: probe2 table={d} h4={d} dt={d}\n", .{
        st.probe_table, st.probe_h4, st.probe_dt,
    }) catch "doc: probe2\n";
    ui.write_console(q2line);

    st.loaded = true;
    st.err = .none;
}

fn load(path: []const u8) void {
    if (path.len == 0) {
        fail(.missing, "doc: error missing\n");
        return;
    }
    setPath(path);
    if (file_bytes.len == 0) {
        fail(.mmap, "doc: error mmap\n");
        return;
    }
    const n = readFileInto(path, file_bytes[0..file_max]) orelse {
        fail(.missing, "doc: error missing\n");
        return;
    };
    if (n == std.math.maxInt(usize)) {
        fail(.too_large, "doc: error too-large\n");
        return;
    }
    st.file_len = n;
    parseAndLayout(file_bytes[0..n]);
}

fn loadHttp(url: []const u8) void {
    setPath(url);
    const parsed = html_url.parseHttpUrl(url) orelse {
        fail(.scheme, "doc: error scheme\n");
        return;
    };
    if (file_bytes.len == 0) {
        fail(.mmap, "doc: error mmap\n");
        return;
    }

    var ip = parsed.ipv4;
    if (ip == null) {
        ip = lookupDns(parsed.host);
        if (ip == null) {
            fail(.dns, "doc: error dns\n");
            return;
        }
    }
    const dest = ip.?;

    if (builtin.os.tag == .freestanding) {
        const verdict = netstatus.check(dest);
        switch (verdict.diagnosis) {
            .offline_no_ip => {
                fail(.connect, "doc: error connect\n");
                return;
            },
            .no_route => {
                fail(.refused, "doc: error refused\n");
                return;
            },
            .ready, .unknown => {},
        }
    }

    const conn_rc = ui.tcp_connect(html_url.ipv4ToU32(dest), parsed.port);
    if (conn_rc < 0) {
        fail(.connect, "doc: error connect\n");
        return;
    }
    defer _ = ui.tcp_close();

    var req_buf: [256]u8 = undefined;
    const req = html_url.formatGetRequest(&req_buf, parsed.host, parsed.path) orelse {
        fail(.missing, "doc: error missing\n");
        return;
    };
    if (ui.tcp_send(req) < 0) {
        fail(.refused, "doc: error refused\n");
        return;
    }

    var total: usize = 0;
    var empty_polls: usize = 0;
    var rx: [64]u8 = undefined;
    while (empty_polls < 50 and total < file_max) {
        const n = ui.tcp_recv(&rx);
        if (n > 0) {
            const count: usize = @intCast(n);
            const take = @min(count, file_max - total);
            @memcpy(file_bytes[total .. total + take], rx[0..take]);
            total += take;
            empty_polls = 0;
            if (take < count) break;
        } else {
            empty_polls += 1;
            ui.yield_task();
        }
    }
    if (total == 0) {
        fail(.timeout, "doc: error timeout\n");
        return;
    }

    const hdr_end = html_url.headerEnd(file_bytes[0..total]) orelse {
        fail(.timeout, "doc: error timeout\n");
        return;
    };
    const code = html_url.parseStatusCode(file_bytes[0..hdr_end]) orelse 0;
    st.http_status = code;
    if (code != 200) {
        var sbuf: [40]u8 = undefined;
        const sline = std.fmt.bufPrint(&sbuf, "doc: error http {d}\n", .{code}) catch "doc: error http\n";
        fail(.status, sline);
        return;
    }
    const body = file_bytes[hdr_end..total];
    if (total == file_max) {
        fail(.too_large, "doc: error too-large\n");
        return;
    }
    var fbuf: [80]u8 = undefined;
    const fline = std.fmt.bufPrint(&fbuf, "doc: fetch status={d} bytes={d}\n", .{ code, body.len }) catch "doc: fetch\n";
    ui.write_console(fline);
    st.file_len = body.len;
    parseAndLayout(body);
}

fn lookupDns(hostname: []const u8) ?[4]u8 {
    if (html_url.parseIpv4(hostname)) |ip| return ip;
    var qbuf: [512]u8 = undefined;
    const qlen = html_url.encodeDnsQuery(&qbuf, 0x1234, hostname) catch return null;
    if (builtin.os.tag != .freestanding) return null;

    _ = ui.udp_listen(dns_client_port);
    const server_u32 = html_url.ipv4ToU32(dns_server);
    var sent = false;
    var retry: usize = 0;
    while (retry < 50) : (retry += 1) {
        var dummy: [16]u8 = undefined;
        _ = ui.udp_recv(dns_client_port, &dummy);
        if (ui.udp_send(server_u32, dns_port, qbuf[0..qlen]) > 0) {
            sent = true;
            break;
        }
        ui.yield_task();
    }
    if (!sent) return null;

    var rbuf: [512]u8 = undefined;
    var rlen: usize = 0;
    var polls: usize = 0;
    while (polls < 50) : (polls += 1) {
        const rc = ui.udp_recv(dns_client_port, &rbuf);
        if (rc > 8) {
            rlen = @intCast(rc);
            break;
        }
        ui.yield_task();
    }
    if (rlen <= 8) return null;
    return html_url.parseDnsA(rbuf[8..rlen], 0x1234) catch null;
}

fn loadImages() void {
    st.img_count = 0;
    var i: u16 = 0;
    while (i < doc.node_count and st.img_count < img_slots) : (i += 1) {
        if (doc.nodes[i].tag != .img) continue;
        const raw = doc.hrefOf(i);
        var resolved: [path_max]u8 = undefined;
        const path = html_url.resolveHref(st.path_buf[0..st.path_len], raw, &resolved) orelse continue;
        if (html_url.isExternalUrl(path)) continue;
        decodeImage(st.img_count, path);
        st.img_count += 1;
    }
}

fn decodeImage(slot: u8, path: []const u8) void {
    const take = @min(path.len, path_max);
    @memcpy(img_paths[slot][0..take], path[0..take]);
    images[slot] = .{ .path_len = take, .ok = false };
    if (img_file.len == 0) img_file = map_region(img_file_max);
    if (img_file.len == 0) return;
    const n = readFileInto(path, img_file) orelse return;
    if (n == 0 or n == std.math.maxInt(usize)) return;
    const bytes = img_file[0..n];
    if (images[slot].pixels.len == 0) images[slot].pixels = map_pixels(img_px_cap);
    if (images[slot].pixels.len < img_px_cap) return;

    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "qoif")) {
        const hdr = qoi.decode(bytes, images[slot].pixels) catch return;
        finishImage(slot, hdr.width, hdr.height);
        return;
    }
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) {
        const info = png.scan(bytes) catch return;
        const total_px = @as(usize, info.width) * info.height;
        if (total_px == 0 or total_px > img_px_cap) return;
        const row_bytes = info.row_bytes();
        if (row_bytes == 0 or row_bytes > png.MAX_ROW_BYTES) return;
        if (png_idat.len < info.idat_total) png_idat = map_region(if (info.idat_total == 0) 1 else info.idat_total);
        if (png_decomp.len < info.decomp_total) png_decomp = map_region(if (info.decomp_total == 0) 1 else info.decomp_total);
        if (png_idat.len < info.idat_total or png_decomp.len < info.decomp_total) return;
        const hdr = png.decode_with_buffers(
            bytes,
            images[slot].pixels,
            png_idat[0..info.idat_total],
            png_decomp[0..info.decomp_total],
            &png_prev_row,
            &png_cur_row,
        ) catch return;
        finishImage(slot, hdr.width, hdr.height);
    }
}

fn finishImage(slot: u8, w: u32, h: u32) void {
    const total = @as(usize, w) * h;
    if (total == 0 or total > img_px_cap) return;
    images[slot].w = w;
    images[slot].h = h;
    images[slot].ok = true;
    var mbuf: [80]u8 = undefined;
    const mline = std.fmt.bufPrint(&mbuf, "doc: img {s} {d}x{d}\n", .{
        img_paths[slot][0..images[slot].path_len], w, h,
    }) catch "doc: img\n";
    ui.write_console(mline);
}

fn captureProbes() void {
    var i: u16 = 0;
    while (i < lay.block_count) : (i += 1) {
        const b = lay.blocks[i];
        if (st.probe_h1 == 0 and b.tag == .h1) st.probe_h1 = b.y;
        if (st.probe_quote == 0 and b.quote_bar) st.probe_quote = b.y;
        if (st.probe_pre == 0 and b.tag == .pre) st.probe_pre = b.y;
        if (st.probe_hr == 0 and b.kind == .hr) st.probe_hr = b.y;
        if (st.probe_table == 0 and b.kind == .table) st.probe_table = b.y;
        if (st.probe_h4 == 0 and b.tag == .h4) st.probe_h4 = b.y;
        if (st.probe_dt == 0 and b.tag == .dt) st.probe_dt = b.y;
    }
}

fn contentRect() Rect {
    const top = title_band_h;
    const h = if (st.win_h > top + status_h) st.win_h - top - status_h else 1;
    return Rect.make(0, top, st.win_w, h);
}

fn maxScroll() u32 {
    const cr = contentRect();
    if (st.content_h > cr.h) return st.content_h - cr.h;
    return 0;
}

fn clampScroll() void {
    const max = maxScroll();
    if (st.scroll > max) st.scroll = max;
}

fn draw(win: u32) void {
    ui.draw_rect(win, Rect.make(0, 0, st.win_w, st.win_h), ui.theme_bg());
    const cr = contentRect();
    if (st.err != .none or !st.loaded) {
        drawError(win, cr);
    } else {
        drawPage(win, cr);
    }
    drawStatus(win);
    ui.flush_fills();
}

fn drawError(win: u32, cr: Rect) void {
    const msg: []const u8 = switch (st.err) {
        .missing => "cannot open file",
        .read => "cannot read file",
        .too_large => "file too large",
        .mmap => "mmap failed",
        .dns => "dns lookup failed",
        .connect => "connect failed",
        .timeout => "fetch timed out",
        .refused => "connection refused",
        .status => "http error",
        .scheme => "unsupported url",
        .none => "no document",
    };
    ui.draw_text_sized(win, msg, cr.x + 12, cr.y + 12, 14, ui.theme_danger());
    if (st.path_len > 0) {
        ui.draw_text_mono(win, st.path_buf[0..st.path_len], cr.x + 12, cr.y + 32, ui.theme_text_muted());
    }
}

fn drawPage(win: u32, cr: Rect) void {
    const ink = ui.theme_text_primary();
    const accent = ui.theme_accent();
    const surface = ui.theme_surface();
    const border = ui.theme_border();
    var bi: u16 = 0;
    while (bi < lay.block_count) : (bi += 1) {
        const b = lay.blocks[bi];
        const by = @as(i32, @intCast(cr.y)) + @as(i32, @intCast(b.y)) - @as(i32, @intCast(st.scroll));
        const bh: i32 = @intCast(b.h);
        if (by + bh < @as(i32, @intCast(cr.y))) continue;
        if (by > @as(i32, @intCast(cr.y + cr.h))) continue;

        if (b.kind == .pre and b.h > 0 and by >= 0) {
            const y: u32 = @intCast(by);
            const clip_h = clipH(y, b.h, cr);
            if (clip_h > 0) {
                ui.draw_rect(win, Rect.make(b.x, y, b.w, clip_h), surface);
            }
        }
        if (b.kind == .cell and b.header_rule and b.h > 0 and by >= 0) {
            const y: u32 = @intCast(by);
            const clip_h = clipH(y, b.h, cr);
            if (clip_h > 0) {
                ui.draw_rect(win, Rect.make(b.x, y, b.w, clip_h), surface);
            }
        }
        if (b.quote_bar and b.h > 0 and by >= 0) {
            const y: u32 = @intCast(by);
            const clip_h = clipH(y, b.h, cr);
            const bar_x = if (b.x > 6) b.x - 6 else 0;
            if (clip_h > 0) ui.draw_rect(win, Rect.make(bar_x, y, html_layout.quote_bar_w, clip_h), accent);
        }
        if (b.kind == .hr and by >= 0) {
            const y: u32 = @intCast(by);
            if (y >= cr.y and y < cr.y + cr.h) {
                ui.draw_rect(win, Rect.make(b.x, y, b.w, 1), border);
            }
        }
        if (b.kind == .image and by >= 0) {
            const y: u32 = @intCast(by);
            if (y < cr.y + cr.h) {
                drawImageBlock(win, b, y, cr);
            }
        }
        if (b.marker != .none and b.line_count > 0) {
            const line = lay.lines[b.first_line];
            const ly = @as(i32, @intCast(cr.y)) + @as(i32, @intCast(line.y)) - @as(i32, @intCast(st.scroll));
            if (ly >= @as(i32, @intCast(cr.y)) and ly < @as(i32, @intCast(cr.y + cr.h))) {
                const my: u32 = @intCast(ly + @as(i32, @intCast(line.h / 2)) - 2);
                if (b.marker == .disc) {
                    ui.draw_rect(win, Rect.make(b.x + 2, my, 4, 4), ink);
                } else {
                    var mbuf: [4]u8 = undefined;
                    const ms = std.fmt.bufPrint(&mbuf, "{d}.", .{b.marker_index}) catch "?.";
                    ui.draw_text_sized(win, ms, b.x, @intCast(ly), 14, ink);
                }
            }
        }

        var li: u16 = 0;
        while (li < b.line_count) : (li += 1) {
            const line = lay.lines[b.first_line + li];
            const ly = @as(i32, @intCast(cr.y)) + @as(i32, @intCast(line.y)) - @as(i32, @intCast(st.scroll));
            if (ly + @as(i32, @intCast(line.h)) < @as(i32, @intCast(cr.y))) continue;
            if (ly > @as(i32, @intCast(cr.y + cr.h))) break;
            if (ly < 0) continue;
            const y: u32 = @intCast(ly);
            var si: u16 = 0;
            while (si < line.span_count) : (si += 1) {
                const sp = lay.spans[line.first_span + si];
                const slice = lay.spanText(sp);
                if (slice.len == 0) continue;
                const sx = line.x + sp.x;
                var color = ink;
                if (sp.flags.em or sp.flags.link) color = accent;
                if (b.tag == .dt) color = ink;
                if (sp.flags.mono) {
                    if (sp.text_len > 0) {
                        ui.draw_rect(win, Rect.make(sx, y, sp.w, line.h), surface);
                    }
                    ui.draw_text_mono(win, slice, sx, y, color);
                } else {
                    ui.draw_text_sized(win, slice, sx, y, sp.size, color);
                    if (sp.flags.bold or b.tag == .th or b.tag == .dt) {
                        ui.draw_text_sized(win, slice, sx + 1, y, sp.size, color);
                    }
                    if (sp.flags.link) {
                        const uy = y + line.h - 2;
                        if (uy >= cr.y and uy < cr.y + cr.h) {
                            ui.draw_rect(win, Rect.make(sx, uy, sp.w, 1), accent);
                        }
                    }
                }
            }
        }
    }
}

fn drawImageBlock(win: u32, b: html_layout.Block, y: u32, cr: Rect) void {
    const src = if (b.node_idx != html_parse.none) doc.hrefOf(b.node_idx) else &.{};
    var resolved: [path_max]u8 = undefined;
    const path = html_url.resolveHref(st.path_buf[0..st.path_len], src, &resolved) orelse src;
    if (findImage(path)) |img| {
        if (img.ok and img.w > 0 and img.h > 0 and img.pixels.len >= @as(usize, img.w) * img.h) {
            const dest = Rect.make(b.x, y, b.w, b.h);
            const picture = ui.Image{
                .width = img.w,
                .height = img.h,
                .pixels = img.pixels[0 .. @as(usize, img.w) * img.h],
            };
            ui.draw_image_scaled(win, dest, picture);
            return;
        }
    }
    const clip_h = clipH(y, b.h, cr);
    if (clip_h == 0) return;
    ui.draw_rect(win, Rect.make(b.x, y, b.w, clip_h), ui.theme_surface());
    ui.draw_rect(win, Rect.make(b.x, y, b.w, 1), ui.theme_border());
    if (clip_h > 12) {
        ui.draw_text_sized(win, "img", b.x + 4, y + 4, 11, ui.theme_text_muted());
    }
}

fn clipH(y: u32, h: u16, cr: Rect) u32 {
    var top = y;
    var bottom = y + h;
    if (top < cr.y) top = cr.y;
    if (bottom > cr.y + cr.h) bottom = cr.y + cr.h;
    if (bottom <= top) return 0;
    return bottom - top;
}

fn drawStatus(win: u32) void {
    const y = if (st.win_h > status_h) st.win_h - status_h else 0;
    ui.draw_rect(win, Rect.make(0, y, st.win_w, status_h), ui.theme_surface());
    var buf: [96]u8 = undefined;
    const line = if (st.hover_len > 0)
        std.fmt.bufPrint(&buf, "{s}", .{st.hover_buf[0..st.hover_len]}) catch "DOC"
    else blk: {
        const name = if (st.path_len > 0) basename(st.path_buf[0..st.path_len]) else "DOC";
        break :blk std.fmt.bufPrint(&buf, "{s}  {d}/{d}", .{ name, st.scroll, maxScroll() }) catch "DOC";
    };
    ui.draw_text_sized(win, line, 8, y + 2, 11, ui.theme_text_muted());
}

fn relayout() void {
    if (!st.loaded) return;
    lay = html_layout.layoutWith(doc, st.win_w, blocks[0..], lines[0..], spans[0..], guestMeasure, guestImageSize);
    st.layout_blocks = lay.block_count;
    st.layout_lines = lay.line_count;
    st.content_h = lay.content_h;
    captureProbes();
    clampScroll();
}

fn openTarget(dest: []const u8, ta: *tabapp.TabApp) void {
    var nbuf: [80]u8 = undefined;
    const nline = std.fmt.bufPrint(&nbuf, "doc: nav {s}\n", .{dest}) catch "doc: nav\n";
    ui.write_console(nline);
    ta.declare_nav(dest);
    st.scroll = 0;
    st.hover_len = 0;
    st.nav_paint = true;
    if (html_url.isHttpUrl(dest)) {
        loadHttp(dest);
        return;
    }
    if (html_url.isExternalUrl(dest)) {
        fail(.scheme, "doc: error scheme\n");
        return;
    }
    load(dest);
}

fn hitLink(px: u32, py: u32) ?[]const u8 {
    const cr = contentRect();
    if (py < cr.y or py >= cr.y + cr.h) return null;
    var bi: u16 = 0;
    while (bi < lay.block_count) : (bi += 1) {
        const b = lay.blocks[bi];
        var li: u16 = 0;
        while (li < b.line_count) : (li += 1) {
            const line = lay.lines[b.first_line + li];
            const ly = @as(i32, @intCast(cr.y)) + @as(i32, @intCast(line.y)) - @as(i32, @intCast(st.scroll));
            if (ly < 0) continue;
            const y: u32 = @intCast(ly);
            if (py < y or py >= y + line.h) continue;
            var si: u16 = 0;
            while (si < line.span_count) : (si += 1) {
                const sp = lay.spans[line.first_span + si];
                if (!sp.flags.link or sp.href_len == 0) continue;
                const sx = line.x + sp.x;
                if (px >= sx and px < sx + sp.w) {
                    return lay.text[sp.href_off .. sp.href_off + sp.href_len];
                }
            }
        }
    }
    return null;
}

fn handlePointer(kind: u16, px: u32, py: u32, ta: *tabapp.TabApp, dirty: *bool) void {
    if (kind == ui.MOUSE_MOVE) {
        if (hitLink(px, py)) |href| {
            const take = @min(href.len, path_max);
            if (st.hover_len != take or !std.mem.eql(u8, st.hover_buf[0..take], href[0..take])) {
                @memcpy(st.hover_buf[0..take], href[0..take]);
                st.hover_len = take;
                dirty.* = true;
            }
        } else if (st.hover_len != 0) {
            st.hover_len = 0;
            dirty.* = true;
        }
        return;
    }
    if (kind != ui.MOUSE_DOWN) return;
    const href = hitLink(px, py) orelse return;
    var resolved: [path_max]u8 = undefined;
    const dest = html_url.resolveHref(st.path_buf[0..st.path_len], href, &resolved) orelse return;
    openTarget(dest, ta);
    dirty.* = true;
}

pub export fn _start(argc: usize, argv: ?[*]const [32]u8) callconv(.c) noreturn {
    file_bytes = map_region(file_max);

    var path_buf: [32]u8 = [_]u8{0} ** 32;
    var path_len: usize = 0;
    if (argc >= 1) {
        if (argv) |slots| {
            const slot = slots[0];
            const len = std.mem.indexOfScalar(u8, &slot, 0) orelse slot.len;
            const take = @min(len, 32);
            @memcpy(path_buf[0..take], slot[0..take]);
            path_len = take;
        }
    }

    const ta_res = tabapp.TabApp.init(.{
        .name = "DOC.BIN",
        .title = "Doc",
        .x = window_x,
        .y = window_y,
        .w = window_w,
        .h = window_h,
    }) orelse {
        ui.write_console("doc: failed to open window\n");
        ui.exit_process(1);
    };
    var ta = ta_res;
    st.win = ta.win;
    st.win_w = ta.w;
    st.win_h = ta.h;

    var obuf: [48]u8 = undefined;
    const oline = std.fmt.bufPrint(&obuf, "doc: open id={d} {d}x{d}\n", .{
        st.win, st.win_w, st.win_h,
    }) catch "doc: open\n";
    ui.write_console(oline);

    if (path_len == 0) {
        fail(.missing, "doc: error missing\n");
    } else if (html_url.isHttpUrl(path_buf[0..path_len])) {
        loadHttp(path_buf[0..path_len]);
    } else if (html_url.isExternalUrl(path_buf[0..path_len])) {
        fail(.scheme, "doc: error scheme\n");
    } else {
        load(path_buf[0..path_len]);
    }
    if (st.path_len > 0) ta.declare_nav(st.path_buf[0..st.path_len]);

    draw(st.win);
    ta.present();
    ui.sleep_ticks(2);
    ui.write_console("doc: settled\n");

    var ev: Event = undefined;
    var nav_buf: [96]u8 = undefined;
    while (true) {
        if (ui.wait_event(&ev) < 0) break;
        var dirty = false;
        if (ta.poll_nav(&nav_buf)) |dest| {
            openTarget(dest, &ta);
            dirty = true;
        }
        handleEvent(&ev, &ta, &dirty);
        while (ui.poll_event(&ev) > 0) {
            handleEvent(&ev, &ta, &dirty);
        }
        if (dirty) {
            draw(st.win);
            ta.present();
            if (st.nav_paint) {
                st.nav_paint = false;
                ui.sleep_ticks(2);
                ui.write_console("doc: navigated\n");
            }
        }
    }
    ui.write_console("doc: exiting 43\n");
    ta.close_and_exit(exit_status);
}

fn handleEvent(ev: *Event, ta: *tabapp.TabApp, dirty: *bool) void {
    switch (ta.dispatch(ev)) {
        .closed => {
            ui.write_console("doc: win_close\n");
            ta.close_and_exit(exit_status);
        },
        .resized => {
            st.win_w = ta.w;
            st.win_h = ta.h;
            relayout();
            dirty.* = true;
        },
        .none => {
            if (ev.kind == ui.KEY_DOWN) {
                handleKey(ev.arg0, dirty);
            } else if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_MOVE) {
                handlePointer(ev.kind, ev.arg0, ev.arg1, ta, dirty);
            }
        },
    }
}

fn handleKey(usage: u32, dirty: *bool) void {
    if (usage == key_quit_q or usage == key_escape) {
        ui.write_console("doc: quit\n");
        ui.win_close(st.win);
        ui.exit_process(exit_status);
    }
    const cr = contentRect();
    const step: u32 = 18;
    const page = if (cr.h > 24) cr.h - 24 else cr.h;
    switch (usage) {
        key_up => {
            if (st.scroll > step) st.scroll -= step else st.scroll = 0;
            dirty.* = true;
        },
        key_down => {
            st.scroll += step;
            clampScroll();
            dirty.* = true;
        },
        key_pageup => {
            if (st.scroll > page) st.scroll -= page else st.scroll = 0;
            dirty.* = true;
        },
        key_pagedown => {
            st.scroll += page;
            clampScroll();
            dirty.* = true;
        },
        key_home => {
            st.scroll = 0;
            dirty.* = true;
        },
        key_end => {
            st.scroll = maxScroll();
            dirty.* = true;
        },
        else => {},
    }
}
