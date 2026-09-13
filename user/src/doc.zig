//! VirelaiOS DOC.BIN — M-web S1 in-guest HTML viewer (issue #1202, ADR 0028).
//!
//! `exec DOC.BIN /host/PAGE.HTML` parses and lays out a local HTML page
//! (oliver's output is the fixture of record) and paints it through TabApp.
//! No JS, no CSS cascade, no network, no kernel changes.
//!
//! Parse and layout are the pure modules in `lib/html/`; this file is the
//! only one that touches the framebuffer.

const std = @import("std");
const ui = @import("lib/ui.zig");
const tabapp = @import("lib/tabapp.zig");
const html_parse = @import("lib/html/parse.zig");
const html_layout = @import("lib/html/layout.zig");

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

pub const key_up: u32 = 0x52;
pub const key_down: u32 = 0x51;
pub const key_pageup: u32 = 0x4b;
pub const key_pagedown: u32 = 0x4e;
pub const key_home: u32 = 0x4a;
pub const key_end: u32 = 0x4d;
pub const key_quit_q: u32 = 0x14;
pub const key_escape: u32 = 0x29;

const ErrKind = enum { none, missing, read, too_large, mmap };

const State = struct {
    win: u32 = 0,
    win_w: u32 = window_w,
    win_h: u32 = window_h,
    scroll: u32 = 0,
    loaded: bool = false,
    err: ErrKind = .none,
    name_buf: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
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
};

var st: State = .{};
var file_bytes: []u8 = &.{};
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

fn map_region(len: usize) []u8 {
    const va = ui.mmap(0, len, prot_rw, map_flags);
    if (va == 0 or va > std.math.maxInt(usize)) {
        ui.write_console("doc: mmap failed\n");
        return &.{};
    }
    return @as([*]u8, @ptrFromInt(@as(usize, @intCast(va))))[0..len];
}

fn basename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return path[i + 1 ..];
    }
    return path;
}

fn load(path: []const u8) void {
    if (path.len == 0 or path.len > 32) {
        st.err = .missing;
        return;
    }
    @memcpy(st.name_buf[0..path.len], path);
    st.name_len = path.len;

    if (file_bytes.len == 0) {
        st.err = .mmap;
        ui.write_console("doc: error mmap\n");
        return;
    }

    const fd = ui.file_open(path, ui.MODE_READ);
    if (fd < 0) {
        st.err = .missing;
        ui.write_console("doc: error missing\n");
        return;
    }
    const handle: u32 = @intCast(fd);
    defer ui.file_close(handle);

    var total: usize = 0;
    var staging: [2048]u8 = undefined;
    while (total < file_max) {
        const n = ui.file_read(handle, staging[0..]);
        if (n < 0) {
            st.err = .read;
            ui.write_console("doc: error read\n");
            return;
        }
        if (n == 0) break;
        @memcpy(file_bytes[total .. total + @as(usize, @intCast(n))], staging[0..@intCast(n)]);
        total += @intCast(n);
    }
    if (total == file_max and ui.file_read(handle, staging[0..1]) > 0) {
        st.err = .too_large;
        ui.write_console("doc: error too-large\n");
        return;
    }
    st.file_len = total;

    doc = html_parse.parse(file_bytes[0..total], nodes[0..], text_buf[0..]);
    st.parse_nodes = doc.node_count;
    st.truncated = doc.truncated;

    var pbuf: [80]u8 = undefined;
    const pline = std.fmt.bufPrint(&pbuf, "doc: parse nodes={d} text={d} truncated={d}\n", .{
        doc.node_count, doc.text_len, @intFromBool(doc.truncated),
    }) catch "doc: parse\n";
    ui.write_console(pline);

    const content_w = if (st.win_w > 0) st.win_w else window_w;
    lay = html_layout.layout(doc, content_w, blocks[0..], lines[0..], spans[0..], guestMeasure);
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

    st.loaded = true;
    st.err = .none;
}

fn captureProbes() void {
    var i: u16 = 0;
    while (i < lay.block_count) : (i += 1) {
        const b = lay.blocks[i];
        if (st.probe_h1 == 0 and b.tag == .h1) st.probe_h1 = b.y;
        if (st.probe_quote == 0 and b.quote_bar) st.probe_quote = b.y;
        if (st.probe_pre == 0 and b.tag == .pre) st.probe_pre = b.y;
        if (st.probe_hr == 0 and b.kind == .hr) st.probe_hr = b.y;
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
        .none => "no document",
    };
    ui.draw_text_sized(win, msg, cr.x + 12, cr.y + 12, 14, ui.theme_danger());
    if (st.name_len > 0) {
        ui.draw_text_mono(win, st.name_buf[0..st.name_len], cr.x + 12, cr.y + 32, ui.theme_text_muted());
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
                if (sp.flags.mono) {
                    if (sp.text_len > 0) {
                        ui.draw_rect(win, Rect.make(sx, y, sp.w, line.h), surface);
                    }
                    ui.draw_text_mono(win, slice, sx, y, color);
                } else {
                    ui.draw_text_sized(win, slice, sx, y, sp.size, color);
                    if (sp.flags.bold) {
                        ui.draw_text_sized(win, slice, sx + 1, y, sp.size, color);
                    }
                }
            }
        }
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
    var buf: [64]u8 = undefined;
    const name = if (st.name_len > 0) basename(st.name_buf[0..st.name_len]) else "DOC";
    const line = std.fmt.bufPrint(&buf, "{s}  {d}/{d}", .{
        name, st.scroll, maxScroll(),
    }) catch "DOC";
    ui.draw_text_sized(win, line, 8, y + 2, 11, ui.theme_text_muted());
}

fn relayout() void {
    if (!st.loaded) return;
    lay = html_layout.layout(doc, st.win_w, blocks[0..], lines[0..], spans[0..], guestMeasure);
    st.layout_blocks = lay.block_count;
    st.layout_lines = lay.line_count;
    st.content_h = lay.content_h;
    captureProbes();
    clampScroll();
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
        st.err = .missing;
        ui.write_console("doc: error missing\n");
    } else {
        load(path_buf[0..path_len]);
    }

    draw(st.win);
    ta.present();
    ui.sleep_ticks(2);
    ui.write_console("doc: settled\n");

    var ev: Event = undefined;
    while (true) {
        if (ui.wait_event(&ev) < 0) break;
        var dirty = false;
        switch (ta.dispatch(&ev)) {
            .closed => {
                ui.write_console("doc: win_close\n");
                ta.close_and_exit(exit_status);
            },
            .resized => {
                st.win_w = ta.w;
                st.win_h = ta.h;
                relayout();
                dirty = true;
            },
            .none => {
                if (ev.kind == ui.KEY_DOWN) {
                    handleKey(ev.arg0, &dirty);
                }
            },
        }
        while (ui.poll_event(&ev) > 0) {
            switch (ta.dispatch(&ev)) {
                .closed => {
                    ui.write_console("doc: win_close\n");
                    ta.close_and_exit(exit_status);
                },
                .resized => {
                    st.win_w = ta.w;
                    st.win_h = ta.h;
                    relayout();
                    dirty = true;
                },
                .none => {
                    if (ev.kind == ui.KEY_DOWN) handleKey(ev.arg0, &dirty);
                },
            }
        }
        if (dirty) {
            draw(st.win);
            ta.present();
        }
    }
    ui.write_console("doc: exiting 43\n");
    ta.close_and_exit(exit_status);
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
