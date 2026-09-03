//! VirelaiOS VIEW.BIN — the M36 IMG5 raster image viewer (issue #826, claim 4574).
//!
//! A userland image viewer over the M36 raster engine (IMG1 `image.zig`,
//! IMG4 toolkit blits): `exec VIEW.BIN <path>` loads a QOI or PNG from the
//! host share (magic-dispatched to lib/qoi.zig or lib/png.zig — see the
//! import note), opens a window sized to the image aspect ratio (clamped to
//! the kernel user back-buffer bounds), and provides pan & zoom:
//!
//!   - Keyboard: `+`/`=` zoom in, `-` zoom out, `0` resets 100%, arrow keys
//!     pan when zoomed, `q`/Esc quits.
//!   - Mouse: scroll wheel zooms, click-and-drag pans when zoomed.
//!
//! The window title bar (sys_win_set_title, slot 61) carries filename,
//! dimensions, format tag, and zoom level. No arguments opens a clean empty
//! state. Zero heap: the file bytes and the decoded pixel buffer live in
//! anonymous mmap regions (M29 slot 63, MAP_POPULATE), state is a plain BSS
//! struct. Honest degradation everywhere: decode failures and missing files
//! render an on-screen error and keep the window open; nothing panics.

const std = @import("std");
const ui = @import("lib/ui.zig");
// Decode dispatch is by MAGIC (not extension): QOI via lib/qoi.zig, PNG via
// lib/png.zig's stream-chunked workspace path (claim 7317) — `png.scan`
// sizes exact IDAT + scanline workspaces from the file, and the viewer
// backs them with M29 anonymous mmap regions. png.zig carries no giant
// static staging (its original 128 KiB IDAT + 256 KiB decompression BSS
// pushed this binary's DSK3 data_mem segment past the kernel's 256 KiB
// exec cap — observed live), so this app's static data stays ~KiB-scale:
// only the two 4 KiB PNG row buffers plus the QOI/file/pixel mmap
// bookkeeping.
const qoi = @import("lib/qoi.zig");
const png = @import("lib/png.zig");

const Event = ui.Event;
const Rect = ui.Rect;

// ---------------------------------------------------------------------------
// Window & viewport geometry (kernel caps: user_buf 512x424, 16 px title band)
// ---------------------------------------------------------------------------

pub const window_x: u32 = 44;
pub const window_y: u32 = 28;
/// Largest window this app will open (leaves headroom under the caps).
pub const win_max_w: u32 = 500;
pub const win_max_h: u32 = 408;
pub const win_min_w: u32 = 96;
pub const win_min_h: u32 = 72;
/// The compositor paints its 16 px title band over the window's top rows;
/// content starts below it.
pub const title_band_h: u32 = 16;
/// Status bar height at the bottom of the viewport.
pub const status_h: u32 = 12;

pub const exit_status: u32 = 43;

/// Frozen syscall slots used directly (no toolkit wrapper yet for these).
pub const sys_win_set_title_num: u64 = 61; // sys_win_set_title(id, ptr, len)
pub const sys_win_resize_num: u64 = 47; // sys_win_resize(id, w, h)

/// Largest decoded pixel extent (512 KiB = 131072 px, e.g. 512x256).
pub const pixels_max: usize = 131072;

/// M29 anonymous mmap (slot 63): the file bytes and decoded pixels live in
/// eager-populated anonymous regions instead of megabyte BSS arrays. Same
/// flag shape vmtest.zig proves live (ANON|PRIVATE, POPULATE for eager).
pub const map_flags: u64 = ui.MAP_ANONYMOUS | ui.MAP_PRIVATE | ui.MAP_POPULATE;
pub const prot_rw: u64 = ui.PROT_READ | ui.PROT_WRITE;

/// Largest image file this viewer loads (the mmap region size).
pub const file_max: usize = 512 * 1024;

// ---------------------------------------------------------------------------
// Zoom table & key map
// ---------------------------------------------------------------------------

/// Discrete zoom percentages (index 4 == 100%).
pub const zoom_table = [_]u32{ 25, 33, 50, 66, 100, 150, 200, 300, 400, 600, 800 };
pub const zoom_default_idx: usize = 4;

/// HID usages (kernel key events carry the usage in arg0) — arrows per
/// notepad/calc/file_browser convention; `=`/`-`/`0` per the HID keyboard
/// usage table (0x2E is the physical `=+` key — the issue's "+" — 0x2D `-`,
/// 0x27 `0`).
pub const key_zoom_in: u32 = 0x2E; // `=` / `+`
pub const key_zoom_out: u32 = 0x2D; // `-`
pub const key_reset: u32 = 0x27; // `0`
pub const key_left: u32 = 0x50;
pub const key_right: u32 = 0x4F;
pub const key_up: u32 = 0x52;
pub const key_down: u32 = 0x51;
pub const key_quit_q: u32 = 0x14; // `q`
pub const key_escape: u32 = 0x29;

// ---------------------------------------------------------------------------
// Pure logic (host-tested)
// ---------------------------------------------------------------------------

pub const Format = enum {
    qoi,
    png,
    unknown,

    pub fn tag(self: Format) []const u8 {
        return switch (self) {
            .qoi => "QOI",
            .png => "PNG",
            .unknown => "???",
        };
    }
};

/// Format tag from the file extension (display only — decode() sniffs magic).
pub fn format_from_path(path: []const u8) Format {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return .unknown;
    const ext = path[dot + 1 ..];
    if (eql_ci(ext, "qoi")) return .qoi;
    if (eql_ci(ext, "png")) return .png;
    return .unknown;
}

/// Everything after the last `/` (or the whole path).
pub fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn eql_ci(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

pub const WinSize = struct { w: u32, h: u32 };

/// Window size for an image: the content area (window minus 8 px side
/// padding and 24 px top+bottom chrome) preserves the image aspect ratio,
/// clamped to [win_min, win_max]. Pure, integer-only.
pub fn choose_window_size(iw: u32, ih: u32) WinSize {
    if (iw == 0 or ih == 0) return .{ .w = 240, .h = 160 };
    const pad_w: u32 = 8;
    const pad_h: u32 = 24; // 16 px title band + 8 px breathing room
    const cap_w = win_max_w - pad_w;
    const cap_h = win_max_h - pad_h;
    // Fit the image into the cap box preserving aspect.
    var cw: u32 = cap_w;
    var ch: u32 = (cap_w * ih) / iw;
    if (ch > cap_h) {
        ch = cap_h;
        cw = (cap_h * iw) / ih;
    }
    // Never upscale past 2x for tiny images.
    if (cw > iw * 2) {
        ch = (ch * iw * 2) / cw;
        cw = iw * 2;
    }
    if (ch > ih * 2) ch = ih * 2;
    // Never below the minimum window.
    if (cw < win_min_w - pad_w) cw = win_min_w - pad_w;
    if (ch < win_min_h - pad_h) ch = win_min_h - pad_h;
    return .{ .w = cw + pad_w, .h = ch + pad_h };
}

pub const Viewport = struct { x: u32, y: u32, w: u32, h: u32 };

/// The viewport rect inside the window: everything between the title band
/// and the status bar.
pub fn viewport_rect(win_w: u32, win_h: u32) Viewport {
    const h = win_h - title_band_h - status_h;
    return .{ .x = 0, .y = title_band_h, .w = win_w, .h = h };
}

/// Displayed (scaled) image size at zoom `z`.
pub fn displayed_size(iw: u32, ih: u32, z: u32) WinSize {
    const dw = @max(1, (iw * z) / 100);
    const dh = @max(1, (ih * z) / 100);
    return .{ .w = dw, .h = dh };
}

/// Where the displayed image sits inside the viewport (top-left), and the
/// on-screen extent (clipped by the viewport).
pub const DestLayout = struct { x: u32, y: u32, w: u32, h: u32 };

pub fn dest_layout(vp: Viewport, dw: u32, dh: u32) DestLayout {
    const x: u32 = if (dw >= vp.w) 0 else (vp.w - dw) / 2;
    const y: u32 = if (dh >= vp.h) 0 else (vp.h - dh) / 2;
    const w = @min(dw, vp.w - @min(vp.w, x));
    const h = @min(dh, vp.h - @min(vp.h, y));
    return .{ .x = vp.x + x, .y = vp.y + y, .w = w, .h = h };
}

/// Pan clamp: the top-left visible image pixel for a displayed size.
/// When the whole image fits, only 0 is legal (and the layout centers it).
pub fn clamp_origin(origin: u32, img_len: u32, disp_len: u32, vp_len: u32) u32 {
    if (disp_len <= vp_len or disp_len == 0) return 0;
    // Image pixels spanned by the viewport at this zoom.
    const span = @max(1, (vp_len * img_len) / disp_len);
    const max_o = img_len - @min(img_len, span);
    return @min(origin, max_o);
}

pub const ZoomStep = enum { in, out, reset };

/// Zoom-table step with clamping (returns the new index).
pub fn step_zoom(idx: usize, dir: ZoomStep) usize {
    return switch (dir) {
        .in => @min(idx + 1, zoom_table.len - 1),
        .out => idx - @min(idx, 1),
        .reset => zoom_default_idx,
    };
}

/// A scroll event's packed arg0 (ADR 0013 D2): bits 0-13 magnitude, bit 14
/// horizontal, bit 15 sign. Returns null when the wheel says nothing usable.
pub const ScrollDir = enum { up, down };

pub fn scroll_dir(arg0: u32) ?ScrollDir {
    if ((arg0 & 0x4000) != 0) return null; // horizontal wheel: not zoom
    const magnitude = arg0 & 0x1FFF;
    if (magnitude == 0) return null;
    return if ((arg0 & 0x8000) != 0) .down else .up;
}

/// Compose the window title: `view: <name> <w>x<h> <FMT> <z>%` (<= 64 bytes,
/// the slot-61 contract). Returns the composed slice; empty when it cannot
/// fit (the caller keeps the previous title).
pub fn compose_title(buf: []u8, name: []const u8, iw: u32, ih: u32, fmt: Format, z: u32) []const u8 {
    return std.fmt.bufPrint(buf, "view: {s} {d}x{d} {s} {d}%", .{
        name, iw, ih, fmt.tag(), z,
    }) catch buf[0..0];
}

// ---------------------------------------------------------------------------
// Runtime state (plain BSS, zero heap)
// ---------------------------------------------------------------------------

const LoadError = enum {
    none,
    too_large,
    open_failed,
    read_failed,
    decode_failed,
};

const State = struct {
    win_id: u32 = 0,
    win_w: u32 = 0,
    win_h: u32 = 0,
    loaded: bool = false,
    errored: bool = false,
    err: LoadError = .none,
    fmt: Format = .unknown,
    img_w: u32 = 0,
    img_h: u32 = 0,
    zoom_idx: usize = zoom_default_idx,
    ox: u32 = 0, // image px at the viewport's left edge
    oy: u32 = 0, // image px at the viewport's top edge
    drag_active: bool = false,
    drag_x: i32 = 0,
    drag_y: i32 = 0,
    drag_ox: u32 = 0,
    drag_oy: u32 = 0,
    name_buf: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,

    fn name(self: *const State) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn zoom(self: *const State) u32 {
        return zoom_table[self.zoom_idx];
    }
};

var st: State = .{};
/// mmap'd storage (va captured at _start; empty until then).
var file_bytes: []u8 = &.{};
var pixel_buf: []align(1) u32 = &.{};

// PNG stream-chunked workspace (claim 7317): the IDAT staging and the
// decompressed-scanline buffers are mmap'd at the exact sizes `png.scan`
// reports (a PNG is decoded once per exec, so a single map each suffices);
// only the per-row filter buffers are static (4 KiB each, max row width).
var png_idat: []u8 = &.{};
var png_decomp: []u8 = &.{};
var png_prev_row: [png.MAX_ROW_BYTES]u8 = [_]u8{0} ** png.MAX_ROW_BYTES;
var png_cur_row: [png.MAX_ROW_BYTES]u8 = [_]u8{0} ** png.MAX_ROW_BYTES;

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// Nearest-neighbor crop+scale blit of the visible image region into the
/// window via the toolkit's batched fills (the IMG4 seam: win_fill_batched
/// under the hood; one span-fill per same-color run). Transparent pixels are
/// skipped so the checkered backdrop shows through.
fn blit_view(win: u32, vp: Viewport) void {
    if (!st.loaded or st.img_w == 0 or st.img_h == 0) return;
    const z = st.zoom();
    const disp = displayed_size(st.img_w, st.img_h, z);
    const dest = dest_layout(vp, disp.w, disp.h);
    if (dest.w == 0 or dest.h == 0) return;

    var dy: u32 = 0;
    while (dy < dest.h) : (dy += 1) {
        const sy = st.oy + (dy * st.img_h) / disp.h;
        if (sy >= st.img_h) break;
        var dx: u32 = 0;
        while (dx < dest.w) {
            const sx = st.ox + (dx * st.img_w) / disp.w;
            if (sx >= st.img_w) break;
            const idx = @as(usize, sy) * st.img_w + sx;
            if (idx >= pixel_buf.len) break;
            const px = pixel_buf[idx];
            const a = (px >> 24) & 0xFF;
            if (a == 0) {
                dx += 1;
                continue;
            }
            const rgb = px & 0x00FFFFFF;
            const run_start = dx;
            dx += 1;
            // Extend the run while sampling stays on the same RGB.
            while (dx < dest.w) {
                const sx2 = st.ox + (dx * st.img_w) / disp.w;
                if (sx2 >= st.img_w) break;
                const idx2 = @as(usize, sy) * st.img_w + sx2;
                if (idx2 >= pixel_buf.len) break;
                const px2 = pixel_buf[idx2];
                if (((px2 >> 24) & 0xFF) == 0 or (px2 & 0x00FFFFFF) != rgb) break;
                dx += 1;
            }
            ui.win_fill_batched(win, dest.x + run_start, dest.y + dy, dx - run_start, 1, rgb);
        }
    }
}

/// The checkerboard backdrop (transparent image pixels show it through).
fn draw_backdrop(win: u32, vp: Viewport) void {
    const c_a = 0x2a2a2a;
    const c_b = 0x3a3a3a;
    const cell: u32 = 8;
    var cy: u32 = 0;
    while (cy < vp.h) : (cy += cell) {
        var cx: u32 = 0;
        while (cx < vp.w) : (cx += cell) {
            const w = @min(cell, vp.w - cx);
            const h = @min(cell, vp.h - cy);
            const even = ((cx / cell) + (cy / cell)) % 2 == 0;
            ui.win_fill_batched(win, vp.x + cx, vp.y + cy, w, h, if (even) c_a else c_b);
        }
    }
}

fn draw_status(win: u32, vp: Viewport) void {
    const bar_y = vp.y + vp.h;
    ui.win_fill_batched(win, 0, bar_y, st.win_w, status_h, ui.theme_surface());
    var buf: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}%  +/- zoom  0 reset  arrows/drag pan", .{st.zoom()}) catch "";
    ui.flush_fills();
    ui.draw_text(win, text, 4, bar_y + 2, ui.theme_text_muted());
}

fn draw_empty(win: u32, vp: Viewport) void {
    ui.draw_text_centered_large(win, "VIEW.BIN", Rect.make(vp.x, vp.y + vp.h / 4, vp.w, 24), ui.theme_text_primary());
    ui.draw_text_centered(win, "no image loaded", Rect.make(vp.x, vp.y + vp.h / 2, vp.w, 12), ui.theme_text_muted());
    ui.draw_text_centered(win, "exec VIEW.BIN /host/FILE.QOI", Rect.make(vp.x, vp.y + vp.h / 2 + 20, vp.w, 12), ui.theme_text_muted());
}

fn err_text(err: LoadError) []const u8 {
    return switch (err) {
        .none => "",
        .too_large => "file too large",
        .open_failed => "open failed",
        .read_failed => "read failed",
        .decode_failed => "decode failed",
    };
}

fn draw_error(win: u32, vp: Viewport) void {
    ui.draw_text_centered_large(win, "cannot open", Rect.make(vp.x, vp.y + vp.h / 4, vp.w, 24), ui.theme_danger());
    ui.draw_text_centered(win, err_text(st.err), Rect.make(vp.x, vp.y + vp.h / 2, vp.w, 12), ui.theme_text_muted());
    ui.draw_text_centered(win, st.name(), Rect.make(vp.x, vp.y + vp.h / 2 + 20, vp.w, 12), ui.theme_text_primary());
}

fn draw(win: u32) void {
    const vp = viewport_rect(st.win_w, st.win_h);
    draw_backdrop(win, vp);
    if (st.loaded) {
        blit_view(win, vp);
    } else if (st.errored) {
        draw_error(win, vp);
    } else {
        draw_empty(win, vp);
    }
    draw_status(win, vp);
    ui.flush_fills();
}

/// One-time live marker: the first title push (name + dims + format + zoom)
/// landed on the compositor. Zoom changes re-push silently after that.
var title_announced: bool = false;

/// Push the title bar (filename, dims, format, zoom) to the compositor.
fn push_title() void {
    var buf: [64]u8 = undefined;
    const t = if (st.name_len > 0)
        compose_title(&buf, st.name(), st.img_w, st.img_h, st.fmt, st.zoom())
    else
        compose_title(&buf, "(no image)", 0, 0, .unknown, st.zoom());
    if (t.len == 0) return;
    _ = ui.syscall3(sys_win_set_title_num, st.win_id, @intFromPtr(t.ptr), t.len);
    if (!title_announced) {
        title_announced = true;
        ui.write_console("view: title set\n");
    }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

fn recenter_clamp() void {
    const vp = viewport_rect(st.win_w, st.win_h);
    const disp = displayed_size(st.img_w, st.img_h, st.zoom());
    st.ox = clamp_origin(st.ox, st.img_w, disp.w, vp.w);
    st.oy = clamp_origin(st.oy, st.img_h, disp.h, vp.h);
}

fn apply_zoom(idx: usize, announce: bool) void {
    if (idx == st.zoom_idx) return;
    st.zoom_idx = idx;
    recenter_clamp();
    if (announce) {
        var buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "view: zoom z={d}%\n", .{st.zoom()}) catch return;
        ui.write_console(line);
    }
    push_title();
    draw(st.win_id);
    ui.win_present(st.win_id);
}

fn pan_max(img_len: u32, disp_len: u32, vp_len: u32) u32 {
    if (disp_len <= vp_len or disp_len == 0) return 0;
    const span = @max(1, (vp_len * img_len) / disp_len);
    return img_len - @min(img_len, span);
}

fn apply_delta(cur: u32, delta: i32, max: u32) u32 {
    const cur_i: i32 = @intCast(cur);
    var next = cur_i + delta;
    if (next < 0) next = 0;
    const max_i: i32 = @intCast(max);
    if (next > max_i) next = max_i;
    return @intCast(next);
}

fn announce_pan() void {
    var buf: [40]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "view: pan ox={d} oy={d}\n", .{ st.ox, st.oy }) catch return;
    ui.write_console(line);
}

fn pan_by(ddx: i32, ddy: i32) void {
    const vp = viewport_rect(st.win_w, st.win_h);
    const disp = displayed_size(st.img_w, st.img_h, st.zoom());
    // Display-px step -> image-px step at the current zoom (1/8 viewport).
    const sx: i32 = @max(1, @divTrunc(@divTrunc(@as(i32, @intCast(vp.w)) * 100, @as(i32, @intCast(@max(1, disp.w)))), 8));
    const sy: i32 = @max(1, @divTrunc(@divTrunc(@as(i32, @intCast(vp.h)) * 100, @as(i32, @intCast(@max(1, disp.h)))), 8));
    const nx = apply_delta(st.ox, ddx * sx, pan_max(st.img_w, disp.w, vp.w));
    const ny = apply_delta(st.oy, ddy * sy, pan_max(st.img_h, disp.h, vp.h));
    if (nx == st.ox and ny == st.oy) return;
    st.ox = nx;
    st.oy = ny;
    announce_pan();
    draw(st.win_id);
    ui.win_present(st.win_id);
}

fn drag_pan(cur_x: i32, cur_y: i32) void {
    const vp = viewport_rect(st.win_w, st.win_h);
    const disp = displayed_size(st.img_w, st.img_h, st.zoom());
    // Display px dragged -> image px panned (inverted: drag the image).
    const ddx = @divTrunc((cur_x - st.drag_x) * 100, @as(i32, @intCast(@max(1, disp.w))));
    const ddy = @divTrunc((cur_y - st.drag_y) * 100, @as(i32, @intCast(@max(1, disp.h))));
    const nx = apply_delta(st.drag_ox, -ddx, pan_max(st.img_w, disp.w, vp.w));
    const ny = apply_delta(st.drag_oy, -ddy, pan_max(st.img_h, disp.h, vp.h));
    if (nx == st.ox and ny == st.oy) return;
    st.ox = nx;
    st.oy = ny;
    announce_pan();
    draw(st.win_id);
    ui.win_present(st.win_id);
}

fn zoom_scroll(dir: ScrollDir) void {
    const idx = switch (dir) {
        .up => step_zoom(st.zoom_idx, .in),
        .down => step_zoom(st.zoom_idx, .out),
    };
    apply_zoom(idx, true);
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

fn load(path: []const u8) void {
    // Path length bound: argv slots are 32 bytes.
    if (path.len == 0 or path.len > 32) {
        st.errored = true;
        st.err = .open_failed;
        return;
    }
    @memcpy(st.name_buf[0..path.len], path);
    st.name_len = path.len;
    st.fmt = format_from_path(path);

    const fd = ui.file_open(path, ui.MODE_READ);
    if (fd < 0) {
        st.errored = true;
        st.err = .open_failed;
        ui.write_console("view: open err\n");
        return;
    }
    const handle: u32 = @intCast(fd);
    defer ui.file_close(handle);

    // sys_file_read copy_out validates against the apertures armed at SVC
    // entry (text/stack + the exec-armed data segment); M29 anonymous mmap
    // regions are NOT armed there (observed live: `view: read err` when
    // reading straight into the mmap'd file_bytes). The kernel caps each
    // read at 2048 bytes anyway, so stage each chunk on the stack (an armed
    // region) and @memcpy it into the mmap'd buffer — plain userland
    // stores, no syscall boundary crossed.
    var total: usize = 0;
    var read_staging: [2048]u8 = undefined;
    while (total < file_max) {
        const n = ui.file_read(handle, read_staging[0..read_staging.len]);
        if (n < 0) {
            st.errored = true;
            st.err = .read_failed;
            ui.write_console("view: read err\n");
            return;
        }
        if (n == 0) break;
        @memcpy(file_bytes[total .. total + @as(usize, @intCast(n))], read_staging[0..@intCast(n)]);
        total += @intCast(n);
    }
    if (total == file_max and ui.file_read(handle, read_staging[0..1]) > 0) {
        st.errored = true;
        st.err = .too_large;
        ui.write_console("view: too large\n");
        return;
    }

    const dims = decode_file(file_bytes[0..total]) orelse return;
    st.loaded = true;
    st.errored = false;
    st.img_w = dims.width;
    st.img_h = dims.height;

    var buf: [80]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "view: loaded {s} {d}x{d} {s} bytes={d}\n", .{
        basename(path), dims.width, dims.height, st.fmt.tag(), total,
    }) catch "view: loaded\n";
    ui.write_console(line);
}

const ImageDims = struct { width: u32, height: u32 };

fn decode_failed() void {
    st.errored = true;
    st.err = .decode_failed;
    ui.write_console("view: decode err\n");
}

fn decode_too_large() void {
    st.errored = true;
    st.err = .too_large;
    ui.write_console("view: too large\n");
}

/// Decode by sniffed magic: `qoif` -> QOI, the PNG signature -> the png.zig
/// workspace path. Sets `st.fmt` from the magic (the marker/title show the
/// real container, not the extension). On failure the error state is set and
/// printed and null is returned.
fn decode_file(bytes: []const u8) ?ImageDims {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "qoif")) {
        st.fmt = .qoi;
        const hdr = qoi.decode(bytes, pixel_buf) catch {
            decode_failed();
            return null;
        };
        return .{ .width = hdr.width, .height = hdr.height };
    }
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) {
        st.fmt = .png;
        return decode_png(bytes);
    }
    decode_failed();
    return null;
}

/// PNG decode through png.zig's workspace path: scan for exact sizes, map
/// the IDAT + scanline workspaces, decode straight into the mmap'd pixel
/// buffer. Row buffers are the static 4 KiB pair; wider images error
/// honestly (MAX_ROW_BYTES).
fn decode_png(bytes: []const u8) ?ImageDims {
    const info = png.scan(bytes) catch {
        decode_failed();
        return null;
    };
    const total_px = @as(usize, info.width) * info.height;
    if (total_px == 0 or total_px > pixels_max) {
        decode_too_large();
        return null;
    }
    const row_bytes = info.row_bytes();
    if (row_bytes == 0 or row_bytes > png.MAX_ROW_BYTES) {
        decode_failed();
        return null;
    }
    // The pixel-extent check above bounds decomp_total (<= px*4 + h), so
    // these maps are small. Map once per exec (a PNG decodes once here).
    if (png_idat.len == 0 and info.idat_total > 0) png_idat = map_region(info.idat_total);
    if (png_decomp.len == 0 and info.decomp_total > 0) png_decomp = map_region(info.decomp_total);
    if (png_idat.len < info.idat_total or png_decomp.len < info.decomp_total) {
        decode_failed();
        return null;
    }

    const hdr = png.decode_with_buffers(
        bytes,
        pixel_buf,
        png_idat[0..info.idat_total],
        png_decomp[0..info.decomp_total],
        &png_prev_row,
        &png_cur_row,
    ) catch {
        decode_failed();
        return null;
    };
    return .{ .width = hdr.width, .height = hdr.height };
}

// ---------------------------------------------------------------------------
// Header sniff (window sizing before the full load)
// ---------------------------------------------------------------------------

var header_bytes: [24]u8 = [_]u8{0} ** 24;
var header_have: usize = 0;
var header_path: [32]u8 = [_]u8{0} ** 32;
var header_path_len: usize = 0;

/// Peek the first 24 bytes of the named file (QOI 14-byte header, PNG IHDR).
fn load_header_only() void {
    header_have = 0;
    if (header_path_len == 0) return;
    const fd = ui.file_open(header_path[0..header_path_len], ui.MODE_READ);
    if (fd < 0) return;
    const handle: u32 = @intCast(fd);
    defer ui.file_close(handle);
    const n = ui.file_read(handle, &header_bytes);
    if (n <= 0) return;
    header_have = @intCast(n);
}

/// Window size from whatever header bytes we sniffed, or the default.
fn header_size_or_default() WinSize {
    if (header_have >= 24) {
        if (std.mem.eql(u8, header_bytes[0..4], "qoif")) {
            const iw = std.mem.readInt(u32, header_bytes[4..8], .big);
            const ih = std.mem.readInt(u32, header_bytes[8..12], .big);
            if (iw > 0 and ih > 0) return choose_window_size(iw, ih);
        }
        if (std.mem.eql(u8, header_bytes[0..8], "\x89PNG\r\n\x1a\n") and std.mem.eql(u8, header_bytes[12..16], "IHDR")) {
            const iw = std.mem.readInt(u32, header_bytes[16..20], .big);
            const ih = std.mem.readInt(u32, header_bytes[20..24], .big);
            if (iw > 0 and ih > 0) return choose_window_size(iw, ih);
        }
    }
    return .{ .w = 320, .h = 240 };
}

// ---------------------------------------------------------------------------
// mmap plumbing (M29 slot 63)
// ---------------------------------------------------------------------------

fn map_region(len: usize) []u8 {
    const va = ui.mmap(0, len, prot_rw, map_flags);
    if (va == 0 or va > std.math.maxInt(usize)) {
        // Honest degradation: an empty slice makes every later step report an
        // error instead of panicking.
        ui.write_console("view: mmap file region failed\n");
        return &.{};
    }
    return @as([*]u8, @ptrFromInt(@as(usize, @intCast(va))))[0..len];
}

fn map_pixels(len: usize) []align(1) u32 {
    const bytes = map_region(len * 4);
    if (bytes.len == 0) return &.{};
    return @as([*]align(1) u32, @ptrCast(bytes.ptr))[0..len];
}

// ---------------------------------------------------------------------------
// Entry & event loop
// ---------------------------------------------------------------------------

pub export fn _start(argc: usize, argv: ?[*]const [32]u8) callconv(.c) noreturn {
    // M29 anonymous mmap for the two big buffers (zero BSS cost).
    file_bytes = map_region(file_max);
    pixel_buf = map_pixels(pixels_max);

    // Claim 4636 entry contract: argc in x0, argv block VA in x1; each slot a
    // 32-byte NUL-padded string. Shell `exec VIEW.BIN <path>` passes the path
    // as argv[0] (no program-name slot). No args -> clean empty state.
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

    if (path_len == 0) {
        ui.write_console("view: empty (no args)\n");
    } else {
        @memcpy(header_path[0..path_len], path_buf[0..path_len]);
        header_path_len = path_len;
        load_header_only();
    }

    // Open the window sized from the sniffed header (default size otherwise).
    const win_size = header_size_or_default();
    const win_res = ui.win_open(window_x, window_y, win_size.w, win_size.h);
    if (win_res < 0) {
        ui.write_console("view: failed to open window\n");
        ui.exit_process(1);
    }
    st.win_id = @intCast(win_res);
    st.win_w = win_size.w;
    st.win_h = win_size.h;
    var obuf: [40]u8 = undefined;
    const oline = std.fmt.bufPrint(&obuf, "view: open id={d} {d}x{d}\n", .{ st.win_id, st.win_w, st.win_h }) catch "view: open\n";
    ui.write_console(oline);

    if (path_len > 0) {
        load(path_buf[0..path_len]);
        if (st.loaded) {
            // Re-fit the window to the decoded image if the header sniff
            // disagreed (defensive; normally identical).
            const want = choose_window_size(st.img_w, st.img_h);
            if (want.w != st.win_w or want.h != st.win_h) {
                st.win_w = want.w;
                st.win_h = want.h;
                _ = ui.syscall3(sys_win_resize_num, st.win_id, want.w, want.h);
            }
        }
    }

    push_title();
    draw(st.win_id);
    ui.win_present(st.win_id);
    ui.write_console("view: ready\n");

    event_loop();

    ui.write_console("view: exiting 43\n");
    ui.win_close(st.win_id);
    ui.exit_process(exit_status);
}

fn event_loop() void {
    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) return;
        var dirty = false;
        handle_event(&ev, &dirty);
        while (ui.poll_event(&ev) > 0) {
            handle_event(&ev, &dirty);
        }
        // Interaction handlers announce + present themselves; `dirty` exists
        // for future coalesced-draw refactors.
        _ = &dirty;
    }
}

fn handle_event(ev: *const Event, dirty: *bool) void {
    switch (ev.kind) {
        ui.WIN_CLOSE => {
            ui.write_console("view: win_close\n");
            ui.win_close(st.win_id);
            ui.exit_process(exit_status);
        },
        ui.KEY_DOWN => handle_key(ev.arg0, ev.arg1, dirty),
        ui.MOUSE_SCROLL => {
            if (st.loaded) {
                if (scroll_dir(ev.arg0)) |dir| zoom_scroll(dir);
            }
        },
        ui.MOUSE_DOWN => {
            if (st.loaded and (ev.flags & ui.BTN_LEFT) != 0) {
                const vp = viewport_rect(st.win_w, st.win_h);
                if (ev.arg0 >= vp.x and ev.arg0 < vp.x + vp.w and ev.arg1 >= vp.y and ev.arg1 < vp.y + vp.h) {
                    st.drag_active = true;
                    st.drag_x = @intCast(ev.arg0);
                    st.drag_y = @intCast(ev.arg1);
                    st.drag_ox = st.ox;
                    st.drag_oy = st.oy;
                }
            }
        },
        ui.MOUSE_UP => {
            st.drag_active = false;
        },
        ui.MOUSE_MOVE => {
            if (st.drag_active and st.loaded) {
                drag_pan(@intCast(ev.arg0), @intCast(ev.arg1));
            }
        },
        else => {},
    }
}

fn handle_key(usage: u32, ascii: u32, dirty: *bool) void {
    // Quit keys work in every state.
    if (usage == key_quit_q or usage == key_escape) {
        ui.write_console("view: quit\n");
        ui.win_close(st.win_id);
        ui.exit_process(exit_status);
    }
    if (usage == key_zoom_in or ascii == '+' or ascii == '=') {
        if (st.loaded) {
            apply_zoom(step_zoom(st.zoom_idx, .in), true);
            dirty.* = true;
        }
        return;
    }
    if (usage == key_zoom_out or ascii == '-') {
        if (st.loaded) {
            apply_zoom(step_zoom(st.zoom_idx, .out), true);
            dirty.* = true;
        }
        return;
    }
    if (usage == key_reset or ascii == '0') {
        if (st.loaded) {
            apply_zoom(step_zoom(st.zoom_idx, .reset), true);
            dirty.* = true;
        }
        return;
    }
    if (!st.loaded) return;
    switch (usage) {
        key_left => {
            pan_by(-1, 0);
            dirty.* = true;
        },
        key_right => {
            pan_by(1, 0);
            dirty.* = true;
        },
        key_up => {
            pan_by(0, -1);
            dirty.* = true;
        },
        key_down => {
            pan_by(0, 1);
            dirty.* = true;
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Host Unit Tests (Class A)
// ---------------------------------------------------------------------------

test "view: format tag from extension (case-insensitive)" {
    try std.testing.expectEqual(Format.qoi, format_from_path("/host/PHOTO.QOI"));
    try std.testing.expectEqual(Format.qoi, format_from_path("/host/photo.qoi"));
    try std.testing.expectEqual(Format.png, format_from_path("/host/shot.PNG"));
    try std.testing.expectEqual(Format.unknown, format_from_path("/host/READ.ME"));
    try std.testing.expectEqual(Format.unknown, format_from_path("/host/noext"));
}

test "view: basename" {
    try std.testing.expectEqualStrings("TEST.QOI", basename("/host/TEST.QOI"));
    try std.testing.expectEqualStrings("plain.qoi", basename("plain.qoi"));
    try std.testing.expectEqualStrings("b", basename("/a/b"));
}

test "view: window size preserves aspect and clamps to the kernel caps" {
    // Fits under the caps with <= 2x upscale: the content area grows to fill
    // the cap box (aspect preserved), padded by 8/24.
    const a = choose_window_size(320, 200);
    try std.testing.expectEqual(@as(u32, 492), a.w - 8);
    try std.testing.expectEqual(@as(u32, 307), a.h - 24);
    const ratio_a = @as(f64, @floatFromInt(a.w - 8)) / @as(f64, @floatFromInt(a.h - 24));
    try std.testing.expectApproxEqAbs(@as(f64, 1.6), ratio_a, 0.01);
    // Wide image clamps to the cap width, height follows the ratio.
    const wide = choose_window_size(4096, 1024);
    try std.testing.expect(wide.w <= win_max_w);
    try std.testing.expect(wide.h <= win_max_h);
    const ratio_wide = @as(f64, @floatFromInt(wide.w - 8)) / @as(f64, @floatFromInt(wide.h - 24));
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), ratio_wide, 0.05);
    // Tall image clamps to the cap height.
    const tall = choose_window_size(1024, 4096);
    try std.testing.expect(tall.w <= win_max_w);
    try std.testing.expect(tall.h <= win_max_h);
    const ratio_tall = @as(f64, @floatFromInt(tall.w - 8)) / @as(f64, @floatFromInt(tall.h - 24));
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), ratio_tall, 0.05);
    // Tiny images never shrink below the minimum window.
    const tiny = choose_window_size(8, 8);
    try std.testing.expect(tiny.w >= win_min_w);
    try std.testing.expect(tiny.h >= win_min_h);
    // Degenerate input is safe.
    const zero = choose_window_size(0, 0);
    try std.testing.expect(zero.w > 0 and zero.h > 0);
}

test "view: viewport rect sits between the title band and status bar" {
    const vp = viewport_rect(320, 240);
    try std.testing.expectEqual(@as(u32, title_band_h), vp.y);
    try std.testing.expectEqual(@as(u32, 240 - title_band_h - status_h), vp.h);
}

test "view: displayed size at the zoom table edges" {
    try std.testing.expectEqual(@as(u32, 80), displayed_size(320, 200, 25).w);
    try std.testing.expectEqual(@as(u32, 640), displayed_size(80, 50, 800).w);
    try std.testing.expectEqual(@as(u32, 1), displayed_size(1, 1, 25).w);
}

test "view: dest layout centers when it fits, clips when it does not" {
    const vp = Viewport{ .x = 0, .y = 16, .w = 300, .h = 200 };
    // Fits: centered.
    const fit = dest_layout(vp, 100, 50);
    try std.testing.expectEqual(@as(u32, 100), fit.w);
    try std.testing.expectEqual(@as(u32, 100), fit.x);
    try std.testing.expectEqual(@as(u32, 91), fit.y);
    // Overflows: pinned to the viewport origin, clipped to its extent.
    const big = dest_layout(vp, 600, 400);
    try std.testing.expectEqual(@as(u32, 0), big.x);
    try std.testing.expectEqual(@as(u32, 16), big.y);
    try std.testing.expectEqual(@as(u32, 300), big.w);
    try std.testing.expectEqual(@as(u32, 200), big.h);
}

test "view: pan clamp bounds the origin by the visible span" {
    // Image 800 px displayed at 4x in a 300 px viewport:
    // span = 300*800/3200 = 75 image px; origin in [0, 800-75].
    try std.testing.expectEqual(@as(u32, 725), clamp_origin(9999, 800, 3200, 300));
    // Fits: 10 is a legal pan position (only the max is clamped).
    try std.testing.expectEqual(@as(u32, 10), clamp_origin(10, 800, 3200, 300));
    // Fits: no panning at all.
    try std.testing.expectEqual(@as(u32, 0), clamp_origin(5, 100, 100, 300));
    try std.testing.expectEqual(@as(u32, 0), clamp_origin(5, 50, 25, 300));
}

test "view: zoom steps clamp at both ends and reset" {
    try std.testing.expectEqual(zoom_default_idx, step_zoom(zoom_default_idx, .reset));
    try std.testing.expectEqual(@as(usize, 5), step_zoom(zoom_default_idx, .in));
    try std.testing.expectEqual(@as(usize, 3), step_zoom(zoom_default_idx, .out));
    try std.testing.expectEqual(@as(usize, zoom_table.len - 1), step_zoom(zoom_table.len - 1, .in));
    try std.testing.expectEqual(@as(usize, 0), step_zoom(0, .out));
}

test "view: scroll decode honors magnitude, horizontal, and sign bits" {
    try std.testing.expectEqual(ScrollDir.up, scroll_dir(1).?);
    try std.testing.expectEqual(ScrollDir.down, scroll_dir(0x8000 | 1).?);
    try std.testing.expect(scroll_dir(0x4000 | 1) == null); // horizontal
    try std.testing.expect(scroll_dir(0) == null); // zero magnitude
}

test "view: title composition stays within the slot-64 contract" {
    var buf: [64]u8 = undefined;
    const t = compose_title(&buf, "GRADIENT_RGBA_8X8.QOI", 8, 8, .qoi, 400);
    try std.testing.expect(t.len > 0 and t.len <= 64);
    try std.testing.expect(std.mem.startsWith(u8, t, "view: GRADIENT_RGBA_8X8.QOI"));
    try std.testing.expect(std.mem.endsWith(u8, t, " 400%"));
    // A 32-byte name must not overflow the buffer (bufPrint errors -> empty).
    const long_name = "a" ** 32;
    const t2 = compose_title(&buf, long_name, 1, 1, .unknown, 100);
    try std.testing.expect(t2.len <= 64);
}

test "view: header size sniff dispatches QOI and PNG big-endian dims" {
    // QOI header: "qoif" + w BE + h BE (14 bytes total).
    var qoi_hdr: [24]u8 = [_]u8{0} ** 24;
    @memcpy(qoi_hdr[0..4], "qoif");
    std.mem.writeInt(u32, qoi_hdr[4..8], 320, .big);
    std.mem.writeInt(u32, qoi_hdr[8..12], 200, .big);
    @memcpy(&header_bytes, &qoi_hdr);
    header_have = 24;
    const s = header_size_or_default();
    try std.testing.expectEqual(@as(u32, 500), s.w);
    try std.testing.expectEqual(@as(u32, 331), s.h);

    // PNG header: sig + IHDR length + "IHDR" + w BE + h BE.
    var png_hdr: [24]u8 = [_]u8{0} ** 24;
    @memcpy(png_hdr[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png_hdr[8..12], 13, .little);
    @memcpy(png_hdr[12..16], "IHDR");
    std.mem.writeInt(u32, png_hdr[16..20], 64, .big);
    std.mem.writeInt(u32, png_hdr[20..24], 32, .big);
    @memcpy(&header_bytes, &png_hdr);
    header_have = 24;
    const s2 = header_size_or_default();
    // 64x32 with <= 2x upscale: clamped to 128x64 content, padded 8/24.
    try std.testing.expectEqual(@as(u32, 136), s2.w);
    try std.testing.expectEqual(@as(u32, 88), s2.h);

    // Unknown/garbage falls back to the default window.
    @memset(&header_bytes, 0);
    header_have = 24;
    const s3 = header_size_or_default();
    try std.testing.expectEqual(@as(u32, 320), s3.w);
    try std.testing.expectEqual(@as(u32, 240), s3.h);
}

test "view: the live-gate fixture decodes and pans through the full stack" {
    // The exact file the live gate loads: 160x120, two solid halves.
    const fixture_bytes = @embedFile("lib/fixtures/qoi/viewer_160x120.qoi");
    var fixture_pixels: [160 * 120]u32 align(1) = undefined;
    const hdr = try qoi.decode(fixture_bytes, &fixture_pixels);
    try std.testing.expectEqual(@as(u32, 160), hdr.width);
    try std.testing.expectEqual(@as(u32, 120), hdr.height);
    // Top half amber, bottom half slate-blue. QOI pixel words are
    // (A << 24) | (R << 16) | (G << 8) | B — the same layout the viewer's
    // blit reads RGB from.
    try std.testing.expectEqual(@as(u32, 0xFFE87A3A), fixture_pixels[10 * 160 + 80]);
    try std.testing.expectEqual(@as(u32, 0xFF336699), fixture_pixels[110 * 160 + 80]);

    // Pan math against the real gate geometry: at 400% the displayed image
    // is 640x480 — far past the capped viewport — so pan must engage and
    // clamp: one right-arrow step moves ox by vp/8 image px, and the origin
    // never leaves [0, img - span].
    const win = choose_window_size(hdr.width, hdr.height);
    const vp = viewport_rect(win.w, win.h);
    const disp = displayed_size(hdr.width, hdr.height, 400);
    const max_ox = pan_max(hdr.width, disp.w, vp.w);
    try std.testing.expect(disp.w > vp.w); // zoomed past the viewport
    try std.testing.expect(max_ox > 0);
    var ox: u32 = 0;
    const step = @max(1, @divTrunc(@divTrunc(@as(i32, @intCast(vp.w)) * 100, @as(i32, @intCast(disp.w))), 8));
    ox = apply_delta(ox, step, max_ox);
    try std.testing.expect(ox > 0 and ox <= max_ox);
    ox = apply_delta(ox, 100000, max_ox);
    try std.testing.expectEqual(max_ox, ox);
    ox = apply_delta(ox, -100000, max_ox);
    try std.testing.expectEqual(@as(u32, 0), ox);
}
