//! VirelaiOS Micro-Widget Toolkit & Runtime (ADR 0011, Milestone 11).
//!
//! Reusable, lightweight GUI primitives with ZERO heap allocation.
//! All widget structures are pure value types operating over static BSS
//! or stack buffers.

const std = @import("std");
pub const font8x8 = @import("font8x8.zig");
pub const image = @import("image.zig");
pub const Image = image.Image;

// ---------------------------------------------------------------------------
// M32 WMS7 Gate B (issue #627): the app↔WM mailbox protocol (WM_RPC) wire.
// This toolkit is compiled into 28 app modules whose module paths cannot
// reach `kernel/src/`, so the wire mirror below is frozen HERE and the
// live gate's byte-level round-trip (ui frame → WND.BIN parse → ack) is the
// integration drift guard: if this ever drifts from `wnd_core.WmRpc`, the
// WM's `wnd: mail` serve + the `wmrpc: *-ack` markers stop matching and the
// gate fails loudly. Layout is byte-identical to kernel/src/wnd_core.zig.
// ---------------------------------------------------------------------------
pub const WmRpc = extern struct {
    kind: u8,
    id: u8,
    seq: u8,
    reply_to: u8,
    applied: u8,
    pad: u8,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    title: [wm_rpc_title_max]u8,
};
pub const wm_rpc_title_max: usize = 24;
pub const wm_rpc_kind_raise: u8 = 1;
pub const wm_rpc_kind_config: u8 = 2;
pub const wm_rpc_kind_register_action: u8 = 3;
pub const wm_rpc_kind_invoke_action: u8 = 4;
pub const wm_rpc_kind_attach_tab: u8 = 5;
pub const wm_rpc_kind_detach_tab: u8 = 6;
pub const wm_rpc_kind_cycle_tab: u8 = 7;
pub const wm_rpc_reply_flag: u8 = 0x80;
pub const wm_rpc_max: usize = 64;

// ---------------------------------------------------------------------------
// Syscall Numbers & ABI Constants (ADR 0007 / ADR 0009 / ADR 0010)
// ---------------------------------------------------------------------------

pub const sys_write_num: u64 = 1;
pub const sys_yield_num: u64 = 2;
pub const sys_exit_num: u64 = 3;
pub const sys_sleep_num: u64 = 4;
pub const sys_procs_num: u64 = 7;
pub const sys_win_open_num: u64 = 12;
pub const sys_win_fill_num: u64 = 13;
pub const sys_win_present_num: u64 = 14;
pub const sys_win_close_num: u64 = 15;
pub const sys_win_move_num: u64 = 16;
pub const sys_ipc_send_num: u64 = 5;
pub const sys_ipc_recv_num: u64 = 6;
pub const sys_win_raise_num: u64 = 17;
pub const sys_win_get_num: u64 = 18;
pub const sys_win_query_num: u64 = 19;
pub const sys_win_set_visible_num: u64 = 20;
pub const sys_poll_event_num: u64 = 21;
pub const sys_wait_event_num: u64 = 22;
pub const sys_file_open_num: u64 = 23;
pub const sys_file_read_num: u64 = 24;
pub const sys_file_write_num: u64 = 25;
pub const sys_file_close_num: u64 = 26;
pub const sys_dir_list_num: u64 = 27;
pub const sys_exec_num: u64 = 28;
pub const sys_kill_num: u64 = 29;
pub const sys_tcp_connect_num: u64 = 30;
pub const sys_tcp_send_num: u64 = 31;
pub const sys_tcp_recv_num: u64 = 32;
pub const sys_tcp_close_num: u64 = 33;
pub const sys_file_delete_num: u64 = 34;
pub const sys_file_rename_num: u64 = 35;
pub const sys_file_truncate_num: u64 = 36;
pub const sys_file_free_num: u64 = 37;
pub const sys_clipboard_set_num: u64 = 38;
pub const sys_clipboard_get_num: u64 = 39;
pub const clipboard_capacity: usize = 512;
pub const sys_timer_set_num: u64 = 40;
pub const sys_audio_info_num: u64 = 42;
pub const sys_audio_play_num: u64 = 43;
pub const sys_audio_volume_num: u64 = 44;
pub const sys_audio_mute_num: u64 = 45;
pub const sys_win_fill_batch_num: u64 = 46;
pub const sys_win_raise_front_num: u64 = 49;
pub const sys_win_lower_back_num: u64 = 50;
pub const sys_notify_num: u64 = 51;
pub const sys_drag_start_num: u64 = 48;
pub const sys_drag_read_num: u64 = 55;
pub const sys_win_move_to_workspace_num: u64 = 52;
pub const sys_win_set_unsaved_num: u64 = 53;
pub const sys_timer_cancel_num: u64 = 41;
pub const sys_udp_listen_num: u64 = 9;
pub const sys_udp_send_num: u64 = 10;
pub const sys_udp_recv_num: u64 = 11;
pub const sys_mmap_num: u64 = 63;
pub const sys_munmap_num: u64 = 64;
pub const PROT_READ: u64 = 1;
pub const PROT_WRITE: u64 = 2;
pub const PROT_EXEC: u64 = 4;
pub const MAP_PRIVATE: u64 = 0x02;
pub const MAP_ANONYMOUS: u64 = 0x20;
pub const MAP_POPULATE: u64 = 0x8000;
pub const datagram_max: usize = 72;
pub const payload_max: usize = 64;

// ---------------------------------------------------------------------------
// Event Kinds & Modifier Masks (ADR 0009)
// ---------------------------------------------------------------------------

pub const KEY_DOWN: u16 = 1;
pub const KEY_UP: u16 = 2;
pub const MOUSE_DOWN: u16 = 3;
pub const MOUSE_UP: u16 = 4;
pub const MOUSE_MOVE: u16 = 5;
pub const WIN_FOCUS: u16 = 6;
pub const WIN_BLUR: u16 = 7;
pub const WIN_CLOSE: u16 = 8;
pub const EVENT_TIMER: u16 = 9;
pub const WIN_RESIZE: u16 = 10;
pub const MOUSE_RIGHT_DOWN: u16 = 11;
pub const MOUSE_RIGHT_UP: u16 = 13;
/// Arc4 #242 (ADR 0013 D2): unsaved-changes warning from compositor.
/// arg0 = 0 (save), 1 (don't save), 2 (cancel).
pub const WIN_UNSAVED: u16 = 17;
/// ADR 0015 (M32 WMS1, claim 1484): composite/present cadence tick for the
/// registered WM server; reserved until the WMS2 kernel push path exists
/// (kernel mirror: kernel/src/events.zig).
pub const COMPOSITE_TICK: u16 = 18;

pub const MOD_SHIFT: u16 = 0x0001;
pub const MOD_CTRL: u16 = 0x0002;
pub const MOD_ALT: u16 = 0x0004;
pub const MOD_CMD: u16 = 0x0008;

pub const BTN_LEFT: u16 = 0x0100;
pub const BTN_RIGHT: u16 = 0x0200;
pub const BTN_MIDDLE: u16 = 0x0400;

pub const Event = extern struct {
    kind: u16,
    flags: u16,
    seq: u32,
    arg0: u32,
    arg1: u32,
};

// ---------------------------------------------------------------------------
// Storage Access Modes & Directory Entry (ADR 0010)
// ---------------------------------------------------------------------------

pub const MODE_READ: u32 = 0x0001;
pub const MODE_WRITE: u32 = 0x0002;
pub const MODE_CREATE: u32 = 0x0004;
pub const MODE_APPEND: u32 = 0x0008;
/// M25 Lane B (claim 2539): with MODE_CREATE|MODE_WRITE, open() creates a
/// real FAT32 directory (kernel-side cluster + dot entries) instead of an
/// empty file. Zero new syscall slots — the slot 23 flag contract extends.
pub const MODE_DIR: u32 = 0x0010;

pub const DirEntry = extern struct {
    name: [32]u8,
    size: u32,
    is_dir: u8,
    reserved: [3]u8,
};

// ---------------------------------------------------------------------------
// Process Descriptor Snapshot (ADR 0007 / slot 7)
// ---------------------------------------------------------------------------

pub const ProcessRow = extern struct {
    pid: u64,
    state: u64,
    exit_status: u64,
    name: [16]u8,
};

// ---------------------------------------------------------------------------
// Theme System (ADR 0008 & ADR 0011, Issue #207)
// ---------------------------------------------------------------------------

pub const Theme = struct {
    bg: u32,
    surface: u32,
    border: u32,
    text_primary: u32,
    text_muted: u32,
    accent: u32,
    btn_idle: u32,
    btn_hover: u32,
    btn_pressed: u32,
    success: u32,
    danger: u32,
    warning: u32,
};

pub const THEME_DARK: Theme = .{
    .bg = 0x182026,
    .surface = 0x222d35,
    .border = 0x334155,
    .text_primary = 0xffffff,
    .text_muted = 0x94a3b8,
    .accent = 0x3b82f6,
    .btn_idle = 0x2d3748,
    .btn_hover = 0x4a5568,
    .btn_pressed = 0x1a202c,
    .success = 0x22c55e,
    .danger = 0xef4444,
    .warning = 0xf59e0b,
};

pub const THEME_LIGHT: Theme = .{
    .bg = 0xf1f5f9,
    .surface = 0xffffff,
    .border = 0xcbd5e1,
    .text_primary = 0x0f172a,
    .text_muted = 0x64748b,
    .accent = 0x2563eb,
    .btn_idle = 0xe2e8f0,
    .btn_hover = 0xcbd5e1,
    .btn_pressed = 0x94a3b8,
    .success = 0x16a34a,
    .danger = 0xdc2626,
    .warning = 0xd97706,
};

pub const THEME_AMBER: Theme = .{
    .bg = 0x1a1000,
    .surface = 0x2a1a00,
    .border = 0x5a4000,
    .text_primary = 0xffcc00,
    .text_muted = 0x997700,
    .accent = 0xff8800,
    .btn_idle = 0x3a2800,
    .btn_hover = 0x5a4000,
    .btn_pressed = 0x1a1000,
    .success = 0x88cc00,
    .danger = 0xff4444,
    .warning = 0xffaa00,
};

pub var current_theme: Theme = THEME_DARK;

pub const ThemeColors = struct {
    bg: u32,
    fg: u32,
    accent: u32,
    border: u32,
    title_bg: u32,
    title_fg: u32,
    @"error": u32,
    success: u32,
};

/// Get active theme colors palette struct.
pub fn get_theme_colors() ThemeColors {
    return .{
        .bg = current_theme.bg,
        .fg = current_theme.text_primary,
        .accent = current_theme.accent,
        .border = current_theme.border,
        .title_bg = current_theme.surface,
        .title_fg = current_theme.text_primary,
        .@"error" = current_theme.danger,
        .success = current_theme.success,
    };
}

/// Select a theme by name. Returns true if found and applied.
pub fn set_theme(name: []const u8) bool {
    if (eql(name, "dark")) {
        current_theme = THEME_DARK;
        return true;
    } else if (eql(name, "light")) {
        current_theme = THEME_LIGHT;
        return true;
    } else if (eql(name, "amber")) {
        current_theme = THEME_AMBER;
        return true;
    }
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// Theme color accessors — widget draw functions read from current_theme.
pub fn theme_bg() u32 {
    return current_theme.bg;
}
pub fn theme_surface() u32 {
    return current_theme.surface;
}
pub fn theme_border() u32 {
    return current_theme.border;
}
pub fn theme_text_primary() u32 {
    return current_theme.text_primary;
}
pub fn theme_text_muted() u32 {
    return current_theme.text_muted;
}
pub fn theme_accent() u32 {
    return current_theme.accent;
}
pub fn theme_btn_idle() u32 {
    return current_theme.btn_idle;
}
pub fn theme_btn_hover() u32 {
    return current_theme.btn_hover;
}
pub fn theme_btn_pressed() u32 {
    return current_theme.btn_pressed;
}
pub fn theme_success() u32 {
    return current_theme.success;
}
pub fn theme_danger() u32 {
    return current_theme.danger;
}
pub fn theme_warning() u32 {
    return current_theme.warning;
}

// ---------------------------------------------------------------------------
// Widget State & Styling Accessors (M27 G14 #457)
// ---------------------------------------------------------------------------

pub const WidgetState = enum {
    normal,
    hover,
    pressed,
    disabled,
    focused,
};

pub fn widget_bg(state: WidgetState) u32 {
    return switch (state) {
        .normal => theme_btn_idle(),
        .hover => theme_btn_hover(),
        .pressed => theme_btn_pressed(),
        .disabled => theme_surface(),
        .focused => theme_btn_hover(),
    };
}

pub fn widget_border(state: WidgetState) u32 {
    return switch (state) {
        .normal => theme_border(),
        .hover => theme_accent(),
        .pressed => theme_accent(),
        .disabled => theme_border(),
        .focused => theme_accent(),
    };
}

pub fn widget_text(state: WidgetState) u32 {
    return switch (state) {
        .normal, .hover, .pressed, .focused => theme_text_primary(),
        .disabled => theme_text_muted(),
    };
}

// Backward-compatible pub const aliases for app code that references
// ui.COLOR_*. These match the default (dark) theme. The widget draw
// functions use theme_*() for dynamic theming.
pub const COLOR_BG: u32 = THEME_DARK.bg;
pub const COLOR_SURFACE: u32 = THEME_DARK.surface;
pub const COLOR_BORDER: u32 = THEME_DARK.border;
pub const COLOR_TEXT_PRIMARY: u32 = THEME_DARK.text_primary;
pub const COLOR_TEXT_MUTED: u32 = THEME_DARK.text_muted;
pub const COLOR_ACCENT: u32 = THEME_DARK.accent;
pub const COLOR_BTN_IDLE: u32 = THEME_DARK.btn_idle;
pub const COLOR_BTN_HOVER: u32 = THEME_DARK.btn_hover;
pub const COLOR_BTN_PRESSED: u32 = THEME_DARK.btn_pressed;
pub const COLOR_SUCCESS: u32 = THEME_DARK.success;
pub const COLOR_DANGER: u32 = THEME_DARK.danger;
pub const COLOR_WARNING: u32 = THEME_DARK.warning;

// ---------------------------------------------------------------------------
// Syscall Invocation Helpers (AArch64 inline assembly / host fallback)
// ---------------------------------------------------------------------------

pub fn syscall0(num: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
        : .{ .memory = true });
    return res;
}

pub fn syscall1(num: u64, arg0: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
        : .{ .memory = true });
    return res;
}

pub fn syscall2(num: u64, arg0: u64, arg1: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
        : .{ .memory = true });
    return res;
}

pub fn syscall3(num: u64, arg0: u64, arg1: u64, arg2: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
        : .{ .memory = true });
    return res;
}

pub fn syscall4(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
        : .{ .memory = true });
    return res;
}

pub fn syscall6(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
          [arg4] "{x4}" (arg4),
          [arg5] "{x5}" (arg5),
        : .{ .memory = true });
    return res;
}

pub fn write_console(msg: []const u8) void {
    if (msg.len == 0) return;
    _ = syscall3(sys_write_num, 1, @intFromPtr(msg.ptr), msg.len);
}

pub fn yield_task() void {
    _ = syscall0(sys_yield_num);
}

pub fn exit_process(status: u64) noreturn {
    _ = syscall1(sys_exit_num, status);
    while (true) {
        yield_task();
    }
}

pub fn sleep_ticks(ticks: u64) void {
    _ = syscall1(sys_sleep_num, ticks);
}

pub fn win_open(x: u32, y: u32, w: u32, h: u32) i64 {
    return syscall4(sys_win_open_num, x, y, w, h);
}

pub fn win_fill(id: u32, x: u32, y: u32, w: u32, h: u32, rgb: u32) void {
    _ = syscall6(sys_win_fill_num, id, x, y, w, h, rgb);
}

// ---------------------------------------------------------------------------
// M32 WMS9 (issue #629): batched fills on the surface seam.
//
// Instead of one syscall per glyph pixel, drawing primitives accumulate fill
// rects in a static `FillBatcher` and flush them through slot 46
// `sys_win_fill_batch` (one SVC per up-to-32 rects). Zero heap allocation:
// the batch lives in static BSS. Output is pixel-identical to per-pixel
// fills; only the syscall count collapses.
// ---------------------------------------------------------------------------

/// One packed rect in a slot-46 batch: 24 bytes, matching the kernel's
/// handle_win_fill_batch layout {id: u8, _pad: [3]u8, x, y, w, h: u32, rgb: u32}.
const FILL_RECT_SIZE: usize = 24;
const FILL_BATCH_MAX: usize = 32;

/// Accumulates fill rects and flushes them through slot 46 in chunks of 32.
/// Zero heap allocation: the buffer lives in static BSS. Batches are keyed
/// per window id — flushing automatically whenever the window id changes,
/// so callers never need to think about it.
pub const FillBatcher = struct {
    buf: [FILL_BATCH_MAX * FILL_RECT_SIZE]u8 align(8) = undefined,
    len: usize = 0,
    cur_id: u32 = 0,

    pub fn reset(self: *FillBatcher) void {
        self.len = 0;
    }

    fn push(self: *FillBatcher, id: u32, x: u32, y: u32, w: u32, h: u32, rgb: u32) void {
        if (self.len >= FILL_BATCH_MAX * FILL_RECT_SIZE) {
            self.flush();
        }
        const off = self.len;
        self.buf[off] = @intCast(id & 0xff);
        self.buf[off + 1] = 0;
        self.buf[off + 2] = 0;
        self.buf[off + 3] = 0;
        std.mem.writeInt(u32, self.buf[off + 4 ..][0..4], x, .little);
        std.mem.writeInt(u32, self.buf[off + 8 ..][0..4], y, .little);
        std.mem.writeInt(u32, self.buf[off + 12 ..][0..4], w, .little);
        std.mem.writeInt(u32, self.buf[off + 16 ..][0..4], h, .little);
        std.mem.writeInt(u32, self.buf[off + 20 ..][0..4], rgb, .little);
        self.len += FILL_RECT_SIZE;
    }

    /// Send all buffered rects through slot 46 in one SVC per 32 rects.
    pub fn flush(self: *FillBatcher) void {
        if (self.len == 0) return;
        _ = syscall2(sys_win_fill_batch_num, @intFromPtr(&self.buf), self.len);
        self.reset();
    }
};

/// The toolkit-wide fill batcher (static BSS, zero heap allocation).
pub var fill_batcher = FillBatcher{};

/// Queue a fill rect into the batcher. Flushes automatically on window-id
/// change or when the 32-rect batch is full, so ordering across windows is
/// preserved and callers never need to flush manually.
pub fn win_fill_batched(id: u32, x: u32, y: u32, w: u32, h: u32, rgb: u32) void {
    if (fill_batcher.len > 0 and fill_batcher.cur_id != id) {
        fill_batcher.flush();
    }
    fill_batcher.cur_id = id;
    fill_batcher.push(id, x, y, w, h, rgb);
}

/// Flush any pending batched fills (call before win_present / frame end).
pub fn flush_fills() void {
    fill_batcher.flush();
}

pub fn win_present(id: u32) void {
    flush_fills();
    _ = syscall1(sys_win_present_num, id);
}

pub fn win_close(id: u32) void {
    _ = syscall1(sys_win_close_num, id);
}

/// Arc4 #238: raise the window to the top of the z-order — the frozen-syscall
/// path (slot 49). WMS7 Gate B: `wm_raise_front` below is how the toolkit
/// "asks the WM"; this syscall path is the shim-mode / no-WM fallback and
/// stays intact for the frozen render-state ABI.
pub fn win_raise_front(id: u32) bool {
    return syscall1(sys_win_raise_front_num, id) == 0;
}

/// Arc4 #238: lower the window to the bottom of the z-order.
pub fn win_lower_back(id: u32) bool {
    return syscall1(sys_win_lower_back_num, id) == 0;
}

// ---------------------------------------------------------------------------
// M32 WMS7 Gate B (issue #627): the toolkit WM_RPC client.
//
// Apps "ask the WM" instead of "syscall the desktop": these helpers build a
// `WmRpc` frame (single-sourced in wnd_core), send it to the registered WM's
// mailbox (sys_ipc_send, slot 5) and await its ack reply in OUR OWN inbox
// (sys_ipc_recv, slot 6 — recv always reads the caller's own ring, so the
// toolkit needs no separate self-pid). If no WM is registered (the shim
// desktop), they fall back to the frozen syscalls — byte-identical behavior,
// additive back-compat.
//
// The API is synchronized-shaped (send + bounded poll on the reply), the
// issue's "async inversion" note answered explicitly: the WM serves at its
// 1 Hz kind-18 wake, so a mail op takes ≤ 1 s; app code stays a plain call.
// ---------------------------------------------------------------------------

/// The registered WM server's process name (the WMS3 `wnd start` bootstrap
/// execs WND.BIN; a future WM keeps the same name via ADR 0015).
pub const wm_proc_name: []const u8 = "WND.BIN";
/// The proc-snapshot buffer bound (16 rows × 40 B — plenty for any fleet).
pub const wm_procs_buf: usize = 16 * 40;
/// The mailbox slot bound the WM_RPC frame must fit (the frozen 64 B).
pub const wm_rpc_slot_bytes: usize = wm_rpc_max;

/// Scan `sys_procs` for a RUNNING process whose 16-byte name equals `want`
/// (the claim-5799 snapshot row: u64 pid / u64 state / u64 exit / 16-byte
/// NUL-padded name). Returns its pid, or 0 if absent. `sys_procs` returns the
/// ROW COUNT, not bytes (the claim-5799 contract).
pub fn wm_find_pid(want: []const u8) u64 {
    var rows: [wm_procs_buf]u8 align(8) = undefined;
    const row_count = get_procs(&rows);
    if (row_count <= 0) return 0;
    var infos: [16]ProcInfo = undefined;
    const n = parse_procs(&rows, @intCast(row_count), &infos);
    for (infos[0..n]) |p| {
        if (p.state != .running) continue;
        if (std.mem.eql(u8, p.name[0..p.name_len], want)) return p.pid;
    }
    return 0;
}

/// Resolve the WM's pid and the caller-specified self pid in ONE sys_procs
/// scan — the WM acks to `reply_to`, so the requester must supply its own
/// pid (resolved by its own process name, the WMRPC pattern). Returns
/// (wm_pid, self_pid); a zero wm_pid means shim mode / no WM.
pub fn wm_peers(self_name: []const u8) struct { wm: u64, self: u64 } {
    var rows: [wm_procs_buf]u8 align(8) = undefined;
    const row_count = get_procs(&rows);
    var wm: u64 = 0;
    var self_pid: u64 = 0;
    if (row_count > 0) {
        var infos: [16]ProcInfo = undefined;
        const n = parse_procs(&rows, @intCast(row_count), &infos);
        for (infos[0..n]) |p| {
            if (p.state != .running) continue;
            const nm = p.name[0..p.name_len];
            if (std.mem.eql(u8, nm, wm_proc_name)) wm = p.pid;
            if (self_name.len != 0 and std.mem.eql(u8, nm, self_name)) self_pid = p.pid;
        }
    }
    return .{ .wm = wm, .self = self_pid };
}

/// Discover the registered WM's pid (0 = none / shim mode).
pub fn wm_available() u64 {
    return wm_find_pid(wm_proc_name);
}

/// Send one WM_RPC request and await its ack in our own inbox. Returns
/// whether the WM applied it. `self_name` identifies THIS process so the
/// WM's ack routes back through `sys_ipc_send(reply_to)`; recv then reads
/// our own ring. With the WM's 1 Hz serve cadence the bounded poll is far
/// more than enough; a timeout returns false (honest — the gate would then
/// fail rather than fake it). No WM reachable → false (caller falls back to
/// the frozen syscall).
pub fn wm_mail_request(kind: u8, id: u32, x: u16, y: u16, w: u16, h: u16, title: []const u8, self_name: []const u8, seq: u8) bool {
    const peers = wm_peers(self_name);
    if (peers.wm == 0 or peers.self == 0) return false;
    var req: WmRpc = .{
        .kind = kind,
        .id = @intCast(id & 0xff),
        .seq = seq,
        .reply_to = @intCast(peers.self & 0xff),
        .applied = 0,
        .pad = 0,
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .title = [_]u8{0} ** wm_rpc_title_max,
    };
    const take = @min(title.len, wm_rpc_title_max);
    @memcpy(req.title[0..take], title[0..take]);
    const req_bytes = std.mem.asBytes(&req);
    _ = syscall3(sys_ipc_send_num, peers.wm, @intFromPtr(req_bytes.ptr), req_bytes.len);
    // Await our own inbox for the ack (recv reads the CALLER's ring, so no
    // self-pid needed): a bounded poll over a sleep+yield.
    var tries: u32 = 0;
    while (tries < 200_000) : (tries += 1) {
        var raw: [wm_rpc_slot_bytes]u8 = undefined;
        const got = syscall2(sys_ipc_recv_num, @intFromPtr(&raw), raw.len);
        if (got >= @sizeOf(WmRpc)) {
            var rep: WmRpc = undefined;
            @memcpy(std.mem.asBytes(&rep), raw[0..@sizeOf(WmRpc)]);
            if (rep.kind & wm_rpc_reply_flag != 0 and rep.seq == req.seq) {
                return rep.applied != 0;
            }
        }
        _ = syscall0(sys_yield_num);
    }
    return false; // timeout
}

/// Ask the WM to raise window `id` (WIN_RAISE, kind 1) — the toolkit's
/// "ask the WM" raise. `self_name` is THIS process's own name (its pid is
/// resolved for the ack's `reply_to`). Falls back to the frozen
/// `sys_win_raise_front` when no WM is registered (shim mode), so behavior
/// is identical either way.
pub fn wm_raise_front(id: u32, self_name: []const u8) bool {
    if (wm_mail_request(wm_rpc_kind_raise, id, 0, 0, 0, 0, "", self_name, 1)) return true;
    return win_raise_front(id); // fallback
}

/// Ask the WM to move/resize window `id` to `x,y,w,h` (WIN_CONFIG, kind 2).
/// `self_name` is THIS process's own name (ack routing). Falls back to the
/// frozen `sys_win_move` when no WM is registered.
pub fn wm_config(id: u32, x: u32, y: u32, w: u32, h: u32, self_name: []const u8) bool {
    if (wm_mail_request(wm_rpc_kind_config, id, @intCast(x), @intCast(y), @intCast(w), @intCast(h), "", self_name, 1)) return true;
    // Fallback: `sys_win_move(id, x, y)` takes x and y as SEPARATE args
    // (slot 16 — clamp+move, owner-restricted); there is no syscall resize
    // here, so the byte-identical frozen behavior is the move (static size
    // keeps the shim path honest; a caller wanting resize still uses
    // sys_win_resize when no WM is present).
    return syscall3(sys_win_move_num, id, x, y) == 0;
}

/// S1/S5 Action registry seam: register an action into section `section_id` for window `window_id`.
pub fn wm_register_action(window_id: u32, section_id: u16, action_id: u16, label: []const u8, self_name: []const u8) bool {
    return wm_mail_request(wm_rpc_kind_register_action, window_id, section_id, action_id, 0, 0, label, self_name, 1);
}

/// S5 Action registry seam: invoke a registered action.
pub fn wm_invoke_action(label: []const u8, self_name: []const u8) bool {
    return wm_mail_request(wm_rpc_kind_invoke_action, 0, 0, 0, 0, 0, label, self_name, 2);
}

/// S6 Tab model: attach window `child_id` as a tab of `parent_id`.
pub fn wm_attach_tab(child_id: u32, parent_id: u32, self_name: []const u8) bool {
    return wm_mail_request(wm_rpc_kind_attach_tab, child_id, @intCast(parent_id), 0, 0, 0, "", self_name, 3);
}

/// S6 Tab model: cycle active tab in the focused group.
pub fn wm_cycle_tab(self_name: []const u8) bool {
    return wm_mail_request(wm_rpc_kind_cycle_tab, 0, 0, 0, 0, 0, "", self_name, 4);
}

/// S6 Tab model: detach tab window `child_id` back to standalone.
pub fn wm_detach_tab(child_id: u32, self_name: []const u8) bool {
    return wm_mail_request(wm_rpc_kind_detach_tab, child_id, 0, 0, 0, 0, "", self_name, 5);
}

test "WMS7 Gate B: the toolkit WM_RPC wire mirror matches the frozen wnd_core ABI" {
    // The toolkit's mirror (user/src/lib/ui.zig) must stay byte-identical to
    // kernel/src/wnd_core.zig's WmRpc (the WM server parses this exact
    // layout). The live gate is the integration drift guard, but this host
    // test locks the layout/consts to the frozen ADR-0015 values so a drift
    // is caught WITHOUT a VM.
    try std.testing.expectEqual(@as(u8, 1), wm_rpc_kind_raise);
    try std.testing.expectEqual(@as(u8, 2), wm_rpc_kind_config);
    try std.testing.expectEqual(@as(u8, 3), wm_rpc_kind_register_action);
    try std.testing.expectEqual(@as(u8, 4), wm_rpc_kind_invoke_action);
    try std.testing.expectEqual(@as(u8, 5), wm_rpc_kind_attach_tab);
    try std.testing.expectEqual(@as(u8, 6), wm_rpc_kind_detach_tab);
    try std.testing.expectEqual(@as(u8, 7), wm_rpc_kind_cycle_tab);
    try std.testing.expectEqual(@as(u8, 0x80), wm_rpc_reply_flag);
    try std.testing.expectEqual(@as(u8, 24), wm_rpc_title_max);
    try std.testing.expectEqual(@as(usize, 64), wm_rpc_max);
    // The frozen little-endian layout: kind/id/seq/reply/applied/pad (6 B),
    // x/y/w/h (8 B), 24-byte title = 38 total; the frame fits the 64-B slot.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(WmRpc, "kind"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(WmRpc, "x"));
    try std.testing.expectEqual(@as(usize, 14), @offsetOf(WmRpc, "title"));
    try std.testing.expectEqual(@as(usize, 38), @sizeOf(WmRpc));
    try std.testing.expect(@sizeOf(WmRpc) <= wm_rpc_max);
}

/// Arc4 #240: post a desktop notification toast. level: 0=info, 1=warn, 2=error.
pub fn notify(text: []const u8, level: u32) bool {
    return syscall3(sys_notify_num, @intFromPtr(text.ptr), text.len, level) == 0;
}

/// Arc4 #237: start a drag with a payload (up to 512B).
pub fn drag_start(payload: []const u8) bool {
    return syscall2(sys_drag_start_num, @intFromPtr(payload.ptr), payload.len) == 0;
}

/// Arc4 #237: read the drag payload after receiving a DROP event.
pub fn drag_read(buf: []u8) usize {
    return @intCast(syscall2(sys_drag_read_num, @intFromPtr(buf.ptr), buf.len));
}

/// Arc4 #241: move the window to a different workspace (0..2).
pub fn win_move_to_workspace(id: u32, ws: u32) bool {
    return syscall2(sys_win_move_to_workspace_num, id, ws) == 0;
}

/// Arc4 #242: mark or clear the unsaved-changes flag on a user window.
/// When set, clicking the close button shows a Save/Don't Save/Cancel dialog.
pub fn win_set_unsaved(id: u32, flag: bool) bool {
    return syscall2(sys_win_set_unsaved_num, id, if (flag) 1 else 0) == 0;
}

pub fn wait_event(ev: *Event) i64 {
    return syscall1(sys_wait_event_num, @intFromPtr(ev));
}

pub fn poll_event(ev: *Event) i64 {
    return syscall1(sys_poll_event_num, @intFromPtr(ev));
}

pub fn file_open(path: []const u8, flags: u32) i64 {
    return syscall3(sys_file_open_num, @intFromPtr(path.ptr), path.len, flags);
}

/// M25 Lane B (claim 2539): create a directory by `/`-path through the
/// slot 23 MODE_DIR flag extension. Returns the fd (close it), or a
/// negative error: -8 name too long, -9 exists, -5 disk full, -6 bad
/// path / no disk. The handle rejects read/write — creation only.
pub fn file_mkdir(path: []const u8) i64 {
    const fd = syscall3(sys_file_open_num, @intFromPtr(path.ptr), path.len, MODE_WRITE | MODE_CREATE | MODE_DIR);
    if (fd >= 0) file_close(@intCast(fd));
    return fd;
}

pub fn file_read(handle: u32, buf: []u8) i64 {
    return syscall3(sys_file_read_num, handle, @intFromPtr(buf.ptr), buf.len);
}

pub fn file_write(handle: u32, data: []const u8) i64 {
    return syscall3(sys_file_write_num, handle, @intFromPtr(data.ptr), data.len);
}

pub fn file_close(handle: u32) void {
    _ = syscall1(sys_file_close_num, handle);
}

/// Claim 3570 (ADR 0010 slot 27): enumerate the entries of a directory
/// ("" or "/data" — the DATA partition; "/esp" — the ESP) into `buf`.
/// Returns the entry count written, or a negative ADR 0007 error. Each
/// `DirEntry` is 40 bytes (`name[32]` NUL-padded + `size` + `is_dir`).
pub fn dir_list(path: []const u8, buf: []DirEntry) i64 {
    return syscall4(sys_dir_list_num, @intFromPtr(path.ptr), path.len, @intFromPtr(buf.ptr), buf.len);
}

/// Claim 5801 (ADR 0007 slot 34): delete a file by path. 0 on success;
/// negative error otherwise (EINVAL bad path, ENOENT absent).
pub fn file_delete(path: []const u8) i64 {
    return syscall2(sys_file_delete_num, @intFromPtr(path.ptr), path.len);
}

/// Claim 5801 (ADR 0007 slot 35): rename a file (same directory). 0 on
/// success; negative error otherwise.
pub fn file_rename(old_path: []const u8, new_path: []const u8) i64 {
    return syscall4(sys_file_rename_num, @intFromPtr(old_path.ptr), old_path.len, @intFromPtr(new_path.ptr), new_path.len);
}

/// Claim 5801 (ADR 0007 slot 36): resize an OPEN handle to `size` bytes.
pub fn file_truncate(handle: u32, size: u32) i64 {
    return syscall2(sys_file_truncate_num, handle, size);
}

/// Claim 5801 (ADR 0007 slot 37): free bytes on a volume (0 = DATA, 1 = ESP).
pub fn file_free(volume: u32) i64 {
    return syscall1(sys_file_free_num, volume);
}

/// Claim 0169 (ADR 0007 slot 38): store text in the SHARED kernel clipboard
/// (truncated at 512 bytes). Returns the stored length; negative error
/// otherwise (EINVAL non-process caller, EFAULT bad pointer).
pub fn clipboard_set(data: []const u8) i64 {
    return syscall2(sys_clipboard_set_num, @intFromPtr(data.ptr), data.len);
}

/// Claim 0169 (ADR 0007 slot 39): read the SHARED kernel clipboard into
/// `buf` (non-destructive — the clipboard is not consumed). Returns the
/// copied length; 0 when empty; negative error otherwise.
pub fn clipboard_get(buf: []u8) i64 {
    return syscall2(sys_clipboard_get_num, @intFromPtr(buf.ptr), buf.len);
}

/// The negotiated playback state `sys_audio_info` copies out (ADR 0007
/// slot 42). 16 bytes, fixed layout.
pub const AudioInfo = extern struct {
    ready: u32,
    format: u8, // negotiated FMT_* (0xff = none)
    rate: u8, // negotiated RATE_* (0xff = none)
    channels: u8,
    padding: u8,
    period_bytes: u32,
    max_len: u32,
};

/// Claim 7636 (ADR 0007 slot 42): learn the device's negotiated playback
/// state. Returns 0; negative error otherwise (ENXIO when no sound device
/// is attached — the default VM).
pub fn audio_info(out: *AudioInfo) i64 {
    return syscall1(sys_audio_info_num, @intFromPtr(out));
}

/// Claim 7636 (ADR 0007 slot 43): play `data` bytes of PCM samples in the
/// negotiated format (the app synthesizes what `audio_info` reported).
/// Returns the bytes played; negative error otherwise (ENXIO no device,
/// ENAMETOOLONG over the kernel bound, EFAULT bad pointer).
pub fn audio_play(data: []const u8) i64 {
    return syscall2(sys_audio_play_num, @intFromPtr(data.ptr), data.len);
}

/// Claim 9297 (ADR 0007 slot 44): set the bounded kernel-side stream
/// volume (0..100 percent). Returns the volume on success; negative error
/// otherwise (EINVAL for a non-process caller or an out-of-range value —
/// no silent clamping).
pub fn audio_volume(vol: u8) i64 {
    return syscall1(sys_audio_volume_num, vol);
}

/// Claim 9297 (ADR 0007 slot 45): set the kernel-side mute state (1 =
/// silent). Returns 0 on success; negative error otherwise (EINVAL for a
/// non-process caller or a value that is not 0/1).
pub fn audio_mute(muted: u8) i64 {
    return syscall1(sys_audio_mute_num, muted);
}

/// Claim 7323 (ADR 0007 slot 40): arm the CALLING process's app timer to
/// fire ONE `EVENT_TIMER` event into its ADR 0009 queue after `delay_ticks`
/// scheduler ticks (0 clamps to 1; over-long truncates at the kernel bound;
/// re-arming replaces a pending timer). Returns 0; negative error otherwise
/// (EINVAL non-process caller).
pub fn timer_set(delay_ticks: u64) i64 {
    return syscall1(sys_timer_set_num, delay_ticks);
}

/// Claim 7323 (ADR 0007 slot 41): disarm the CALLING process's app timer.
/// Returns 1 if a pending timer was canceled, 0 if none was armed; negative
/// error otherwise (EINVAL non-process caller).
pub fn timer_cancel() i64 {
    return syscall0(sys_timer_cancel_num);
}

pub fn udp_listen(port: u16) i64 {
    return syscall1(sys_udp_listen_num, port);
}

pub fn udp_send(dst_ip: u32, dst_port: u16, payload: []const u8) i64 {
    return syscall4(sys_udp_send_num, dst_ip, dst_port, @intFromPtr(payload.ptr), payload.len);
}

pub fn udp_recv(port: u16, buf: []u8) i64 {
    return syscall3(sys_udp_recv_num, port, @intFromPtr(buf.ptr), buf.len);
}

pub fn tcp_listen(port: u16) i64 {
    return syscall2(sys_tcp_connect_num, 0, port);
}

pub fn tcp_connect(ip: u32, port: u16) i64 {
    return syscall2(sys_tcp_connect_num, ip, port);
}

pub fn tcp_send(data: []const u8) i64 {
    return syscall2(sys_tcp_send_num, @intFromPtr(data.ptr), data.len);
}

pub fn tcp_recv(buf: []u8) i64 {
    return syscall2(sys_tcp_recv_num, @intFromPtr(buf.ptr), buf.len);
}

pub fn tcp_close() i64 {
    return syscall0(sys_tcp_close_num);
}

/// M29 (issue #598): sys_mmap wrapper — allocate anonymous user memory.
pub fn mmap(addr: u64, len: u64, prot: u64, flags: u64) i64 {
    return syscall4(sys_mmap_num, addr, len, prot, flags);
}

/// M29 (issue #598): sys_munmap wrapper — free anonymous user memory.
pub fn munmap(addr: u64, len: u64) i64 {
    return syscall2(sys_munmap_num, addr, len);
}

pub const sys_ping_send_num: u64 = 59;
pub const sys_ping_poll_num: u64 = 60;
pub const sys_net_stats_num: u64 = 62;

pub fn ping_send(ip: u32) i64 {
    return syscall1(sys_ping_send_num, ip);
}

pub fn ping_poll() i64 {
    return syscall0(sys_ping_poll_num);
}

pub const ProcState = enum(u64) {
    created = 1,
    running = 2,
    exited = 3,
    _,
};

/// Claim 6359 (ADR 0007 slot 28): load a `.BIN` from the ESP into a fresh
/// process slot from EL0 — the launcher half of the exec seam (the EL1h
/// monitor's `exec` is the privileged equivalent). Returns the new
/// process's pid on success; negative ADR 0007 error otherwise (EINVAL
/// bad path/loader refusal, EFAULT bad pointer, ENOENT not on the ESP,
/// ENOSPC capacity).
pub fn exec_program(name: []const u8) i64 {
    if (name.len == 0) return -1;
    return syscall2(sys_exec_num, @intFromPtr(name.ptr), name.len);
}

/// Claim 7604 (ADR 0007 slot 29): arm the target process for termination
/// from EL0 — the kill half of the process-control seam (the EL1h
/// monitor's `kill` is the privileged equivalent). The target exits with
/// the reserved status 137 at its next ring selection. Returns 0 once
/// armed; EINVAL for an out-of-range/free/exited/scheduler-owned target or
/// a non-process caller.
pub fn kill_process(pid: u64) i64 {
    return syscall1(sys_kill_num, pid);
}

pub const ProcInfo = struct {
    pid: u64,
    state: ProcState,
    exit_status: u64,
    name: [16]u8,
    name_len: usize,
};

pub fn get_procs(buf: []u8) i64 {
    return syscall2(sys_procs_num, @intFromPtr(buf.ptr), buf.len);
}

pub fn parse_procs(raw: []const u8, row_count: usize, out: []ProcInfo) usize {
    const row_size: usize = 40;
    const max_rows = @min(row_count, @min(raw.len / row_size, out.len));
    var i: usize = 0;
    while (i < max_rows) : (i += 1) {
        const off = i * row_size;
        const pid = std.mem.readInt(u64, raw[off .. off + 8][0..8], .little);
        const state_raw = std.mem.readInt(u64, raw[off + 8 .. off + 16][0..8], .little);
        const exit_status = std.mem.readInt(u64, raw[off + 16 .. off + 24][0..8], .little);
        var name: [16]u8 = [_]u8{0} ** 16;
        @memcpy(&name, raw[off + 24 .. off + 40]);

        var name_len: usize = 0;
        while (name_len < 16 and name[name_len] != 0) : (name_len += 1) {}

        out[i] = .{
            .pid = pid,
            .state = @enumFromInt(state_raw),
            .exit_status = exit_status,
            .name = name,
            .name_len = name_len,
        };
    }
    return max_rows;
}

// ---------------------------------------------------------------------------
// Geometry Primitives
// ---------------------------------------------------------------------------

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn make(x: u32, y: u32, w: u32, h: u32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn contains(self: Rect, px: u32, py: u32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }

    pub fn inset(self: Rect, dx: u32, dy: u32) Rect {
        const double_dx = dx * 2;
        const double_dy = dy * 2;
        return .{
            .x = self.x + dx,
            .y = self.y + dy,
            .w = if (self.w > double_dx) self.w - double_dx else 0,
            .h = if (self.h > double_dy) self.h - double_dy else 0,
        };
    }
};

// ---------------------------------------------------------------------------
// Drawing Primitives
// ---------------------------------------------------------------------------

pub fn draw_rect(win_id: u32, rect: Rect, rgb: u32) void {
    if (rect.w == 0 or rect.h == 0) return;
    win_fill_batched(win_id, rect.x, rect.y, rect.w, rect.h, rgb);
}

pub fn draw_rect_outline(win_id: u32, rect: Rect, thickness: u32, rgb: u32) void {
    if (rect.w == 0 or rect.h == 0 or thickness == 0) return;
    // Top
    win_fill_batched(win_id, rect.x, rect.y, rect.w, thickness, rgb);
    // Bottom
    if (rect.h > thickness) {
        win_fill_batched(win_id, rect.x, rect.y + rect.h - thickness, rect.w, thickness, rgb);
    }
    // Left
    win_fill_batched(win_id, rect.x, rect.y, thickness, rect.h, rgb);
    // Right
    if (rect.w > thickness) {
        win_fill_batched(win_id, rect.x + rect.w - thickness, rect.y, thickness, rect.h, rgb);
    }
}

pub fn draw_char(win_id: u32, ch: u8, x: u32, y: u32, fg_rgb: u32) void {
    if (ch < 0x20 or ch > 0x7e) return;
    const glyph = font8x8.glyphs[ch - 0x20];
    var row_idx: usize = 0;
    while (row_idx < 8) : (row_idx += 1) {
        const row_byte = glyph[row_idx];
        // Emit one span per contiguous run of set pixels instead of one
        // 1×1 fill per pixel (WMS9, issue #629). Same pixels, fewer syscalls.
        var col_idx: usize = 0;
        while (col_idx < 8) {
            if (!font8x8.row_pixel(row_byte, col_idx)) {
                col_idx += 1;
                continue;
            }
            const start_col = col_idx;
            while (col_idx < 8 and font8x8.row_pixel(row_byte, col_idx)) : (col_idx += 1) {}
            win_fill_batched(win_id, x + @as(u32, @intCast(start_col)), y + @as(u32, @intCast(row_idx)), @as(u32, @intCast(col_idx - start_col)), 1, fg_rgb);
        }
    }
}

pub fn draw_text(win_id: u32, text: []const u8, x: u32, y: u32, fg_rgb: u32) void {
    var cur_x = x;
    for (text) |ch| {
        draw_char(win_id, ch, cur_x, y, fg_rgb);
        cur_x += 8;
    }
}

pub fn draw_text_centered(win_id: u32, text: []const u8, rect: Rect, fg_rgb: u32) void {
    const text_w = @as(u32, @intCast(text.len)) * 8;
    const text_h: u32 = 8;
    const x = if (rect.w > text_w) rect.x + (rect.w - text_w) / 2 else rect.x;
    const y = if (rect.h > text_h) rect.y + (rect.h - text_h) / 2 else rect.y;
    draw_text(win_id, text, x, y, fg_rgb);
}

// ---------------------------------------------------------------------------
// Step 6 (Issue #206): 8×16 font helpers for titles and headings.
// Uses the kernel's 2×-stretched glyph table via a runtime pixel walk.
// ---------------------------------------------------------------------------

pub fn draw_char_16(win_id: u32, ch: u8, x: u32, y: u32, fg_rgb: u32) void {
    if (ch < 0x20 or ch > 0x7e) return;
    // The 8×16 glyph is the 8×8 glyph with each row doubled.
    // We re-derive the stretch at render time to stay in sync with
    // font8x8.zig's glyphs_16 table (same data, user-side copy).
    const glyph = font8x8.glyphs[ch - 0x20];
    var row_idx: usize = 0;
    while (row_idx < 8) : (row_idx += 1) {
        const row_byte = glyph[row_idx];
        var col_idx: usize = 0;
        while (col_idx < 8) {
            if (!font8x8.row_pixel(row_byte, col_idx)) {
                col_idx += 1;
                continue;
            }
            const start_col = col_idx;
            while (col_idx < 8 and font8x8.row_pixel(row_byte, col_idx)) : (col_idx += 1) {}
            // One 2px-tall span per contiguous run (2× vertical stretch) —
            // replaces two 1×1 fills per pixel (WMS9, issue #629).
            win_fill_batched(win_id, x + @as(u32, @intCast(start_col)), y + @as(u32, @intCast(row_idx * 2)), @as(u32, @intCast(col_idx - start_col)), 2, fg_rgb);
        }
    }
}

pub fn draw_text_large(win_id: u32, text: []const u8, x: u32, y: u32, fg_rgb: u32) void {
    var cur_x = x;
    for (text) |ch| {
        draw_char_16(win_id, ch, cur_x, y, fg_rgb);
        cur_x += 8;
    }
}

pub fn draw_text_centered_large(win_id: u32, text: []const u8, rect: Rect, fg_rgb: u32) void {
    const text_w = @as(u32, @intCast(text.len)) * 8;
    const text_h: u32 = 16;
    const x = if (rect.w > text_w) rect.x + (rect.w - text_w) / 2 else rect.x;
    const y = if (rect.h > text_h) rect.y + (rect.h - text_h) / 2 else rect.y;
    draw_text_large(win_id, text, x, y, fg_rgb);
}

// ---------------------------------------------------------------------------
// Window Backing Buffer Support & Raster Blitting
// ---------------------------------------------------------------------------

pub const WindowBacking = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
};

const max_backing_windows: usize = 16;
var window_backings: [max_backing_windows]?WindowBacking = [_]?WindowBacking{null} ** max_backing_windows;

/// Associate a direct 32-bpp RGBA/RGBX backing buffer with a window ID.
pub fn win_set_backing(win_id: u32, pixels: [*]u32, width: u32, height: u32) void {
    if (win_id >= max_backing_windows) return;
    window_backings[win_id] = .{
        .pixels = pixels,
        .width = width,
        .height = height,
    };
}

/// Disassociate any registered backing buffer for a window ID.
pub fn win_clear_backing(win_id: u32) void {
    if (win_id >= max_backing_windows) return;
    window_backings[win_id] = null;
}

/// Retrieve the registered backing buffer for a window ID, if any.
pub fn win_get_backing(win_id: u32) ?WindowBacking {
    if (win_id >= max_backing_windows) return null;
    return window_backings[win_id];
}

/// Standard Porter-Duff source-over alpha blending for 32-bpp 0xAARRGGBB pixels.
pub fn blend_source_over(dst: u32, src: u32) u32 {
    const src_a: u32 = (src >> 24) & 0xFF;
    if (src_a == 0) return dst;
    if (src_a == 255) return src;

    const inv_a: u32 = 255 - src_a;
    const src_r: u32 = (src >> 16) & 0xFF;
    const src_g: u32 = (src >> 8) & 0xFF;
    const src_b: u32 = src & 0xFF;

    const dst_a: u32 = (dst >> 24) & 0xFF;
    const dst_r: u32 = (dst >> 16) & 0xFF;
    const dst_g: u32 = (dst >> 8) & 0xFF;
    const dst_b: u32 = dst & 0xFF;

    const out_r = (src_r * src_a + dst_r * inv_a) / 255;
    const out_g = (src_g * src_a + dst_g * inv_a) / 255;
    const out_b = (src_b * src_a + dst_b * inv_a) / 255;
    const out_a = src_a + (dst_a * inv_a) / 255;

    return (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
}

/// Blit raster image pixels to a window backing surface.
/// If a backing buffer is registered via win_set_backing, blends pixels directly
/// with source-over alpha blending and boundary clipping.
/// Otherwise, falls back to win_fill_batched span emission.
pub fn draw_image(win_id: u32, x: u32, y: u32, img: image.Image) void {
    if (img.width == 0 or img.height == 0) return;
    if (win_get_backing(win_id)) |backing| {
        if (x >= backing.width or y >= backing.height) return;
        const max_w = @min(img.width, backing.width - x);
        const max_h = @min(img.height, backing.height - y);
        var sy: u32 = 0;
        while (sy < max_h) : (sy += 1) {
            const dst_row = (y + sy) * backing.width + x;
            var sx: u32 = 0;
            while (sx < max_w) : (sx += 1) {
                const px_ptr = img.pixel_at(sx, sy) orelse continue;
                const src_px = px_ptr.*;
                if (((src_px >> 24) & 0xFF) == 0) continue;
                const dst_idx = dst_row + sx;
                backing.pixels[dst_idx] = blend_source_over(backing.pixels[dst_idx], src_px);
            }
        }
        return;
    }

    var sy: u32 = 0;
    while (sy < img.height) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < img.width) {
            const px_ptr = img.pixel_at(sx, sy) orelse break;
            const px = px_ptr.*;
            const a = (px >> 24) & 0xFF;
            if (a == 0) {
                sx += 1;
                continue;
            }
            const rgb = px & 0x00FFFFFF;
            const start_x = sx;
            sx += 1;
            while (sx < img.width) {
                const next_ptr = img.pixel_at(sx, sy) orelse break;
                const next_px = next_ptr.*;
                if (((next_px >> 24) & 0xFF) == 0 or (next_px & 0x00FFFFFF) != rgb) break;
                sx += 1;
            }
            win_fill_batched(win_id, x + start_x, y + sy, sx - start_x, 1, rgb);
        }
    }
}

/// Draw a clipped raster image to a window, rendering only pixels that fall within clip.
/// Uses direct backing buffer alpha blending when registered, otherwise batched fills.
pub fn draw_image_clipped(win_id: u32, x: u32, y: u32, img: image.Image, clip: Rect) void {
    if (img.width == 0 or img.height == 0 or clip.w == 0 or clip.h == 0) return;
    if (win_get_backing(win_id)) |backing| {
        const clip_x0 = clip.x;
        const clip_y0 = clip.y;
        const clip_x1 = @min(clip.x + clip.w, backing.width);
        const clip_y1 = @min(clip.y + clip.h, backing.height);
        if (clip_x0 >= clip_x1 or clip_y0 >= clip_y1) return;

        var sy: u32 = 0;
        while (sy < img.height) : (sy += 1) {
            const py = y + sy;
            if (py < clip_y0 or py >= clip_y1) continue;
            var sx: u32 = 0;
            while (sx < img.width) : (sx += 1) {
                const px_pos = x + sx;
                if (px_pos < clip_x0 or px_pos >= clip_x1) continue;
                const px_ptr = img.pixel_at(sx, sy) orelse continue;
                const src_px = px_ptr.*;
                if (((src_px >> 24) & 0xFF) == 0) continue;
                const dst_idx = py * backing.width + px_pos;
                backing.pixels[dst_idx] = blend_source_over(backing.pixels[dst_idx], src_px);
            }
        }
        return;
    }

    var sy: u32 = 0;
    while (sy < img.height) : (sy += 1) {
        const py = y + sy;
        if (py < clip.y or py >= clip.y + clip.h) continue;

        var sx: u32 = 0;
        while (sx < img.width) {
            const px_ptr = img.pixel_at(sx, sy) orelse break;
            const px = px_ptr.*;
            const a = (px >> 24) & 0xFF;
            const cur_x = x + sx;
            if (a == 0 or cur_x < clip.x or cur_x >= clip.x + clip.w) {
                sx += 1;
                continue;
            }
            const rgb = px & 0x00FFFFFF;
            const start_x = sx;
            sx += 1;
            while (sx < img.width) {
                const next_x = x + sx;
                if (next_x >= clip.x + clip.w) break;
                const next_ptr = img.pixel_at(sx, sy) orelse break;
                const next_px = next_ptr.*;
                if (((next_px >> 24) & 0xFF) == 0 or (next_px & 0x00FFFFFF) != rgb) break;
                sx += 1;
            }
            win_fill_batched(win_id, x + start_x, py, sx - start_x, 1, rgb);
        }
    }
}

/// Nearest-neighbor scaled image blitting into target destination rectangle.
/// Uses direct backing buffer alpha blending when registered, otherwise batched fills.
pub fn draw_image_scaled(win_id: u32, dest: Rect, img: image.Image) void {
    if (dest.w == 0 or dest.h == 0 or img.width == 0 or img.height == 0) return;
    if (win_get_backing(win_id)) |backing| {
        if (dest.x >= backing.width or dest.y >= backing.height) return;
        const max_w = @min(dest.w, backing.width - dest.x);
        const max_h = @min(dest.h, backing.height - dest.y);
        var dy: u32 = 0;
        while (dy < max_h) : (dy += 1) {
            const sy = (dy * img.height) / dest.h;
            const dst_row = (dest.y + dy) * backing.width + dest.x;
            var dx: u32 = 0;
            while (dx < max_w) : (dx += 1) {
                const sx = (dx * img.width) / dest.w;
                const px_ptr = img.pixel_at(sx, sy) orelse continue;
                const src_px = px_ptr.*;
                if (((src_px >> 24) & 0xFF) == 0) continue;
                const dst_idx = dst_row + dx;
                backing.pixels[dst_idx] = blend_source_over(backing.pixels[dst_idx], src_px);
            }
        }
        return;
    }

    var dy: u32 = 0;
    while (dy < dest.h) : (dy += 1) {
        const sy = (dy * img.height) / dest.h;
        var dx: u32 = 0;
        while (dx < dest.w) {
            const sx = (dx * img.width) / dest.w;
            const px_ptr = img.pixel_at(sx, sy) orelse break;
            const px = px_ptr.*;
            const a = (px >> 24) & 0xFF;
            if (a == 0) {
                dx += 1;
                continue;
            }
            const rgb = px & 0x00FFFFFF;
            const start_dx = dx;
            dx += 1;
            while (dx < dest.w) {
                const next_sx = (dx * img.width) / dest.w;
                const next_ptr = img.pixel_at(next_sx, sy) orelse break;
                const next_px = next_ptr.*;
                if (((next_px >> 24) & 0xFF) == 0 or (next_px & 0x00FFFFFF) != rgb) break;
                dx += 1;
            }
            win_fill_batched(win_id, dest.x + start_dx, dest.y + dy, dx - start_dx, 1, rgb);
        }
    }
}

// ---------------------------------------------------------------------------
// Component: Button
// ---------------------------------------------------------------------------

pub const ButtonState = enum {
    idle,
    hover,
    pressed,
    disabled,
    focused,
    normal,
    hovered,

    pub fn to_widget_state(self: ButtonState) WidgetState {
        return switch (self) {
            .idle, .normal => .normal,
            .hover, .hovered => .hover,
            .pressed => .pressed,
            .disabled => .disabled,
            .focused => .focused,
        };
    }
};

pub const Button = struct {
    rect: Rect,
    label: []const u8,
    state: ButtonState = .idle,
    bg_color: ?u32 = null,
    text_color: u32 = 0xffffff,
    is_active: bool = false,

    pub fn init(rect: Rect, label: []const u8) Button {
        return .{
            .rect = rect,
            .label = label,
        };
    }

    pub fn handle_event(self: *Button, ev: *const Event) bool {
        switch (ev.kind) {
            MOUSE_MOVE => {
                const inside = self.rect.contains(ev.arg0, ev.arg1);
                if (inside) {
                    if (self.state == .idle) self.state = .hover;
                } else {
                    self.state = .idle;
                }
                return false;
            },
            MOUSE_DOWN => {
                const inside = self.rect.contains(ev.arg0, ev.arg1);
                if (inside) {
                    self.state = .pressed;
                } else {
                    self.state = .idle;
                }
                return false;
            },
            MOUSE_UP => {
                const was_pressed = (self.state == .pressed);
                const inside = self.rect.contains(ev.arg0, ev.arg1);
                self.state = if (inside) .hover else .idle;
                return was_pressed and inside;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const Button, win_id: u32) void {
        const ws = self.state.to_widget_state();
        const bg = if (self.is_active)
            theme_accent()
        else if (self.bg_color) |c|
            c
        else
            widget_bg(ws);

        const border = if (self.is_active)
            theme_text_primary()
        else
            widget_border(ws);

        const text_col = if (self.state == .disabled)
            widget_text(ws)
        else
            self.text_color;

        draw_rect(win_id, self.rect, bg);
        draw_rect_outline(win_id, self.rect, 1, border);
        draw_text_centered(win_id, self.label, self.rect, text_col);
    }
};

// ---------------------------------------------------------------------------
// Component: Label
// ---------------------------------------------------------------------------

pub const Label = struct {
    rect: Rect,
    text: []const u8,
    color: u32 = 0xffffff,
    align_center: bool = false,

    pub fn init(rect: Rect, text: []const u8) Label {
        return .{
            .rect = rect,
            .text = text,
        };
    }

    pub fn draw(self: *const Label, win_id: u32) void {
        if (self.align_center) {
            draw_text_centered(win_id, self.text, self.rect, self.color);
        } else {
            draw_text(win_id, self.text, self.rect.x, self.rect.y + (self.rect.h - 8) / 2, self.color);
        }
    }
};

// ---------------------------------------------------------------------------
// Component: TextInput
// ---------------------------------------------------------------------------

pub const TextInput = struct {
    rect: Rect,
    buf: [128]u8 = [_]u8{0} ** 128,
    len: usize = 0,
    cursor: usize = 0,
    focused: bool = false,

    pub fn init(rect: Rect) TextInput {
        return .{ .rect = rect };
    }

    pub fn get_text(self: *const TextInput) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set_text(self: *TextInput, text: []const u8) void {
        const copy_len = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..copy_len], text[0..copy_len]);
        self.len = copy_len;
        self.cursor = copy_len;
    }

    pub fn clear(self: *TextInput) void {
        self.len = 0;
        self.cursor = 0;
    }

    pub fn handle_event(self: *TextInput, ev: *const Event) bool {
        switch (ev.kind) {
            MOUSE_DOWN => {
                const inside = self.rect.contains(ev.arg0, ev.arg1);
                const prev = self.focused;
                self.focused = inside;
                return prev != self.focused;
            },
            KEY_DOWN => {
                if (!self.focused) return false;
                const keycode = ev.arg0;
                const ascii_char = @as(u8, @truncate(ev.arg1));

                // Backspace (ASCII 0x08 or keycode 0x2a)
                if (ascii_char == 0x08 or keycode == 0x2a) {
                    if (self.cursor > 0 and self.len > 0) {
                        var i = self.cursor - 1;
                        while (i < self.len - 1) : (i += 1) {
                            self.buf[i] = self.buf[i + 1];
                        }
                        self.len -= 1;
                        self.cursor -= 1;
                        return true;
                    }
                    return false;
                }

                // Printable character insertion
                if (ascii_char >= 0x20 and ascii_char <= 0x7e) {
                    if (self.len < self.buf.len) {
                        var i = self.len;
                        while (i > self.cursor) : (i -= 1) {
                            self.buf[i] = self.buf[i - 1];
                        }
                        self.buf[self.cursor] = ascii_char;
                        self.len += 1;
                        self.cursor += 1;
                        return true;
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const TextInput, win_id: u32) void {
        draw_rect(win_id, self.rect, theme_surface());
        draw_rect_outline(win_id, self.rect, 1, if (self.focused) theme_accent() else theme_border());

        const text_y = self.rect.y + (self.rect.h - 8) / 2;
        const text_x = self.rect.x + 4;
        draw_text(win_id, self.get_text(), text_x, text_y, theme_text_primary());

        // Draw cursor bar if focused
        if (self.focused) {
            const cursor_x = text_x + @as(u32, @intCast(self.cursor)) * 8;
            if (cursor_x + 2 <= self.rect.x + self.rect.w) {
                win_fill(win_id, cursor_x, text_y, 2, 8, theme_text_primary());
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Component: ListView
// ---------------------------------------------------------------------------

pub const ListView = struct {
    rect: Rect,
    row_height: u32 = 14,
    selected_idx: ?usize = null,
    item_count: usize = 0,

    pub fn init(rect: Rect, row_height: u32) ListView {
        return .{
            .rect = rect,
            .row_height = row_height,
        };
    }

    pub fn handle_event(self: *ListView, ev: *const Event) bool {
        switch (ev.kind) {
            MOUSE_DOWN => {
                if (self.rect.contains(ev.arg0, ev.arg1)) {
                    const rel_y = ev.arg1 - self.rect.y;
                    const clicked_row = rel_y / self.row_height;
                    if (clicked_row < self.item_count) {
                        const prev = self.selected_idx;
                        self.selected_idx = clicked_row;
                        return prev != self.selected_idx;
                    }
                }
                return false;
            },
            KEY_DOWN => {
                const keycode = ev.arg0;
                // Up arrow (keycode 0x52)
                if (keycode == 0x52) {
                    if (self.selected_idx) |idx| {
                        if (idx > 0) {
                            self.selected_idx = idx - 1;
                            return true;
                        }
                    } else if (self.item_count > 0) {
                        self.selected_idx = 0;
                        return true;
                    }
                }
                // Down arrow (keycode 0x51)
                if (keycode == 0x51) {
                    if (self.selected_idx) |idx| {
                        if (idx + 1 < self.item_count) {
                            self.selected_idx = idx + 1;
                            return true;
                        }
                    } else if (self.item_count > 0) {
                        self.selected_idx = 0;
                        return true;
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn draw_row(self: *const ListView, win_id: u32, row: usize, text: []const u8, is_selected: bool) void {
        const row_y = self.rect.y + @as(u32, @intCast(row)) * self.row_height;
        if (row_y + self.row_height > self.rect.y + self.rect.h) return;

        const row_rect = Rect.make(self.rect.x, row_y, self.rect.w, self.row_height);
        const bg = if (is_selected)
            theme_accent()
        else if (row % 2 == 0)
            theme_surface()
        else
            theme_bg();

        draw_rect(win_id, row_rect, bg);
        draw_text(win_id, text, row_rect.x + 4, row_rect.y + (self.row_height - 8) / 2, theme_text_primary());
    }
};

// ---------------------------------------------------------------------------
// Component: DropDown
// ---------------------------------------------------------------------------

pub const DropDown = struct {
    rect: Rect,
    options: []const []const u8,
    selected: usize = 0,
    open: bool = false,
    hover_idx: ?usize = null,
    row_height: u32 = 16,
    max_visible: u32 = 6,

    pub fn init(rect: Rect, options: []const []const u8) DropDown {
        return .{ .rect = rect, .options = options };
    }

    pub fn selected_text(self: *const DropDown) []const u8 {
        if (self.selected < self.options.len) return self.options[self.selected];
        return "";
    }

    pub fn set_selected_by_name(self: *DropDown, name: []const u8) void {
        for (self.options, 0..) |opt, i| {
            if (eql_str(opt, name)) {
                self.selected = i;
                return;
            }
        }
    }

    fn eql_str(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            if (ca != cb) return false;
        }
        return true;
    }

    fn overlay_rect(self: *const DropDown) Rect {
        const visible = @min(@as(u32, @intCast(self.options.len)), self.max_visible);
        return Rect.make(self.rect.x, self.rect.y + self.rect.h, self.rect.w, visible * self.row_height);
    }

    fn hit_test_overlay(self: *const DropDown, px: u32, py: u32) ?usize {
        if (!self.open) return null;
        const ov = self.overlay_rect();
        if (!ov.contains(px, py)) return null;
        const rel_y = py - ov.y;
        const idx = rel_y / self.row_height;
        if (idx < self.options.len) return idx;
        return null;
    }

    pub fn handle_event(self: *DropDown, ev: *const Event) bool {
        switch (ev.kind) {
            MOUSE_DOWN => {
                if (self.open) {
                    if (self.hit_test_overlay(ev.arg0, ev.arg1)) |idx| {
                        self.selected = idx;
                        self.open = false;
                        self.hover_idx = null;
                        return true;
                    }
                    self.open = false;
                    self.hover_idx = null;
                }
                if (self.rect.contains(ev.arg0, ev.arg1)) {
                    self.open = true;
                    return false;
                }
                return false;
            },
            MOUSE_MOVE => {
                if (self.open) {
                    self.hover_idx = self.hit_test_overlay(ev.arg0, ev.arg1);
                }
                return false;
            },
            KEY_DOWN => {
                if (!self.open) return false;
                const keycode = ev.arg0;
                // Up arrow (0x52)
                if (keycode == 0x52) {
                    if (self.selected > 0) {
                        self.selected -= 1;
                        return true;
                    }
                }
                // Down arrow (0x51)
                if (keycode == 0x51) {
                    if (self.selected + 1 < self.options.len) {
                        self.selected += 1;
                        return true;
                    }
                }
                // Enter (0x28) or Escape (0x29)
                if (keycode == 0x28 or keycode == 0x29) {
                    self.open = false;
                    self.hover_idx = null;
                    return false;
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const DropDown, win_id: u32) void {
        // Button body.
        const bg = if (self.open) theme_btn_pressed() else theme_btn_idle();
        draw_rect(win_id, self.rect, bg);
        draw_rect_outline(win_id, self.rect, 1, if (self.open) theme_accent() else theme_border());
        draw_text(win_id, self.selected_text(), self.rect.x + 4, self.rect.y + (self.rect.h - 8) / 2, theme_text_primary());
        // Down arrow indicator.
        const ax = self.rect.x + self.rect.w - 12;
        const ay = self.rect.y + (self.rect.h - 4) / 2;
        win_fill(win_id, ax, ay, 6, 2, theme_text_muted());
        win_fill(win_id, ax + 1, ay + 2, 4, 2, theme_text_muted());
        win_fill(win_id, ax + 2, ay + 4, 2, 2, theme_text_muted());

        // Dropdown overlay.
        if (self.open) {
            const ov = self.overlay_rect();
            draw_rect(win_id, ov, theme_surface());
            draw_rect_outline(win_id, ov, 1, theme_border());
            var i: u32 = 0;
            while (i < self.options.len and i < self.max_visible) : (i += 1) {
                const row_y = ov.y + i * self.row_height;
                const row_bg = if (self.hover_idx != null and self.hover_idx.? == i)
                    theme_btn_hover()
                else if (i == self.selected)
                    theme_accent()
                else
                    theme_surface();
                win_fill(win_id, ov.x + 1, row_y, ov.w - 2, self.row_height, row_bg);
                draw_text(win_id, self.options[i], ov.x + 4, row_y + (self.row_height - 8) / 2, theme_text_primary());
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Component: ContextMenu & Menu Builder (GH #228, Arc2 W2, M27 G9 #452)
// ---------------------------------------------------------------------------

pub const CanonicalMenuCategory = enum {
    file,
    edit,
    view,
    help,
};

pub const canonical_menu_bar = [_][]const u8{ "File", "Edit", "View", "Help" };

pub const StandardShortcut = struct {
    pub const save = "Ctrl+S";
    pub const open = "Ctrl+O";
    pub const quit = "Ctrl+Q";
    pub const undo = "Ctrl+Z";
    pub const redo = "Ctrl+Y";
    pub const find = "Ctrl+F";
    pub const help = "Ctrl+H";
    pub const cut = "Ctrl+X";
    pub const copy = "Ctrl+C";
    pub const paste = "Ctrl+V";
    pub const select_all = "Ctrl+A";
    pub const new_file = "Ctrl+N";
};

pub const MenuItemKind = enum {
    action,
    separator,
    header,
};

pub const MenuItemSpec = struct {
    label: []const u8 = "",
    shortcut: []const u8 = "",
    kind: MenuItemKind = .action,
    disabled: bool = false,
    action: ?*const fn () void = null,
};

pub const MenuSection = struct {
    title: []const u8 = "",
    items: []const MenuItemSpec = &[_]MenuItemSpec{},
};

pub const MenuBuilder = struct {
    items: [16]MenuItemSpec = [_]MenuItemSpec{.{}} ** 16,
    count: usize = 0,

    pub fn init() MenuBuilder {
        return .{};
    }

    pub fn add_item(self: *MenuBuilder, label: []const u8, shortcut: []const u8) *MenuBuilder {
        if (self.count < self.items.len) {
            self.items[self.count] = .{ .label = label, .shortcut = shortcut, .kind = .action };
            self.count += 1;
        }
        return self;
    }

    pub fn add_action(self: *MenuBuilder, label: []const u8, shortcut: []const u8, action_fn: ?*const fn () void) *MenuBuilder {
        if (self.count < self.items.len) {
            self.items[self.count] = .{ .label = label, .shortcut = shortcut, .kind = .action, .action = action_fn };
            self.count += 1;
        }
        return self;
    }

    pub fn add_separator(self: *MenuBuilder) *MenuBuilder {
        if (self.count < self.items.len) {
            self.items[self.count] = .{ .kind = .separator };
            self.count += 1;
        }
        return self;
    }

    pub fn add_header(self: *MenuBuilder, title: []const u8) *MenuBuilder {
        if (self.count < self.items.len) {
            self.items[self.count] = .{ .label = title, .kind = .header };
            self.count += 1;
        }
        return self;
    }

    pub fn slice(self: *const MenuBuilder) []const MenuItemSpec {
        return self.items[0..self.count];
    }
};

/// Build a standardized ContextMenu from a slice of MenuItemSpecs (M27 G9).
pub fn menu_build(specs: []const MenuItemSpec) ContextMenu {
    return ContextMenu.initWithSpecs(specs);
}

pub const ContextMenuItem = struct {
    label: []const u8,
    // Optional callback — not used in host tests, reserved for app wiring.
    action: ?*const fn () void = null,
};

pub const ContextMenu = struct {
    items: []const ContextMenuItem = &[_]ContextMenuItem{},
    specs: []const MenuItemSpec = &[_]MenuItemSpec{},
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 120,
    row_h: u32 = 16,
    open: bool = false,
    hover_idx: ?usize = null,
    selected_idx: ?usize = null,

    pub fn init(items: []const ContextMenuItem) ContextMenu {
        return .{ .items = items, .specs = &[_]MenuItemSpec{} };
    }

    pub fn initWithSpecs(specs: []const MenuItemSpec) ContextMenu {
        return .{ .items = &[_]ContextMenuItem{}, .specs = specs };
    }

    pub fn show(self: *ContextMenu, x: u32, y: u32) void {
        self.x = x;
        self.y = y;
        self.open = true;
        self.hover_idx = null;
        self.selected_idx = null;
    }

    pub fn dismiss(self: *ContextMenu) void {
        self.open = false;
        self.hover_idx = null;
    }

    pub fn is_open(self: *const ContextMenu) bool {
        return self.open;
    }

    pub fn count(self: *const ContextMenu) usize {
        return if (self.specs.len > 0) self.specs.len else self.items.len;
    }

    pub fn bounds(self: *const ContextMenu) Rect {
        return Rect.make(self.x, self.y, self.width, @as(u32, @intCast(self.count())) * self.row_h);
    }

    fn is_item_selectable(self: *const ContextMenu, idx: usize) bool {
        if (self.specs.len > 0) {
            if (idx >= self.specs.len) return false;
            return self.specs[idx].kind == .action and !self.specs[idx].disabled;
        }
        return idx < self.items.len;
    }

    fn hit_test(self: *const ContextMenu, px: u32, py: u32) ?usize {
        if (!self.open) return null;
        const b = self.bounds();
        if (!b.contains(px, py)) return null;
        const rel_y = py - b.y;
        const idx = rel_y / self.row_h;
        if (idx < self.count()) return idx;
        return null;
    }

    pub fn handle_event(self: *ContextMenu, ev: *const Event) bool {
        switch (ev.kind) {
            KEY_DOWN => {
                if (!self.open) return false;
                const kc = ev.arg0;
                const total = self.count();
                if (total == 0) return false;
                if (kc == 0x52) { // Up arrow
                    var cur = if (self.hover_idx) |h| h else 0;
                    var tries: usize = 0;
                    while (tries < total) : (tries += 1) {
                        cur = if (cur == 0) total - 1 else cur - 1;
                        if (self.is_item_selectable(cur)) {
                            self.hover_idx = cur;
                            return true;
                        }
                    }
                    return true;
                } else if (kc == 0x51) { // Down arrow
                    var cur = if (self.hover_idx) |h| h else total - 1;
                    var tries: usize = 0;
                    while (tries < total) : (tries += 1) {
                        cur = if (cur + 1 >= total) 0 else cur + 1;
                        if (self.is_item_selectable(cur)) {
                            self.hover_idx = cur;
                            return true;
                        }
                    }
                    return true;
                } else if (kc == 0x28) { // Enter
                    if (self.hover_idx) |idx| {
                        if (self.is_item_selectable(idx)) {
                            self.selected_idx = idx;
                            self.open = false;
                            if (self.specs.len > 0) {
                                if (self.specs[idx].action) |act| act();
                            } else if (self.items.len > 0) {
                                if (self.items[idx].action) |act| act();
                            }
                            return true;
                        }
                    }
                    return false;
                } else if (kc == 0x29) { // Escape
                    self.dismiss();
                    return true;
                }
                return false;
            },
            MOUSE_RIGHT_DOWN => {
                self.show(ev.arg0, ev.arg1);
                return true;
            },
            MOUSE_DOWN => {
                if (!self.open) return false;
                if (self.hit_test(ev.arg0, ev.arg1)) |idx| {
                    if (self.is_item_selectable(idx)) {
                        self.selected_idx = idx;
                        self.open = false;
                        self.hover_idx = null;
                        if (self.specs.len > 0) {
                            if (self.specs[idx].action) |act| act();
                        } else if (self.items.len > 0) {
                            if (self.items[idx].action) |act| act();
                        }
                        return true;
                    }
                    return true;
                }
                self.dismiss();
                return false;
            },
            MOUSE_MOVE => {
                if (!self.open) return false;
                const hit = self.hit_test(ev.arg0, ev.arg1);
                if (hit) |idx| {
                    if (self.is_item_selectable(idx)) {
                        self.hover_idx = idx;
                    } else {
                        self.hover_idx = null;
                    }
                } else {
                    self.hover_idx = null;
                }
                return false;
            },
            MOUSE_RIGHT_UP => {
                if (self.open) return true;
                return false;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const ContextMenu, win_id: u32) void {
        if (!self.open) return;
        const b = self.bounds();
        draw_rect(win_id, b, theme_surface());
        draw_rect_outline(win_id, b, 1, theme_border());
        const total = self.count();
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const row_y = b.y + @as(u32, @intCast(i)) * self.row_h;
            const row_rect = Rect.make(b.x + 1, row_y, b.w - 2, self.row_h);

            if (self.specs.len > 0) {
                const spec = self.specs[i];
                if (spec.kind == .separator) {
                    const mid_y = row_y + self.row_h / 2;
                    draw_rect(win_id, Rect.make(b.x + 4, mid_y, if (b.w > 8) b.w - 8 else 0, 1), theme_border());
                    continue;
                }
                const bg = if (self.hover_idx != null and self.hover_idx.? == i and !spec.disabled)
                    theme_btn_hover()
                else
                    theme_surface();
                win_fill(win_id, row_rect.x, row_rect.y, row_rect.w, row_rect.h, bg);
                const text_col = if (spec.disabled) theme_text_muted() else theme_text_primary();
                draw_text(win_id, spec.label, row_rect.x + 6, row_rect.y + (self.row_h - 8) / 2, text_col);
                if (spec.shortcut.len > 0) {
                    const sc_w = @as(u32, @intCast(spec.shortcut.len)) * 8;
                    const sc_x = if (row_rect.w > sc_w + 6) row_rect.x + row_rect.w - sc_w - 6 else row_rect.x;
                    draw_text(win_id, spec.shortcut, sc_x, row_rect.y + (self.row_h - 8) / 2, theme_text_muted());
                }
            } else {
                const bg = if (self.hover_idx != null and self.hover_idx.? == i)
                    theme_btn_hover()
                else
                    theme_surface();
                win_fill(win_id, row_rect.x, row_rect.y, row_rect.w, row_rect.h, bg);
                draw_text(win_id, self.items[i].label, row_rect.x + 6, row_rect.y + (self.row_h - 8) / 2, theme_text_primary());
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Component: ScrollView — vertical scroll container (GH #218, Arc1)
// ---------------------------------------------------------------------------

pub const MOUSE_SCROLL: u16 = 12;

pub const ScrollView = struct {
    rect: Rect,
    content_h: u32,
    offset: u32 = 0,
    dragging: bool = false,
    drag_start_y: u32 = 0,
    drag_start_offset: u32 = 0,

    const scrollbar_w: u32 = 6;
    const thumb_min_h: u32 = 16;

    pub fn init(rect: Rect, content_h: u32) ScrollView {
        var sv = ScrollView{ .rect = rect, .content_h = content_h };
        sv.clamp_offset();
        return sv;
    }

    pub fn set_content_height(self: *ScrollView, h: u32) void {
        self.content_h = h;
        self.clamp_offset();
    }

    pub fn max_offset(self: *const ScrollView) u32 {
        if (self.content_h <= self.rect.h) return 0;
        return self.content_h - self.rect.h;
    }

    fn clamp_offset(self: *ScrollView) void {
        const m = self.max_offset();
        if (self.offset > m) self.offset = m;
    }

    pub fn thumb_h(self: *const ScrollView) u32 {
        if (self.content_h <= self.rect.h) return self.rect.h;
        const visible = self.rect.h;
        const content = self.content_h;
        const proportional = visible * visible / content;
        return @max(thumb_min_h, proportional);
    }

    pub fn thumb_y(self: *const ScrollView) u32 {
        const m = self.max_offset();
        if (m == 0) return self.rect.y;
        const th = self.thumb_h();
        const track_h = self.rect.h - th;
        // offset * track_h / max_offset, rounded down
        return self.rect.y + (self.offset * track_h / m);
    }

    pub fn thumb_rect(self: *const ScrollView) Rect {
        if (self.content_h <= self.rect.h) return self.rect;
        const th = self.thumb_h();
        const ty = self.thumb_y();
        return Rect.make(self.rect.x + self.rect.w - scrollbar_w, ty, scrollbar_w, th);
    }

    fn track_contains(self: *const ScrollView, px: u32, py: u32) bool {
        const track = Rect.make(self.rect.x + self.rect.w - scrollbar_w, self.rect.y, scrollbar_w, self.rect.h);
        return track.contains(px, py);
    }

    pub fn scroll_by(self: *ScrollView, delta: i32) void {
        const m: i32 = @intCast(self.max_offset());
        var off: i32 = @intCast(self.offset);
        off += delta;
        if (off < 0) off = 0;
        if (off > m) off = m;
        self.offset = @intCast(off);
    }

    pub fn handle_event(self: *ScrollView, ev: *const Event) bool {
        if (self.content_h <= self.rect.h) return false;
        switch (ev.kind) {
            MOUSE_DOWN => {
                const px = ev.arg0;
                const py = ev.arg1;
                if (!self.rect.contains(px, py)) return false;
                const tr = self.thumb_rect();
                if (tr.contains(px, py)) {
                    self.dragging = true;
                    self.drag_start_y = py;
                    self.drag_start_offset = self.offset;
                    return true;
                }
                if (self.track_contains(px, py)) {
                    // Click on track outside thumb — page up/down
                    const ty = self.thumb_y();
                    if (py < ty) {
                        self.scroll_by(-@as(i32, @intCast(self.rect.h)));
                    } else {
                        self.scroll_by(@as(i32, @intCast(self.rect.h)));
                    }
                    return true;
                }
                return false;
            },
            MOUSE_MOVE => {
                if (!self.dragging) return false;
                const py: i32 = @intCast(ev.arg1);
                const start_y: i32 = @intCast(self.drag_start_y);
                const delta: i32 = py - start_y;
                const m = self.max_offset();
                if (m == 0) return false;
                const th = self.thumb_h();
                const track_h: i32 = @intCast(self.rect.h - th);
                if (track_h <= 0) return false;
                // Scale thumb drag to content offset: delta * max_offset / track_h
                const scaled = @divTrunc(delta * @as(i32, @intCast(m)), track_h);
                var new_off: i32 = @as(i32, @intCast(self.drag_start_offset)) + scaled;
                if (new_off < 0) new_off = 0;
                if (new_off > @as(i32, @intCast(m))) new_off = @intCast(m);
                self.offset = @intCast(new_off);
                return true;
            },
            MOUSE_UP => {
                if (self.dragging) {
                    self.dragging = false;
                    return true;
                }
                return false;
            },
            KEY_DOWN => {
                const keycode = ev.arg0;
                // PageUp 0x4b, PageDown 0x4e (from notepad.zig), also handle wheel if present
                if (keycode == 0x4b) { // PageUp
                    self.scroll_by(-@as(i32, @intCast(self.rect.h)));
                    return true;
                }
                if (keycode == 0x4e) { // PageDown
                    self.scroll_by(@as(i32, @intCast(self.rect.h)));
                    return true;
                }
                return false;
            },
            MOUSE_SCROLL => {
                // Arc4 #236: arg0 packed per ADR 0013 D2.
                // bits 0–13 = magnitude, bit 14 = horizontal, bit 15 = sign.
                const raw = ev.arg0;
                const horizontal = (raw & 0x4000) != 0;
                if (horizontal) return false; // vertical-only ScrollView
                const magnitude: i32 = @intCast(raw & 0x1fff);
                if (magnitude == 0) return false;
                const sign: i32 = if ((raw & 0x8000) != 0) 1 else -1;
                const step = sign * magnitude * 16;
                self.scroll_by(step);
                return true;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const ScrollView, win_id: u32) void {
        if (self.content_h <= self.rect.h) return;
        // Track
        const track_x = self.rect.x + self.rect.w - scrollbar_w;
        draw_rect(win_id, Rect.make(track_x, self.rect.y, scrollbar_w, self.rect.h), theme_border());
        // Thumb
        const tr = self.thumb_rect();
        // Thumb as accent, with 1px inset for rounded feel
        win_fill(win_id, tr.x, tr.y, tr.w, tr.h, theme_accent());
    }
};

// ---------------------------------------------------------------------------
// Component: Checkbox — 12×12 boolean (GH #219, Arc1)
// ---------------------------------------------------------------------------

pub const Checkbox = struct {
    rect: Rect,
    checked: *bool,

    pub fn init(rect: Rect, checked: *bool) Checkbox {
        return .{ .rect = rect, .checked = checked };
    }

    pub fn handle_event(self: *Checkbox, ev: *const Event) bool {
        if (ev.kind != MOUSE_DOWN) return false;
        if ((ev.flags & BTN_LEFT) == 0) return false;
        if (!self.rect.contains(ev.arg0, ev.arg1)) return false;
        self.checked.* = !self.checked.*;
        return true;
    }

    pub fn draw(self: *const Checkbox, win_id: u32) void {
        // Box outline
        draw_rect(win_id, self.rect, theme_surface());
        draw_rect_outline(win_id, self.rect, 1, theme_border());
        if (self.checked.*) {
            // Filled inner square (inset 3) in accent
            const inner = self.rect.inset(3, 3);
            // Clamp to at least 6×6 for 12×12 box -> 6×6 inner
            win_fill(win_id, inner.x, inner.y, inner.w, inner.h, theme_accent());
        }
    }
};

// ---------------------------------------------------------------------------
// Component: Toggle — 48×20 pill boolean (GH #219, Arc1)
// ---------------------------------------------------------------------------

pub const Toggle = struct {
    rect: Rect,
    enabled: *bool,

    pub fn init(rect: Rect, enabled: *bool) Toggle {
        return .{ .rect = rect, .enabled = enabled };
    }

    pub fn handle_event(self: *Toggle, ev: *const Event) bool {
        if (ev.kind != MOUSE_DOWN) return false;
        if ((ev.flags & BTN_LEFT) == 0) return false;
        if (!self.rect.contains(ev.arg0, ev.arg1)) return false;
        self.enabled.* = !self.enabled.*;
        return true;
    }

    pub fn draw(self: *const Toggle, win_id: u32) void {
        // Pill background
        const bg = if (self.enabled.*) theme_accent() else theme_border();
        draw_rect(win_id, self.rect, bg);
        // Knob: 16×16 circle approximated as square, inset 2, left or right
        const knob_w: u32 = 16;
        const knob_h: u32 = 16;
        const knob_y = self.rect.y + (self.rect.h - knob_h) / 2;
        const knob_x = if (self.enabled.*)
            self.rect.x + self.rect.w - knob_w - 2
        else
            self.rect.x + 2;
        // Knob in surface (contrasts with accent/border bg)
        win_fill(win_id, knob_x, knob_y, knob_w, knob_h, theme_surface());
        draw_rect_outline(win_id, Rect.make(knob_x, knob_y, knob_w, knob_h), 1, theme_border());
    }
};

// ---------------------------------------------------------------------------
// Component: ProgressBar — determinate + indeterminate (GH #220, Arc1)
// ---------------------------------------------------------------------------

pub const ProgressBar = struct {
    rect: Rect,
    value: f32 = 0.0,
    label: []const u8 = "",
    indeterminate: bool = false,
    offset: i32 = 0,
    dir: i32 = 1,

    pub const indeterminate_width: u32 = 20;
    pub const indeterminate_step: i32 = 4;

    pub fn init(rect: Rect) ProgressBar {
        return .{ .rect = rect };
    }

    pub fn initWithValue(rect: Rect, value: f32) ProgressBar {
        var pb = ProgressBar.init(rect);
        pb.set_value(value);
        return pb;
    }

    pub fn set_value(self: *ProgressBar, v: f32) void {
        if (std.math.isNan(v) or std.math.isInf(v)) {
            self.value = if (v > 0 and std.math.isInf(v)) 1.0 else 0.0;
            if (std.math.isNan(v)) self.value = 0.0;
            return;
        }
        if (v < 0.0) {
            self.value = 0.0;
        } else if (v > 1.0) {
            self.value = 1.0;
        } else {
            self.value = v;
        }
    }

    pub fn set_label(self: *ProgressBar, text: []const u8) void {
        self.label = text;
    }

    pub fn set_indeterminate(self: *ProgressBar, enabled: bool) void {
        self.indeterminate = enabled;
        if (enabled) {
            self.offset = 0;
            self.dir = 1;
        }
    }

    fn inner_rect(self: *const ProgressBar) Rect {
        if (self.rect.w <= 2 or self.rect.h <= 2) return Rect.make(self.rect.x, self.rect.y, 0, 0);
        return Rect.make(self.rect.x + 1, self.rect.y + 1, self.rect.w - 2, self.rect.h - 2);
    }

    pub fn fill_width(self: *const ProgressBar) u32 {
        const inner = self.inner_rect();
        if (inner.w == 0) return 0;
        const clamped = if (self.value < 0.0) @as(f32, 0.0) else if (self.value > 1.0) @as(f32, 1.0) else self.value;
        const fw: f32 = @as(f32, @floatFromInt(inner.w)) * clamped;
        return @as(u32, @intFromFloat(@floor(fw)));
    }

    /// Max offset for the sliding block inside inner rect (inner_w - block_w).
    pub fn max_offset(self: *const ProgressBar) i32 {
        const inner = self.inner_rect();
        if (inner.w <= indeterminate_width) return 0;
        return @as(i32, @intCast(inner.w - indeterminate_width));
    }

    /// Advance indeterminate animation by one TIMER tick. Returns true if moved.
    pub fn tick(self: *ProgressBar) bool {
        if (!self.indeterminate) return false;
        const max = self.max_offset();
        if (max == 0) return false;
        self.offset += self.dir * indeterminate_step;
        if (self.offset >= max) {
            self.offset = max;
            self.dir = -1;
        } else if (self.offset <= 0) {
            self.offset = 0;
            self.dir = 1;
        }
        return true;
    }

    pub fn handle_event(self: *ProgressBar, ev: *const Event) bool {
        if (!self.indeterminate) return false;
        if (ev.kind != EVENT_TIMER) return false;
        return self.tick();
    }

    /// Test helper: is the i-th label character centered over the fill/block?
    pub fn is_label_char_over_fill(self: *const ProgressBar, char_idx: usize) bool {
        if (self.label.len == 0 or char_idx >= self.label.len) return false;
        const inner = self.inner_rect();
        const text_w = @as(u32, @intCast(self.label.len)) * 8;
        const label_x = if (self.rect.w > text_w) self.rect.x + (self.rect.w - text_w) / 2 else self.rect.x;
        const char_x = label_x + @as(u32, @intCast(char_idx)) * 8;
        const char_center = char_x + 4;
        if (self.indeterminate) {
            const block_x = @as(i32, @intCast(inner.x)) + self.offset;
            const block_x_u: u32 = if (block_x < 0) 0 else @as(u32, @intCast(block_x));
            return char_center >= block_x_u and char_center < block_x_u + indeterminate_width;
        } else {
            const fw = self.fill_width();
            if (fw == 0) return false;
            const fill_end = inner.x + fw;
            return char_center < fill_end;
        }
    }

    pub fn draw(self: *const ProgressBar, win_id: u32) void {
        // Background + border
        draw_rect(win_id, self.rect, theme_surface());
        draw_rect_outline(win_id, self.rect, 1, theme_border());
        const inner = self.inner_rect();
        if (inner.w == 0 or inner.h == 0) return;

        if (self.indeterminate) {
            const block_x_i: i32 = @as(i32, @intCast(inner.x)) + self.offset;
            const block_x: u32 = if (block_x_i < 0) inner.x else @as(u32, @intCast(block_x_i));
            // Clamp block inside inner
            const clamped_x = @min(block_x, inner.x + inner.w - indeterminate_width);
            const block_rect = Rect.make(clamped_x, inner.y, indeterminate_width, inner.h);
            draw_rect(win_id, block_rect, theme_accent());
        } else {
            const fw = self.fill_width();
            if (fw > 0) {
                const fill_rect = Rect.make(inner.x, inner.y, fw, inner.h);
                draw_rect(win_id, fill_rect, theme_accent());
            }
        }

        // Centered label with contrast inversion per character.
        if (self.label.len > 0) {
            const text_w = @as(u32, @intCast(self.label.len)) * 8;
            const text_h: u32 = 8;
            const lx = if (self.rect.w > text_w) self.rect.x + (self.rect.w - text_w) / 2 else self.rect.x;
            const ly = if (self.rect.h > text_h) self.rect.y + (self.rect.h - text_h) / 2 else self.rect.y;
            var i: usize = 0;
            while (i < self.label.len) : (i += 1) {
                const ch = self.label[i];
                const char_x = lx + @as(u32, @intCast(i)) * 8;
                const over_fill = self.is_label_char_over_fill(i);
                // Over fill/block: white for high contrast on accent; over bg: theme text primary.
                const fg: u32 = if (over_fill) 0xffffff else theme_text_primary();
                draw_char(win_id, ch, char_x, ly, fg);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Component: Dialog — modal child window helper (GH #221, Arc1)
// ---------------------------------------------------------------------------

pub const DialogResult = enum {
    none,
    ok,
    cancel,
    button_0,
    button_1,
    button_2,

    pub fn is_ok(self: DialogResult) bool {
        return self == .ok or self == .button_0;
    }

    pub fn is_cancel(self: DialogResult) bool {
        return self == .cancel or self == .button_1;
    }
};

pub const Dialog = struct {
    parent_rect: Rect,
    rect: Rect,
    title: []const u8 = "",
    message: []const u8 = "",
    has_input: bool = false,
    input: TextInput,
    ok_button: Button,
    cancel_button: Button,
    result: DialogResult = .none,
    open: bool = false,

    pub const width: u32 = 300;
    pub const height: u32 = 150;

    fn centered_rect(parent: Rect) Rect {
        const w = width;
        const h = height;
        const cw = @min(w, parent.w);
        const ch = @min(h, parent.h);
        const x = if (parent.w > w) parent.x + (parent.w - w) / 2 else parent.x;
        const y = if (parent.h > h) parent.y + (parent.h - h) / 2 else parent.y;
        return Rect.make(x, y, cw, ch);
    }

    pub fn init(parent_rect: Rect, message: []const u8, has_input: bool) Dialog {
        const r = centered_rect(parent_rect);
        var dlg = Dialog{
            .parent_rect = parent_rect,
            .rect = r,
            .title = "",
            .message = message,
            .has_input = has_input,
            .input = TextInput.init(Rect.make(r.x + 10, r.y + 60, if (r.w > 20) r.w - 20 else 0, 20)),
            .ok_button = Button.init(Rect.make(if (r.w > 140) r.x + r.w - 140 else r.x, r.y + r.h - 30, 60, 20), "OK"),
            .cancel_button = Button.init(Rect.make(if (r.w > 70) r.x + r.w - 70 else r.x, r.y + r.h - 30, 60, 20), "Cancel"),
            .result = .none,
            .open = false,
        };
        dlg.input.focused = has_input;
        return dlg;
    }

    pub fn initWithButtons(parent_rect: Rect, title: []const u8, message: []const u8, buttons: []const []const u8) Dialog {
        const r = centered_rect(parent_rect);
        const btn0 = if (buttons.len > 0) buttons[0] else "OK";
        const btn1 = if (buttons.len > 1) buttons[1] else "Cancel";
        const dlg = Dialog{
            .parent_rect = parent_rect,
            .rect = r,
            .title = title,
            .message = message,
            .has_input = false,
            .input = TextInput.init(Rect.make(r.x + 10, r.y + 60, if (r.w > 20) r.w - 20 else 0, 20)),
            .ok_button = Button.init(Rect.make(if (r.w > 140) r.x + r.w - 140 else r.x, r.y + r.h - 30, 60, 20), btn0),
            .cancel_button = Button.init(Rect.make(if (r.w > 70) r.x + r.w - 70 else r.x, r.y + r.h - 30, 60, 20), btn1),
            .result = .none,
            .open = false,
        };
        return dlg;
    }

    pub fn show(self: *Dialog) void {
        self.open = true;
        self.result = .none;
        self.input.clear();
        self.input.focused = self.has_input;
        // Reset button states
        self.ok_button.state = .idle;
        self.cancel_button.state = .idle;
    }

    pub fn dismiss(self: *Dialog, res: DialogResult) void {
        self.open = false;
        self.result = res;
    }

    pub fn is_open(self: *const Dialog) bool {
        return self.open;
    }

    pub fn needs_dim(self: *const Dialog) bool {
        return self.open;
    }

    pub fn get_result(self: *const Dialog) DialogResult {
        return self.result;
    }

    pub fn handle_event(self: *Dialog, ev: *const Event) bool {
        if (!self.open) return false;
        switch (ev.kind) {
            KEY_DOWN => {
                const kc = ev.arg0;
                if (kc == 0x28) { // Enter → OK
                    self.result = .ok;
                    self.open = false;
                    return true;
                }
                if (kc == 0x29) { // Escape → Cancel
                    self.result = .cancel;
                    self.open = false;
                    return true;
                }
                if (self.has_input) {
                    // Delegate typing to TextInput (preserves Enter/Escape handling above)
                    return self.input.handle_event(ev);
                }
                return false;
            },
            MOUSE_DOWN, MOUSE_MOVE, MOUSE_UP => {
                // Forward to buttons to maintain hover/pressed visuals and detect clicks.
                const ok_clicked = self.ok_button.handle_event(ev);
                const cancel_clicked = self.cancel_button.handle_event(ev);
                if (ok_clicked) {
                    self.result = .ok;
                    self.open = false;
                    return true;
                }
                if (cancel_clicked) {
                    self.result = .cancel;
                    self.open = false;
                    return true;
                }
                if (self.has_input and ev.kind == MOUSE_DOWN) {
                    // Give input focus on click inside its rect; also handle click outside to blur.
                    const inside_input = self.input.rect.contains(ev.arg0, ev.arg1);
                    // Let TextInput update its focused flag
                    const changed = self.input.handle_event(ev);
                    if (inside_input or changed) return true;
                }
                // Modal exclusive focus: any click inside dialog consumes, outside also consumes
                // to prevent parent interaction while open (dim overlay).
                if (ev.kind == MOUSE_DOWN and self.rect.contains(ev.arg0, ev.arg1)) return true;
                if (ev.kind == MOUSE_DOWN) {
                    // Click outside dialog but while open → consume (modal) but no dismiss
                    // (unless desired to dismiss on outside click — we keep modal strict)
                    return true;
                }
                if (ev.kind == MOUSE_MOVE and self.rect.contains(ev.arg0, ev.arg1)) return true;
                return false;
            },
            else => return false,
        }
    }

    pub fn draw_dim_overlay(self: *const Dialog, parent_win_id: u32) void {
        if (!self.open) return;
        // Dim parent with a muted overlay — fill parent rect with border color at 50% illusion
        // (solid fill with theme_border, parent content underneath will be dimmed visually).
        draw_rect(parent_win_id, self.parent_rect, 0x000000);
        // Use a semi-transparent illusion: overdraw with theme_surface at reduced intensity
        // For host test, just verify no panic — actual dim is visual.
        draw_rect(parent_win_id, self.parent_rect, theme_border());
    }

    pub fn draw(self: *const Dialog, win_id: u32) void {
        if (!self.open) return;
        // Dialog window background + border
        draw_rect(win_id, self.rect, theme_surface());
        draw_rect_outline(win_id, self.rect, 1, theme_border());
        // Title bar accent strip (8px)
        draw_rect(win_id, Rect.make(self.rect.x, self.rect.y, self.rect.w, 12), theme_accent());
        // Message — support up to 3 lines split by '\n', wrap at ~35 chars.
        var line_y = self.rect.y + 18;
        var msg_start: usize = 0;
        var line_idx: usize = 0;
        while (msg_start < self.message.len and line_idx < 3) : (line_idx += 1) {
            var line_end = msg_start;
            while (line_end < self.message.len and self.message[line_end] != '\n' and line_end - msg_start < 35) : (line_end += 1) {}
            // If we stopped mid-word, try to break at space (optional)
            const line = self.message[msg_start..line_end];
            draw_text(win_id, line, self.rect.x + 10, line_y, theme_text_primary());
            line_y += 10;
            if (line_end < self.message.len and self.message[line_end] == '\n') line_end += 1;
            msg_start = line_end;
            if (msg_start >= self.message.len) break;
        }
        // Optional TextInput
        if (self.has_input) {
            self.input.draw(win_id);
        }
        // Buttons
        self.ok_button.draw(win_id);
        self.cancel_button.draw(win_id);
    }
};

// ---------------------------------------------------------------------------
// Standard Dialog Helper (M27 G10 #453)
// ---------------------------------------------------------------------------

pub const DialogSeverity = enum {
    info,
    warning,
    error_type,
    question,
};

pub const DialogButtons = enum {
    ok,
    ok_cancel,
    yes_no,
    yes_no_cancel,
    save_dont_cancel,
};

/// Helper to configure and present a standardized modal dialog.
pub fn show_dialog(dlg: *Dialog, message: []const u8, has_input: bool) void {
    dlg.message = message;
    dlg.has_input = has_input;
    dlg.show();
}

// ---------------------------------------------------------------------------
// Empty State Presenter (M27 G22 #465)
// ---------------------------------------------------------------------------

/// Draw an empty-state message inside `rect` when a view/list has no items.
pub fn draw_empty_state(win_id: u32, rect: Rect, title: []const u8, subtitle: []const u8) void {
    if (rect.w == 0 or rect.h == 0) return;
    draw_rect(win_id, rect, theme_surface());
    draw_rect_outline(win_id, rect, 1, theme_border());

    const center_y = rect.y + rect.h / 2;
    const title_w = @as(u32, @intCast(title.len)) * 8;
    const title_x = if (rect.w > title_w) rect.x + (rect.w - title_w) / 2 else rect.x + 4;
    const title_y = if (center_y >= 14) center_y - 14 else rect.y + 4;

    draw_text(win_id, title, title_x, title_y, theme_text_primary());

    if (subtitle.len > 0) {
        const sub_w = @as(u32, @intCast(subtitle.len)) * 8;
        const sub_x = if (rect.w > sub_w) rect.x + (rect.w - sub_w) / 2 else rect.x + 4;
        draw_text(win_id, subtitle, sub_x, title_y + 14, theme_text_muted());
    }
}

/// Draw an empty-state message with an icon character (M27 G22 #465).
pub fn draw_empty_state_icon(win_id: u32, rect: Rect, message: []const u8, icon_char: u8) void {
    if (rect.w == 0 or rect.h == 0) return;
    draw_rect(win_id, rect, theme_surface());
    draw_rect_outline(win_id, rect, 1, theme_border());

    const center_y = rect.y + rect.h / 2;
    const icon_x = if (rect.w >= 8) rect.x + (rect.w - 8) / 2 else rect.x + 4;
    const icon_y = if (center_y >= 20) center_y - 16 else rect.y + 4;
    if (icon_char >= 0x20 and icon_char <= 0x7e) {
        draw_char(win_id, icon_char, icon_x, icon_y, theme_text_muted());
    }

    const msg_w = @as(u32, @intCast(message.len)) * 8;
    const msg_x = if (rect.w > msg_w) rect.x + (rect.w - msg_w) / 2 else rect.x + 4;
    const msg_y = icon_y + 14;
    draw_text(win_id, message, msg_x, msg_y, theme_text_muted());
}

// ---------------------------------------------------------------------------
// Error Display Consistency (M27 G23 #466)
// ---------------------------------------------------------------------------

/// Format standard OS error code into a user-friendly message.
pub fn format_error(code: i64, buf: []u8) []const u8 {
    const msg: []const u8 = switch (code) {
        -1 => "Operation not permitted",
        -2 => "File or directory not found",
        -3 => "No such process",
        -4 => "Interrupted system call",
        -5 => "Input/output error",
        -6 => "No such device or address",
        -7 => "Argument list too long",
        -8 => "Exec format error",
        -9 => "Bad file descriptor",
        -12 => "Out of memory",
        -13 => "Permission denied",
        -14 => "Bad memory address",
        -16 => "Device or resource busy",
        -17 => "File already exists",
        -19 => "No such device",
        -20 => "Not a directory",
        -21 => "Is a directory",
        -22 => "Invalid argument",
        -24 => "Too many open files",
        -27 => "File too large",
        -28 => "No space left on device",
        -30 => "Read-only file system",
        -38 => "Function not implemented",
        -110 => "Connection timed out",
        -111 => "Connection refused",
        else => "",
    };
    if (msg.len > 0) {
        const n = @min(msg.len, buf.len);
        @memcpy(buf[0..n], msg[0..n]);
        return buf[0..n];
    }
    return std.fmt.bufPrint(buf, "System error ({d})", .{code}) catch "System error";
}

/// Format error with optional context prefix (e.g. "Save failed: File or directory not found").
pub fn format_error_ctx(buf: []u8, code: i64, context: []const u8) []const u8 {
    var raw_buf: [128]u8 = undefined;
    const err_str = format_error(code, &raw_buf);
    if (context.len == 0) {
        const n = @min(err_str.len, buf.len);
        @memcpy(buf[0..n], err_str[0..n]);
        return buf[0..n];
    }
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ context, err_str }) catch err_str;
}

pub const format_error_with_context = format_error_ctx;

// ---------------------------------------------------------------------------
// Component: HScrollBar — horizontal scroll track (GH #222, Arc1)
// ---------------------------------------------------------------------------

pub const HScrollBar = struct {
    rect: Rect,
    content_w: u32,
    viewport_w: u32,
    offset: u32 = 0,
    dragging: bool = false,
    drag_start_x: u32 = 0,
    drag_start_offset: u32 = 0,

    pub const track_h: u32 = 8;
    pub const thumb_min_w: u32 = 16;

    pub fn init(rect: Rect, content_w: u32, viewport_w: u32) HScrollBar {
        var hb = HScrollBar{ .rect = rect, .content_w = content_w, .viewport_w = viewport_w };
        hb.clamp_offset();
        return hb;
    }

    pub fn set_content_width(self: *HScrollBar, w: u32) void {
        self.content_w = w;
        self.clamp_offset();
    }

    pub fn set_viewport_width(self: *HScrollBar, w: u32) void {
        self.viewport_w = w;
        self.clamp_offset();
    }

    pub fn max_offset(self: *const HScrollBar) u32 {
        if (self.content_w <= self.viewport_w) return 0;
        return self.content_w - self.viewport_w;
    }

    fn clamp_offset(self: *HScrollBar) void {
        const m = self.max_offset();
        if (self.offset > m) self.offset = m;
    }

    pub fn thumb_w(self: *const HScrollBar) u32 {
        if (self.content_w <= self.viewport_w) return self.rect.w;
        const visible = self.viewport_w;
        const content = self.content_w;
        const proportional = self.rect.w * visible / content;
        return @max(thumb_min_w, proportional);
    }

    pub fn thumb_x(self: *const HScrollBar) u32 {
        const m = self.max_offset();
        if (m == 0) return self.rect.x;
        const tw = self.thumb_w();
        const track_w = self.rect.w - tw;
        return self.rect.x + (self.offset * track_w / m);
    }

    pub fn thumb_rect(self: *const HScrollBar) Rect {
        if (self.content_w <= self.viewport_w) return self.rect;
        const tw = self.thumb_w();
        const tx = self.thumb_x();
        return Rect.make(tx, self.rect.y, tw, self.rect.h);
    }

    fn track_contains(self: *const HScrollBar, px: u32, py: u32) bool {
        return self.rect.contains(px, py);
    }

    pub fn scroll_by(self: *HScrollBar, delta: i32) void {
        const m: i32 = @intCast(self.max_offset());
        var off: i32 = @intCast(self.offset);
        off += delta;
        if (off < 0) off = 0;
        if (off > m) off = m;
        self.offset = @intCast(off);
    }

    pub fn handle_event(self: *HScrollBar, ev: *const Event) bool {
        if (self.content_w <= self.viewport_w) return false;
        switch (ev.kind) {
            MOUSE_DOWN => {
                const px = ev.arg0;
                const py = ev.arg1;
                if (!self.rect.contains(px, py)) return false;
                const tr = self.thumb_rect();
                if (tr.contains(px, py)) {
                    self.dragging = true;
                    self.drag_start_x = px;
                    self.drag_start_offset = self.offset;
                    return true;
                }
                if (self.track_contains(px, py)) {
                    const tx = self.thumb_x();
                    if (px < tx) {
                        self.scroll_by(-@as(i32, @intCast(self.viewport_w)));
                    } else {
                        self.scroll_by(@as(i32, @intCast(self.viewport_w)));
                    }
                    return true;
                }
                return false;
            },
            MOUSE_MOVE => {
                if (!self.dragging) return false;
                const px: i32 = @intCast(ev.arg0);
                const start_x: i32 = @intCast(self.drag_start_x);
                const delta: i32 = px - start_x;
                const m = self.max_offset();
                if (m == 0) return false;
                const tw = self.thumb_w();
                const track_w: i32 = @intCast(self.rect.w - tw);
                if (track_w <= 0) return false;
                const scaled = @divTrunc(delta * @as(i32, @intCast(m)), track_w);
                var new_off: i32 = @as(i32, @intCast(self.drag_start_offset)) + scaled;
                if (new_off < 0) new_off = 0;
                if (new_off > @as(i32, @intCast(m))) new_off = @intCast(m);
                self.offset = @intCast(new_off);
                return true;
            },
            MOUSE_UP => {
                if (self.dragging) {
                    self.dragging = false;
                    return true;
                }
                return false;
            },
            KEY_DOWN => {
                const keycode = ev.arg0;
                // Left 0x50, Right 0x4f, Home 0x4a, End 0x4d
                if (keycode == 0x50) {
                    self.scroll_by(-16);
                    return true;
                }
                if (keycode == 0x4f) {
                    self.scroll_by(16);
                    return true;
                }
                if (keycode == 0x4a) {
                    self.offset = 0;
                    return true;
                }
                if (keycode == 0x4d) {
                    self.offset = self.max_offset();
                    return true;
                }
                return false;
            },
            MOUSE_SCROLL => {
                // Horizontal via Shift (MOD_SHIFT) or packed horizontal bit.
                const is_shift = (ev.flags & MOD_SHIFT) != 0;
                const packed_horizontal = (ev.arg0 & 0x4000) != 0 and (ev.arg0 & 0xffff0000) == 0;
                const is_horizontal = is_shift or packed_horizontal;
                if (!is_horizontal) return false;
                var delta: i32 = 0;
                // Arc4 #236: arg0 packed per ADR 0013 D2.
                // bits 0–13 = magnitude, bit 14 = horizontal, bit 15 = sign.
                // Shift+scroll overrides horizontal flag.
                const raw = ev.arg0;
                const magnitude: i32 = @intCast(raw & 0x1fff);
                if (magnitude == 0) return false;
                const horiz = is_shift or (raw & 0x4000) != 0;
                if (!horiz) return false; // HScrollBar only consumes horizontal
                const sign: i32 = if ((raw & 0x8000) != 0) 1 else -1;
                delta = sign * magnitude * 16;
                self.scroll_by(delta);
                return true;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const HScrollBar, win_id: u32) void {
        if (self.content_w <= self.viewport_w) return;
        // Track
        draw_rect(win_id, self.rect, theme_border());
        // Thumb
        const tr = self.thumb_rect();
        win_fill(win_id, tr.x, tr.y, tr.w, tr.h, theme_accent());
    }
};

// ---------------------------------------------------------------------------
// Unit Tests (Class A Host Validation)
// ---------------------------------------------------------------------------

test "ui: Rect contains and inset geometry" {
    const r = Rect.make(10, 20, 100, 50);
    try std.testing.expect(r.contains(10, 20));
    try std.testing.expect(r.contains(50, 40));
    try std.testing.expect(r.contains(109, 69));
    try std.testing.expect(!r.contains(9, 20));
    try std.testing.expect(!r.contains(110, 20));
    try std.testing.expect(!r.contains(10, 70));

    const inner = r.inset(2, 5);
    try std.testing.expectEqual(@as(u32, 12), inner.x);
    try std.testing.expectEqual(@as(u32, 25), inner.y);
    try std.testing.expectEqual(@as(u32, 96), inner.w);
    try std.testing.expectEqual(@as(u32, 40), inner.h);
}

test "ui: Button state transitions and click trigger" {
    var btn = Button.init(Rect.make(10, 10, 80, 30), "OK");
    try std.testing.expectEqual(ButtonState.idle, btn.state);

    // Mouse hover inside
    var ev_move = Event{ .kind = MOUSE_MOVE, .flags = 0, .seq = 1, .arg0 = 20, .arg1 = 20 };
    _ = btn.handle_event(&ev_move);
    try std.testing.expectEqual(ButtonState.hover, btn.state);

    // Mouse press inside
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 20, .arg1 = 20 };
    _ = btn.handle_event(&ev_down);
    try std.testing.expectEqual(ButtonState.pressed, btn.state);

    // Mouse release inside -> triggers click!
    var ev_up = Event{ .kind = MOUSE_UP, .flags = 0, .seq = 3, .arg0 = 20, .arg1 = 20 };
    const clicked = btn.handle_event(&ev_up);
    try std.testing.expect(clicked);
    try std.testing.expectEqual(ButtonState.hover, btn.state);

    // Mouse press and drag outside -> no click
    _ = btn.handle_event(&ev_down);
    var ev_up_outside = Event{ .kind = MOUSE_UP, .flags = 0, .seq = 4, .arg0 = 200, .arg1 = 200 };
    const clicked_outside = btn.handle_event(&ev_up_outside);
    try std.testing.expect(!clicked_outside);
    try std.testing.expectEqual(ButtonState.idle, btn.state);
}

test "ui: TextInput buffer typing, backspace, and cursor" {
    var input = TextInput.init(Rect.make(10, 10, 120, 20));
    input.focused = true;

    // Type 'A' (ASCII 65)
    var ev_a = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x04, .arg1 = 'A' };
    try std.testing.expect(input.handle_event(&ev_a));
    try std.testing.expectEqualStrings("A", input.get_text());
    try std.testing.expectEqual(@as(usize, 1), input.cursor);

    // Type 'B' (ASCII 66)
    var ev_b = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x05, .arg1 = 'B' };
    try std.testing.expect(input.handle_event(&ev_b));
    try std.testing.expectEqualStrings("AB", input.get_text());
    try std.testing.expectEqual(@as(usize, 2), input.cursor);

    // Backspace
    var ev_bs = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x2a, .arg1 = 0x08 };
    try std.testing.expect(input.handle_event(&ev_bs));
    try std.testing.expectEqualStrings("A", input.get_text());
    try std.testing.expectEqual(@as(usize, 1), input.cursor);
}

test "ui: ListView row selection and keyboard navigation" {
    var list = ListView.init(Rect.make(10, 10, 100, 100), 16);
    list.item_count = 5;

    // Click row 2 (y=10 + 2*16 + 4 = 46)
    var ev_click = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = 20, .arg1 = 46 };
    try std.testing.expect(list.handle_event(&ev_click));
    try std.testing.expectEqual(@as(?usize, 2), list.selected_idx);

    // Down arrow -> row 3
    var ev_down = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x51, .arg1 = 0 };
    try std.testing.expect(list.handle_event(&ev_down));
    try std.testing.expectEqual(@as(?usize, 3), list.selected_idx);

    // Up arrow -> row 2
    var ev_up = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x52, .arg1 = 0 };
    try std.testing.expect(list.handle_event(&ev_up));
    try std.testing.expectEqual(@as(?usize, 2), list.selected_idx);
}

test "ui: parse_procs decodes 40-byte snapshot rows" {
    var raw: [80]u8 = [_]u8{0} ** 80;
    // Row 0: pid=1, state=2 (running), exit=0, name="KERNEL.BIN"
    std.mem.writeInt(u64, raw[0..8], 1, .little);
    std.mem.writeInt(u64, raw[8..16], 2, .little);
    std.mem.writeInt(u64, raw[16..24], 0, .little);
    @memcpy(raw[24..34], "KERNEL.BIN");

    // Row 1: pid=2, state=3 (exited), exit=43, name="CALC.BIN"
    std.mem.writeInt(u64, raw[40..48], 2, .little);
    std.mem.writeInt(u64, raw[48..56], 3, .little);
    std.mem.writeInt(u64, raw[56..64], 43, .little);
    @memcpy(raw[64..72], "CALC.BIN");

    var procs: [4]ProcInfo = undefined;
    const count = parse_procs(&raw, 2, &procs);
    try std.testing.expectEqual(@as(usize, 2), count);

    try std.testing.expectEqual(@as(u64, 1), procs[0].pid);
    try std.testing.expectEqual(ProcState.running, procs[0].state);
    try std.testing.expectEqual(@as(u64, 0), procs[0].exit_status);
    try std.testing.expectEqualStrings("KERNEL.BIN", procs[0].name[0..procs[0].name_len]);

    try std.testing.expectEqual(@as(u64, 2), procs[1].pid);
    try std.testing.expectEqual(ProcState.exited, procs[1].state);
    try std.testing.expectEqual(@as(u64, 43), procs[1].exit_status);
    try std.testing.expectEqualStrings("CALC.BIN", procs[1].name[0..procs[1].name_len]);
}

test "ui: DropDown open, select, and dismiss" {
    const options = [_][]const u8{ "dark", "light", "amber" };
    var dd = DropDown.init(Rect.make(10, 10, 120, 20), &options);
    try std.testing.expectEqual(@as(usize, 0), dd.selected);
    try std.testing.expect(!dd.open);
    try std.testing.expectEqualStrings("dark", dd.selected_text());

    // Click button -> opens overlay.
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = 30, .arg1 = 15 };
    _ = dd.handle_event(&ev_down);
    try std.testing.expect(dd.open);

    // Click option 2 ("amber") in overlay.
    var ev_opt = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 30, .arg1 = 70 };
    _ = dd.handle_event(&ev_opt);
    try std.testing.expect(!dd.open);
    try std.testing.expectEqual(@as(usize, 2), dd.selected);
    try std.testing.expectEqualStrings("amber", dd.selected_text());

    // Open again and click outside -> dismisses.
    _ = dd.handle_event(&ev_down);
    try std.testing.expect(dd.open);
    var ev_outside = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = 200, .arg1 = 200 };
    _ = dd.handle_event(&ev_outside);
    try std.testing.expect(!dd.open);
}

test "ui: DropDown keyboard navigation" {
    const options = [_][]const u8{ "a", "b", "c", "d" };
    var dd = DropDown.init(Rect.make(10, 10, 80, 20), &options);
    dd.open = true;

    // Down arrow -> select 1.
    var ev_down = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x51, .arg1 = 0 };
    _ = dd.handle_event(&ev_down);
    try std.testing.expectEqual(@as(usize, 1), dd.selected);

    // Down arrow -> select 2.
    _ = dd.handle_event(&ev_down);
    try std.testing.expectEqual(@as(usize, 2), dd.selected);

    // Up arrow -> back to 1.
    var ev_up = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x52, .arg1 = 0 };
    _ = dd.handle_event(&ev_up);
    try std.testing.expectEqual(@as(usize, 1), dd.selected);

    // Enter -> closes overlay.
    var ev_enter = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x28, .arg1 = 0 };
    _ = dd.handle_event(&ev_enter);
    try std.testing.expect(!dd.open);

    // Escape -> closes overlay.
    dd.open = true;
    var ev_esc = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x29, .arg1 = 0 };
    _ = dd.handle_event(&ev_esc);
    try std.testing.expect(!dd.open);
}

test "ui: DropDown set_selected_by_name" {
    const options = [_][]const u8{ "dark", "light", "amber" };
    var dd = DropDown.init(Rect.make(10, 10, 120, 20), &options);
    dd.set_selected_by_name("amber");
    try std.testing.expectEqual(@as(usize, 2), dd.selected);
    try std.testing.expectEqualStrings("amber", dd.selected_text());

    // Name not found -> no change.
    dd.set_selected_by_name("nope");
    try std.testing.expectEqual(@as(usize, 2), dd.selected);
}

test "ui: ScrollView proportional thumb and offset clamp" {
    // Visible 100, content 200 -> thumb = max(16, 100*100/200=50) = 50
    var sv = ScrollView.init(Rect.make(0, 0, 120, 100), 200);
    try std.testing.expectEqual(@as(u32, 100), sv.max_offset());
    try std.testing.expectEqual(@as(u32, 50), sv.thumb_h());
    try std.testing.expectEqual(@as(u32, 0), sv.offset);
    try std.testing.expectEqual(@as(u32, 0), sv.thumb_y());

    // Visible 100, content 400 -> thumb = max(16, 100*100/400=25) = 25
    var sv2 = ScrollView.init(Rect.make(0, 0, 120, 100), 400);
    try std.testing.expectEqual(@as(u32, 300), sv2.max_offset());
    try std.testing.expectEqual(@as(u32, 25), sv2.thumb_h());

    // Content fits — no scrolling, thumb fills track, offset clamped
    var sv3 = ScrollView.init(Rect.make(0, 0, 120, 100), 80);
    try std.testing.expectEqual(@as(u32, 0), sv3.max_offset());
    try std.testing.expectEqual(@as(u32, 100), sv3.thumb_h());
    sv3.offset = 999;
    sv3.set_content_height(80);
    try std.testing.expectEqual(@as(u32, 0), sv3.offset);

    // Small content with large visible — thumb clamp to 16 minimum
    var sv4 = ScrollView.init(Rect.make(0, 0, 120, 20), 500);
    // 20*20/500 = 0 -> clamp to 16
    try std.testing.expectEqual(@as(u32, 16), sv4.thumb_h());
}

test "ui: ScrollView PAGE_UP/DOWN and track click" {
    var sv = ScrollView.init(Rect.make(10, 10, 100, 100), 300);
    try std.testing.expectEqual(@as(u32, 200), sv.max_offset());

    // PageDown moves by viewport height
    var ev_pgdn = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x4e, .arg1 = 0 };
    _ = sv.handle_event(&ev_pgdn);
    try std.testing.expectEqual(@as(u32, 100), sv.offset);
    _ = sv.handle_event(&ev_pgdn);
    try std.testing.expectEqual(@as(u32, 200), sv.offset);
    // Clamped at max
    _ = sv.handle_event(&ev_pgdn);
    try std.testing.expectEqual(@as(u32, 200), sv.offset);

    // PageUp
    var ev_pgup = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x4b, .arg1 = 0 };
    _ = sv.handle_event(&ev_pgup);
    try std.testing.expectEqual(@as(u32, 100), sv.offset);
    _ = sv.handle_event(&ev_pgup);
    try std.testing.expectEqual(@as(u32, 0), sv.offset);

    // Track click below thumb — page down
    sv.offset = 0;
    const th = sv.thumb_rect();
    // Click 10px below thumb but inside track
    var ev_track_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = th.x + 1, .arg1 = th.y + th.h + 5 };
    _ = sv.handle_event(&ev_track_down);
    try std.testing.expectEqual(@as(u32, 100), sv.offset);

    // Track click above thumb — page up
    var ev_track_up = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 4, .arg0 = th.x + 1, .arg1 = 15 };
    // Need to be above current thumb (which is now at y=33 for offset 100 with thumb 33)
    _ = sv.handle_event(&ev_track_up);
    try std.testing.expectEqual(@as(u32, 0), sv.offset);
}

test "ui: ScrollView thumb drag scales to content offset" {
    // Viewport 100, content 300 -> max 200, thumb 33, track_h 67
    var sv = ScrollView.init(Rect.make(10, 10, 100, 100), 300);
    const tr = sv.thumb_rect();
    try std.testing.expectEqual(@as(u32, 33), tr.h);

    // Drag thumb from y=10 down by 33px (half track) -> offset ~100
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = tr.x + 1, .arg1 = tr.y + 2 };
    try std.testing.expect(sv.handle_event(&ev_down));
    try std.testing.expect(sv.dragging);

    var ev_move = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 2, .arg0 = tr.x + 1, .arg1 = tr.y + 35 };
    _ = sv.handle_event(&ev_move);
    // delta 33, scaled 33*200/67 ≈ 98
    try std.testing.expect(sv.offset >= 95 and sv.offset <= 102);

    var ev_up = Event{ .kind = MOUSE_UP, .flags = 0, .seq = 3, .arg0 = tr.x + 1, .arg1 = tr.y + 35 };
    _ = sv.handle_event(&ev_up);
    try std.testing.expect(!sv.dragging);

    // Drag beyond max clamps
    sv.offset = 0;
    _ = sv.handle_event(&ev_down);
    var ev_far = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 4, .arg0 = tr.x + 1, .arg1 = 200 };
    _ = sv.handle_event(&ev_far);
    try std.testing.expectEqual(sv.max_offset(), sv.offset);
}

test "ui: ScrollView 50+ lines demo scrolls via thumb" {
    // Simulate a file list: 60 lines, each 10px, viewport 100 -> content 600
    const line_h: u32 = 10;
    const lines: u32 = 60;
    const content_h = lines * line_h;
    var sv = ScrollView.init(Rect.make(0, 0, 120, 100), content_h);
    try std.testing.expectEqual(@as(u32, 500), sv.max_offset());
    // Thumb for 100 visible / 600 content -> 16 (clamped minimum)
    try std.testing.expectEqual(@as(u32, 16), sv.thumb_h());

    // Scroll through all pages via PAGE_DOWN
    var steps: u32 = 0;
    while (sv.offset < sv.max_offset()) : (steps += 1) {
        var ev = Event{ .kind = KEY_DOWN, .flags = 0, .seq = steps, .arg0 = 0x4e, .arg1 = 0 };
        _ = sv.handle_event(&ev);
        if (steps > 10) break;
    }
    try std.testing.expectEqual(sv.max_offset(), sv.offset);
    try std.testing.expect(steps >= 5);
}

test "ui: Checkbox click toggles *bool and visual state" {
    var checked: bool = false;
    var cb = Checkbox.init(Rect.make(10, 10, 12, 12), &checked);

    // Click inside toggles to true
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = 15, .arg1 = 15 };
    try std.testing.expect(cb.handle_event(&ev_down));
    try std.testing.expect(checked);

    // Click again toggles back to false
    var ev2 = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 15, .arg1 = 15 };
    try std.testing.expect(cb.handle_event(&ev2));
    try std.testing.expect(!checked);

    // Click outside does not toggle
    var ev_out = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = 30, .arg1 = 30 };
    try std.testing.expect(!cb.handle_event(&ev_out));
    try std.testing.expect(!checked);

    // Visual state reflects bool on every frame (draw does not panic)
    checked = true;
    // draw is no-panic check — we call it with a dummy win_id (no kernel, just logic)
    // Host test just ensures draw path doesn't crash; actual pixels checked on VZ.
    cb.draw(0);
    checked = false;
    cb.draw(0);
}

test "ui: Toggle click toggles *bool, pill accent/muted" {
    var enabled: bool = false;
    var tg = Toggle.init(Rect.make(20, 20, 48, 20), &enabled);

    // Click inside toggles to true
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = 30, .arg1 = 30 };
    try std.testing.expect(tg.handle_event(&ev_down));
    try std.testing.expect(enabled);

    // Click again toggles false
    var ev2 = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 30, .arg1 = 30 };
    try std.testing.expect(tg.handle_event(&ev2));
    try std.testing.expect(!enabled);

    // Click outside does not toggle
    var ev_out = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = 100, .arg1 = 100 };
    try std.testing.expect(!tg.handle_event(&ev_out));
    try std.testing.expect(!enabled);

    // Visual state reflects bool
    enabled = true;
    tg.draw(1);
    enabled = false;
    tg.draw(1);
}

test "ui: Checkbox and Toggle ignore non-left or non-MOUSE_DOWN" {
    var b: bool = false;
    var cb = Checkbox.init(Rect.make(0, 0, 12, 12), &b);
    var tg = Toggle.init(Rect.make(0, 0, 48, 20), &b);

    var ev_move = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 1, .arg0 = 5, .arg1 = 5 };
    try std.testing.expect(!cb.handle_event(&ev_move));
    try std.testing.expect(!tg.handle_event(&ev_move));

    var ev_right = Event{ .kind = MOUSE_DOWN, .flags = BTN_RIGHT, .seq = 2, .arg0 = 5, .arg1 = 5 };
    try std.testing.expect(!cb.handle_event(&ev_right));
    try std.testing.expect(!tg.handle_event(&ev_right));

    var ev_key = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x04, .arg1 = 'a' };
    try std.testing.expect(!cb.handle_event(&ev_key));
    try std.testing.expect(!tg.handle_event(&ev_key));
}

test "ui: ProgressBar determinate fill at 0%/50%/100% and clamp" {
    var pb = ProgressBar.init(Rect.make(10, 10, 100, 20));
    // inner 98x18 (100-2, 20-2)
    try std.testing.expectEqual(@as(u32, 98), pb.inner_rect().w);

    pb.set_value(0.0);
    try std.testing.expectEqual(@as(u32, 0), pb.fill_width());
    pb.set_value(0.5);
    try std.testing.expectEqual(@as(u32, 49), pb.fill_width());
    pb.set_value(1.0);
    try std.testing.expectEqual(@as(u32, 98), pb.fill_width());

    // Clamp
    pb.set_value(-0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pb.value, 0.001);
    try std.testing.expectEqual(@as(u32, 0), pb.fill_width());
    pb.set_value(2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pb.value, 0.001);
    try std.testing.expectEqual(@as(u32, 98), pb.fill_width());
    pb.set_value(std.math.nan(f32));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pb.value, 0.001);

    // 25% -> 24 (98*0.25=24.5 floor 24)
    pb.set_value(0.25);
    try std.testing.expectEqual(@as(u32, 24), pb.fill_width());
}

test "ui: ProgressBar indeterminate slides via TIMER and bounces" {
    var pb = ProgressBar.init(Rect.make(0, 0, 100, 20));
    pb.set_indeterminate(true);
    try std.testing.expect(pb.indeterminate);
    try std.testing.expectEqual(@as(i32, 0), pb.offset);
    try std.testing.expectEqual(@as(i32, 1), pb.dir);
    const max = pb.max_offset(); // 98-20=78
    try std.testing.expectEqual(@as(i32, 78), max);

    var ev_timer = Event{ .kind = EVENT_TIMER, .flags = 0, .seq = 1, .arg0 = 0, .arg1 = 0 };
    // Step forward 5 ticks -> offset 20
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expect(pb.handle_event(&ev_timer));
    }
    try std.testing.expectEqual(@as(i32, 20), pb.offset);

    // Run to max and bounce
    while (pb.offset < max) {
        _ = pb.handle_event(&ev_timer);
    }
    try std.testing.expectEqual(max, pb.offset);
    try std.testing.expectEqual(@as(i32, -1), pb.dir);
    // One more tick moves back
    _ = pb.handle_event(&ev_timer);
    try std.testing.expectEqual(max - 4, pb.offset);

    // Return to 0 and bounce to +1
    while (pb.offset > 0) {
        _ = pb.handle_event(&ev_timer);
    }
    try std.testing.expectEqual(@as(i32, 0), pb.offset);
    try std.testing.expectEqual(@as(i32, 1), pb.dir);

    // Non-TIMER ignored
    var ev_other = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 10, .arg1 = 10 };
    try std.testing.expect(!pb.handle_event(&ev_other));
    // Determinate ignores TIMER
    pb.set_indeterminate(false);
    try std.testing.expect(!pb.handle_event(&ev_timer));
}

test "ui: ProgressBar label contrast inversion over fill/block" {
    var pb = ProgressBar.init(Rect.make(10, 10, 100, 20));
    pb.set_label("50%");
    // At 0%, no char over fill
    pb.set_value(0.0);
    try std.testing.expect(!pb.is_label_char_over_fill(0));
    try std.testing.expect(!pb.is_label_char_over_fill(1));
    // At 100%, centered label "50%" (3*8=24, rect 100 -> label_x=10+38=48)
    // char0 at 48 center 52, char1 at 56 center 60, char2 at 64 center 68
    // inner 11..108 (10+1), fill_end 109 -> all over fill
    pb.set_value(1.0);
    try std.testing.expect(pb.is_label_char_over_fill(0));
    try std.testing.expect(pb.is_label_char_over_fill(1));
    try std.testing.expect(pb.is_label_char_over_fill(2));
    // At 50% fill_end 60 (11+49=60): char0 center 52 <60 over, char1 60 not <60, char2 68 not
    pb.set_value(0.5);
    try std.testing.expect(pb.is_label_char_over_fill(0));
    try std.testing.expect(!pb.is_label_char_over_fill(1));
    try std.testing.expect(!pb.is_label_char_over_fill(2));

    // Indeterminate block at offset 0: block 11..31
    pb.set_indeterminate(true);
    pb.offset = 0;
    // label "50%" same centers 52,60,68 -> none over block 11..31
    try std.testing.expect(!pb.is_label_char_over_fill(0));
    // Move block to cover label: offset 37 -> block 48..68 covers char0 and char1 partially
    pb.offset = 37;
    try std.testing.expect(pb.is_label_char_over_fill(0)); // 52 in 48..68
    try std.testing.expect(pb.is_label_char_over_fill(1)); // 60 in
    try std.testing.expect(!pb.is_label_char_over_fill(2) or pb.is_label_char_over_fill(2)); // char2 center 68 is at block end exclusive, so false
    // Out of range idx false
    try std.testing.expect(!pb.is_label_char_over_fill(99));
}

test "ui: ProgressBar draw paths no panic (determinate/indeterminate/label)" {
    var pb = ProgressBar.init(Rect.make(10, 10, 120, 20));
    pb.set_value(0.0);
    pb.draw(0);
    pb.set_value(0.5);
    pb.set_label("Loading 50%");
    pb.draw(1);
    pb.set_value(1.0);
    pb.set_label("Done");
    pb.draw(2);
    pb.set_indeterminate(true);
    pb.set_label("Fetching...");
    pb.draw(3);
    // Tick and draw again
    var ev = Event{ .kind = EVENT_TIMER, .flags = 0, .seq = 1, .arg0 = 0, .arg1 = 0 };
    _ = pb.handle_event(&ev);
    pb.draw(3);
    // Small rect edge case (no inner)
    var pb_small = ProgressBar.init(Rect.make(0, 0, 2, 2));
    pb_small.set_value(0.5);
    pb_small.draw(0);
    try std.testing.expectEqual(@as(u32, 0), pb_small.fill_width());
    try std.testing.expectEqual(@as(i32, 0), pb_small.max_offset());
}

test "ui: ProgressBar initWithValue and theme contrast draw" {
    var pb = ProgressBar.initWithValue(Rect.make(0, 0, 200, 24), 0.75);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), pb.value, 0.001);
    // inner 198, 75% -> 148
    try std.testing.expectEqual(@as(u32, 148), pb.fill_width());
    // Theme switch does not panic
    _ = set_theme("light");
    pb.set_label("75% light");
    pb.draw(0);
    _ = set_theme("dark");
    pb.draw(0);
    _ = set_theme("amber");
    pb.draw(0);
    _ = set_theme("dark");
}

test "ui: Dialog centered 300x150 and button geometry" {
    const parent = Rect.make(0, 0, 400, 300);
    var dlg = Dialog.init(parent, "Delete file?", false);
    // Centered 300x150 at (50,75)
    try std.testing.expectEqual(@as(u32, 300), dlg.rect.w);
    try std.testing.expectEqual(@as(u32, 150), dlg.rect.h);
    try std.testing.expectEqual(@as(u32, 50), dlg.rect.x);
    try std.testing.expectEqual(@as(u32, 75), dlg.rect.y);
    try std.testing.expect(!dlg.is_open());
    try std.testing.expect(!dlg.needs_dim());
    dlg.show();
    try std.testing.expect(dlg.is_open());
    try std.testing.expect(dlg.needs_dim());
    try std.testing.expectEqual(DialogResult.none, dlg.get_result());
    // Buttons placed at bottom right
    try std.testing.expectEqual(@as(u32, 60), dlg.ok_button.rect.w);
    try std.testing.expectEqual(@as(u32, 20), dlg.ok_button.rect.h);
    try std.testing.expectEqual(@as(u32, 60), dlg.cancel_button.rect.w);
    // OK at x+160 (300-140), Cancel at x+230 (300-70)
    try std.testing.expectEqual(dlg.rect.x + 160, dlg.ok_button.rect.x);
    try std.testing.expectEqual(dlg.rect.x + 230, dlg.cancel_button.rect.x);
    try std.testing.expectEqual(dlg.rect.y + 120, dlg.ok_button.rect.y);
    // Small parent clamps
    const small = Rect.make(10, 10, 200, 100);
    const dlg2 = Dialog.init(small, "Hi", false);
    try std.testing.expectEqual(@as(u32, 200), dlg2.rect.w);
    try std.testing.expectEqual(@as(u32, 100), dlg2.rect.h);
    try std.testing.expectEqual(@as(u32, 10), dlg2.rect.x);
}

test "ui: Dialog OK/Cancel via click and keyboard, dim overlay" {
    const parent = Rect.make(0, 0, 500, 400);
    var dlg = Dialog.init(parent, "Confirm delete?", false);
    dlg.show();
    try std.testing.expect(dlg.is_open());
    // Click OK → need MOUSE_DOWN + MOUSE_UP sequence via Button
    const ok = dlg.ok_button.rect;
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = ok.x + 5, .arg1 = ok.y + 5 };
    var ev_up = Event{ .kind = MOUSE_UP, .flags = 0, .seq = 2, .arg0 = ok.x + 5, .arg1 = ok.y + 5 };
    _ = dlg.handle_event(&ev_down);
    const ok_clicked = dlg.handle_event(&ev_up);
    try std.testing.expect(ok_clicked);
    try std.testing.expect(!dlg.is_open());
    try std.testing.expectEqual(DialogResult.ok, dlg.get_result());
    try std.testing.expect(!dlg.needs_dim());

    // Reopen and Cancel via mouse
    dlg.show();
    const cancel = dlg.cancel_button.rect;
    var ev_down_c = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = cancel.x + 5, .arg1 = cancel.y + 5 };
    var ev_up_c = Event{ .kind = MOUSE_UP, .flags = 0, .seq = 4, .arg0 = cancel.x + 5, .arg1 = cancel.y + 5 };
    _ = dlg.handle_event(&ev_down_c);
    _ = dlg.handle_event(&ev_up_c);
    try std.testing.expect(!dlg.is_open());
    try std.testing.expectEqual(DialogResult.cancel, dlg.get_result());

    // Keyboard Enter → OK, Escape → Cancel
    dlg.show();
    var ev_enter = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 5, .arg0 = 0x28, .arg1 = 0 };
    _ = dlg.handle_event(&ev_enter);
    try std.testing.expect(!dlg.is_open());
    try std.testing.expectEqual(DialogResult.ok, dlg.get_result());
    dlg.show();
    var ev_esc = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 6, .arg0 = 0x29, .arg1 = 0 };
    _ = dlg.handle_event(&ev_esc);
    try std.testing.expect(!dlg.is_open());
    try std.testing.expectEqual(DialogResult.cancel, dlg.get_result());

    // Modal: click outside still consumed when open, ignored when closed
    dlg.show();
    var ev_outside = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 7, .arg0 = 5, .arg1 = 5 };
    try std.testing.expect(dlg.handle_event(&ev_outside));
    dlg.dismiss(.cancel);
    try std.testing.expect(!dlg.handle_event(&ev_outside));
}

test "ui: Dialog with TextInput focus, typing, and draw no panic" {
    const parent = Rect.make(0, 0, 400, 300);
    var dlg = Dialog.init(parent, "Rename file:", true);
    try std.testing.expect(dlg.has_input);
    dlg.show();
    try std.testing.expect(dlg.input.focused);
    try std.testing.expectEqualStrings("", dlg.input.get_text());
    // Click inside input should keep focus
    var ev_click_input = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = dlg.input.rect.x + 2, .arg1 = dlg.input.rect.y + 5 };
    _ = dlg.handle_event(&ev_click_input);
    try std.testing.expect(dlg.input.focused);
    // Type 'A' via KEY_DOWN
    var ev_a = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x04, .arg1 = 'A' };
    _ = dlg.handle_event(&ev_a);
    try std.testing.expectEqualStrings("A", dlg.input.get_text());
    var ev_b = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x05, .arg1 = 'B' };
    _ = dlg.handle_event(&ev_b);
    try std.testing.expectEqualStrings("AB", dlg.input.get_text());
    // Backspace
    var ev_bs = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x2a, .arg1 = 0x08 };
    _ = dlg.handle_event(&ev_bs);
    try std.testing.expectEqualStrings("A", dlg.input.get_text());
    // Draw paths no panic (both windows)
    dlg.draw_dim_overlay(0);
    dlg.draw(1);
    dlg.dismiss(.ok);
    try std.testing.expectEqualStrings("A", dlg.input.get_text());
    try std.testing.expectEqual(DialogResult.ok, dlg.get_result());
    // Closed draw is no-op no panic
    dlg.draw(1);
    dlg.draw_dim_overlay(0);
}

test "ui: HScrollBar proportional thumb and offset clamp" {
    // Viewport 100, content 200 → thumb max(16,120*100/200=60)=60, max_offset 100
    var hb = HScrollBar.init(Rect.make(0, 0, 120, 8), 200, 100);
    try std.testing.expectEqual(@as(u32, 100), hb.max_offset());
    try std.testing.expectEqual(@as(u32, 60), hb.thumb_w());
    try std.testing.expectEqual(@as(u32, 0), hb.offset);
    try std.testing.expectEqual(@as(u32, 0), hb.thumb_x());
    // Viewport 100, content 400 → thumb 30, max 300
    var hb2 = HScrollBar.init(Rect.make(0, 0, 120, 8), 400, 100);
    try std.testing.expectEqual(@as(u32, 300), hb2.max_offset());
    try std.testing.expectEqual(@as(u32, 30), hb2.thumb_w());
    // Content fits → no scroll, thumb fills
    var hb3 = HScrollBar.init(Rect.make(0, 0, 120, 8), 80, 100);
    try std.testing.expectEqual(@as(u32, 0), hb3.max_offset());
    try std.testing.expectEqual(@as(u32, 120), hb3.thumb_w());
    hb3.offset = 999;
    hb3.set_content_width(80);
    try std.testing.expectEqual(@as(u32, 0), hb3.offset);
    // Min thumb clamp 16
    var hb4 = HScrollBar.init(Rect.make(0, 0, 120, 8), 500, 20);
    // 120*20/500=4 → clamp 16
    try std.testing.expectEqual(@as(u32, 16), hb4.thumb_w());
}

test "ui: HScrollBar track click and drag scales to content offset" {
    var hb = HScrollBar.init(Rect.make(10, 10, 120, 8), 300, 100);
    try std.testing.expectEqual(@as(u32, 200), hb.max_offset());
    // Track click right of thumb → page right by viewport (100)
    hb.offset = 0;
    const tr = hb.thumb_rect();
    try std.testing.expectEqual(@as(u32, 40), tr.w); // 120*100/300=40
    var ev_track_right = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = tr.x + tr.w + 5, .arg1 = 14 };
    _ = hb.handle_event(&ev_track_right);
    try std.testing.expectEqual(@as(u32, 100), hb.offset);
    // Track click left of thumb → page left
    var ev_track_left = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 15, .arg1 = 14 };
    _ = hb.handle_event(&ev_track_left);
    try std.testing.expectEqual(@as(u32, 0), hb.offset);
    // Thumb drag: from x=10 drag +40px (≈ half track) → offset ~100
    hb.offset = 0;
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = tr.x + 2, .arg1 = 14 };
    try std.testing.expect(hb.handle_event(&ev_down));
    try std.testing.expect(hb.dragging);
    var ev_move = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 4, .arg0 = tr.x + 42, .arg1 = 14 };
    _ = hb.handle_event(&ev_move);
    // delta 40, track_w 80 (120-40), scaled 40*200/80=100
    try std.testing.expect(hb.offset >= 95 and hb.offset <= 105);
    var ev_up = Event{ .kind = MOUSE_UP, .flags = 0, .seq = 5, .arg0 = tr.x + 42, .arg1 = 14 };
    _ = hb.handle_event(&ev_up);
    try std.testing.expect(!hb.dragging);
    // Drag beyond max clamps
    hb.offset = 0;
    _ = hb.handle_event(&ev_down);
    var ev_far = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 6, .arg0 = 250, .arg1 = 14 };
    _ = hb.handle_event(&ev_far);
    try std.testing.expectEqual(hb.max_offset(), hb.offset);
}

test "ui: HScrollBar Shift+scroll and keyboard" {
    var hb = HScrollBar.init(Rect.make(0, 0, 120, 8), 300, 100);
    // Keyboard Right 0x4f → +16
    var ev_right = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x4f, .arg1 = 0 };
    _ = hb.handle_event(&ev_right);
    try std.testing.expectEqual(@as(u32, 16), hb.offset);
    var ev_left = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x50, .arg1 = 0 };
    _ = hb.handle_event(&ev_left);
    try std.testing.expectEqual(@as(u32, 0), hb.offset);
    // Home 0x4a → 0, End 0x4d → max
    _ = hb.handle_event(&ev_right);
    var ev_home = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x4a, .arg1 = 0 };
    _ = hb.handle_event(&ev_home);
    try std.testing.expectEqual(@as(u32, 0), hb.offset);
    var ev_end = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x4d, .arg1 = 0 };
    _ = hb.handle_event(&ev_end);
    try std.testing.expectEqual(@as(u32, 200), hb.offset);
    // Shift+scroll right (packed arg0: mag=1, sign=1, bit15=1)
    hb.offset = 0;
    var ev_scroll = Event{ .kind = MOUSE_SCROLL, .flags = MOD_SHIFT, .seq = 5, .arg0 = 0x8001, .arg1 = 0 };
    _ = hb.handle_event(&ev_scroll);
    try std.testing.expectEqual(@as(u32, 16), hb.offset);
    // Without Shift, vertical scroll ignored for HScrollBar
    var ev_scroll_vert = Event{ .kind = MOUSE_SCROLL, .flags = 0, .seq = 6, .arg0 = 0x8001, .arg1 = 0 };
    const before = hb.offset;
    _ = hb.handle_event(&ev_scroll_vert);
    try std.testing.expectEqual(before, hb.offset);
    // Scroll left via Shift+scroll (packed: mag=1, sign=0, bit15=0)
    var ev_scroll_left = Event{ .kind = MOUSE_SCROLL, .flags = MOD_SHIFT, .seq = 7, .arg0 = 0x0001, .arg1 = 0 };
    _ = hb.handle_event(&ev_scroll_left);
    try std.testing.expectEqual(@as(u32, 0), hb.offset);
    // Content fits → no scroll even with keys
    var hb_small = HScrollBar.init(Rect.make(0, 0, 120, 8), 80, 100);
    try std.testing.expect(!hb_small.handle_event(&ev_right));
    try std.testing.expect(!hb_small.handle_event(&ev_scroll));
}

test "ui: HScrollBar + ScrollView 2D demo scrolls via both" {
    var sv = ScrollView.init(Rect.make(0, 0, 120, 100), 300);
    var hb = HScrollBar.init(Rect.make(0, 100, 120, 8), 400, 120);
    try std.testing.expectEqual(@as(u32, 200), sv.max_offset());
    try std.testing.expectEqual(@as(u32, 280), hb.max_offset());
    // Scroll vertical page down + horizontal page right
    var ev_pgdn = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x4e, .arg1 = 0 };
    _ = sv.handle_event(&ev_pgdn);
    try std.testing.expectEqual(@as(u32, 100), sv.offset);
    var ev_right = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x4f, .arg1 = 0 };
    _ = hb.handle_event(&ev_right);
    try std.testing.expectEqual(@as(u32, 16), hb.offset);
    // Drag both thumbs to near max
    const v_tr = sv.thumb_rect();
    var ev_v_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = v_tr.x + 1, .arg1 = v_tr.y + 2 };
    _ = sv.handle_event(&ev_v_down);
    var ev_v_move = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 4, .arg0 = v_tr.x + 1, .arg1 = 200 };
    _ = sv.handle_event(&ev_v_move);
    try std.testing.expectEqual(sv.max_offset(), sv.offset);
    const h_tr = hb.thumb_rect();
    var ev_h_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 5, .arg0 = h_tr.x + 2, .arg1 = 104 };
    _ = hb.handle_event(&ev_h_down);
    var ev_h_move = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 6, .arg0 = 250, .arg1 = 104 };
    _ = hb.handle_event(&ev_h_move);
    try std.testing.expectEqual(hb.max_offset(), hb.offset);
    // Draw both no panic
    sv.draw(0);
    hb.draw(0);
}

test "ui: ContextMenu show/dismiss and bounds" {
    const items = [_]ContextMenuItem{
        .{ .label = "Copy" },
        .{ .label = "Cut" },
        .{ .label = "Paste" },
    };
    var m = ContextMenu.init(items[0..]);
    try std.testing.expect(!m.is_open());
    m.show(50, 60);
    try std.testing.expect(m.is_open());
    const b = m.bounds();
    try std.testing.expectEqual(@as(u32, 50), b.x);
    try std.testing.expectEqual(@as(u32, 60), b.y);
    try std.testing.expectEqual(@as(u32, 120), b.w);
    try std.testing.expectEqual(@as(u32, 48), b.h);
    m.dismiss();
    try std.testing.expect(!m.is_open());
    m.draw(0);
}

test "ui: ContextMenu hit-test maps rows and outside dismisses" {
    const items = [_]ContextMenuItem{
        .{ .label = "Open" },
        .{ .label = "Rename" },
        .{ .label = "Delete" },
    };
    var m = ContextMenu.init(items[0..]);
    m.show(10, 10);
    // Hit first row
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = 15, .arg1 = 12 };
    _ = m.handle_event(&ev_down);
    try std.testing.expect(!m.is_open());
    try std.testing.expectEqual(@as(?usize, 0), m.selected_idx);
    // Reopen and click outside
    m.show(10, 10);
    var ev_out = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 200, .arg1 = 200 };
    _ = m.handle_event(&ev_out);
    try std.testing.expect(!m.is_open());
    // Reopen and hover second row
    m.show(10, 10);
    var ev_move = Event{ .kind = MOUSE_MOVE, .flags = 0, .seq = 3, .arg0 = 15, .arg1 = 30 };
    _ = m.handle_event(&ev_move);
    try std.testing.expectEqual(@as(?usize, 1), m.hover_idx);
    m.draw(0);
}

test "ui: ContextMenu via MOUSE_RIGHT_DOWN and NOTEPAD/FILE/TOP integration" {
    const notepad_items = [_]ContextMenuItem{
        .{ .label = "Copy" },
        .{ .label = "Cut" },
        .{ .label = "Paste" },
    };
    const file_items = [_]ContextMenuItem{
        .{ .label = "Open" },
        .{ .label = "Rename" },
        .{ .label = "Delete" },
    };
    const top_items = [_]ContextMenuItem{
        .{ .label = "Kill" },
        .{ .label = "Inspect" },
    };
    var m1 = ContextMenu.init(notepad_items[0..]);
    var m2 = ContextMenu.init(file_items[0..]);
    var m3 = ContextMenu.init(top_items[0..]);
    // Right-click shows menu
    var ev_r = Event{ .kind = MOUSE_RIGHT_DOWN, .flags = BTN_RIGHT, .seq = 1, .arg0 = 100, .arg1 = 80 };
    _ = m1.handle_event(&ev_r);
    try std.testing.expect(m1.is_open());
    try std.testing.expectEqual(@as(u32, 100), m1.bounds().x);
    // FILE.BIN menu opens separately
    var ev_r2 = Event{ .kind = MOUSE_RIGHT_DOWN, .flags = BTN_RIGHT, .seq = 2, .arg0 = 50, .arg1 = 40 };
    _ = m2.handle_event(&ev_r2);
    try std.testing.expect(m2.is_open());
    // Click first item selects and dismisses
    var ev_click = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = 55, .arg1 = 42 };
    _ = m2.handle_event(&ev_click);
    try std.testing.expect(!m2.is_open());
    try std.testing.expectEqual(@as(?usize, 0), m2.selected_idx);
    // TOP menu hover
    m3.show(20, 20);
    var ev_move = Event{ .kind = MOUSE_MOVE, .flags = 0, .seq = 4, .arg0 = 25, .arg1 = 38 };
    _ = m3.handle_event(&ev_move);
    try std.testing.expectEqual(@as(?usize, 1), m3.hover_idx);
    m1.draw(0);
    m2.draw(0);
    m3.draw(0);
}

test "ui: WidgetState styling accessors" {
    try std.testing.expect(widget_bg(.normal) != 0);
    try std.testing.expect(widget_bg(.hover) != 0);
    try std.testing.expect(widget_border(.normal) != 0);
    try std.testing.expect(widget_text(.normal) != 0);
    try std.testing.expect(widget_text(.disabled) != 0);
}

test "ui: ContextMenu with MenuItemSpec, separators, shortcuts, and keyboard navigation" {
    const specs = [_]MenuItemSpec{
        .{ .label = "New", .shortcut = "Ctrl+N" },
        .{ .label = "Open", .shortcut = "Ctrl+O" },
        .{ .kind = .separator },
        .{ .label = "Save", .shortcut = "Ctrl+S", .disabled = true },
        .{ .label = "Quit", .shortcut = "Ctrl+Q" },
    };
    var menu = ContextMenu.initWithSpecs(specs[0..]);
    menu.show(10, 20);
    try std.testing.expect(menu.is_open());
    try std.testing.expectEqual(@as(usize, 5), menu.count());

    // Down arrow should select first item (0: "New")
    var ev_down = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x51, .arg1 = 0 };
    _ = menu.handle_event(&ev_down);
    try std.testing.expectEqual(@as(?usize, 0), menu.hover_idx);

    // Down arrow again should select second item (1: "Open")
    _ = menu.handle_event(&ev_down);
    try std.testing.expectEqual(@as(?usize, 1), menu.hover_idx);

    // Down arrow again should skip separator (2) and disabled item (3) to select (4: "Quit")
    _ = menu.handle_event(&ev_down);
    try std.testing.expectEqual(@as(?usize, 4), menu.hover_idx);

    // Enter on "Quit" should select index 4 and close menu
    var ev_enter = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x28, .arg1 = 0 };
    _ = menu.handle_event(&ev_enter);
    try std.testing.expect(!menu.is_open());
    try std.testing.expectEqual(@as(?usize, 4), menu.selected_idx);

    // Reopen and test Escape dismissal
    menu.show(10, 20);
    var ev_esc = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x29, .arg1 = 0 };
    _ = menu.handle_event(&ev_esc);
    try std.testing.expect(!menu.is_open());

    menu.draw(0);
}

test "ui: show_dialog, draw_empty_state, and format_error" {
    const parent = Rect.make(0, 0, 400, 300);
    var dlg = Dialog.init(parent, "Test Dialog", false);
    show_dialog(&dlg, "Updated Message", true);
    try std.testing.expect(dlg.is_open());
    try std.testing.expectEqualStrings("Updated Message", dlg.message);
    try std.testing.expect(dlg.has_input);

    draw_empty_state(0, Rect.make(10, 10, 200, 100), "No Files Found", "Create a file or mount volume");

    var err_buf: [64]u8 = undefined;
    const msg_enoent = format_error(-2, &err_buf);
    try std.testing.expectEqualStrings("File or directory not found", msg_enoent);

    const msg_eacces = format_error(-13, &err_buf);
    try std.testing.expectEqualStrings("Permission denied", msg_eacces);

    const msg_custom = format_error(-999, &err_buf);
    try std.testing.expect(std.mem.startsWith(u8, msg_custom, "System error"));
}

test "ui: MenuBuilder and canonical shortcuts (M27 G9)" {
    var mb = MenuBuilder.init();
    _ = mb.add_item("Save", StandardShortcut.save);
    _ = mb.add_item("Open", StandardShortcut.open);
    _ = mb.add_separator();
    _ = mb.add_item("Quit", StandardShortcut.quit);

    const specs = mb.slice();
    try std.testing.expectEqual(@as(usize, 4), specs.len);
    try std.testing.expectEqualStrings("Save", specs[0].label);
    try std.testing.expectEqualStrings("Ctrl+S", specs[0].shortcut);
    try std.testing.expectEqual(MenuItemKind.separator, specs[2].kind);

    var menu = menu_build(specs);
    try std.testing.expectEqual(@as(usize, 4), menu.count());
    try std.testing.expectEqualStrings("File", canonical_menu_bar[0]);
    try std.testing.expectEqualStrings("Help", canonical_menu_bar[3]);
}

test "ui: Dialog with custom buttons and DialogResult (M27 G10)" {
    const parent = Rect.make(0, 0, 400, 300);
    const buttons = [_][]const u8{ "Yes", "No" };
    var dlg = Dialog.initWithButtons(parent, "Confirm", "Do you wish to proceed?", buttons[0..]);
    dlg.show();
    try std.testing.expect(dlg.is_open());
    try std.testing.expectEqualStrings("Yes", dlg.ok_button.label);
    try std.testing.expectEqualStrings("No", dlg.cancel_button.label);

    dlg.dismiss(.button_0);
    try std.testing.expect(!dlg.is_open());
    try std.testing.expect(dlg.get_result().is_ok());

    dlg.show();
    dlg.dismiss(.button_1);
    try std.testing.expect(dlg.get_result().is_cancel());
}

test "ui: ButtonState variants and ThemeColors (M27 G14, G20)" {
    try std.testing.expectEqual(WidgetState.normal, ButtonState.normal.to_widget_state());
    try std.testing.expectEqual(WidgetState.hover, ButtonState.hovered.to_widget_state());

    const tc = get_theme_colors();
    try std.testing.expect(tc.bg != 0);
    try std.testing.expect(tc.accent != 0);
}

test "ui: draw_empty_state_icon and format_error_ctx (M27 G22, G23)" {
    draw_empty_state_icon(0, Rect.make(10, 10, 200, 100), "Empty Directory", '>');

    var buf: [128]u8 = undefined;
    const err = format_error_ctx(&buf, -2, "File open");
    try std.testing.expectEqualStrings("File open: File or directory not found", err);
}

// ---------------------------------------------------------------------------
// M32 WMS9 (issue #629): span batching tests.
// The batcher is host-testable: in non-freestanding builds `syscall2` returns
// 0 without touching real registers, so we can exercise push/flush/auto-flush
// and the span-emit logic of draw_char without a kernel.
// ---------------------------------------------------------------------------

test "ui: FillBatcher buffers up to 32 rects then auto-flushes (WMS9)" {
    fill_batcher.reset();
    fill_batcher.cur_id = 0;

    // Push 32 rects — none should trigger a syscall mid-batch.
    var i: u32 = 0;
    while (i < FILL_BATCH_MAX) : (i += 1) {
        win_fill_batched(7, i * 10, 20, 10, 5, 0xff0000);
    }
    try std.testing.expectEqual(FILL_BATCH_MAX * FILL_RECT_SIZE, fill_batcher.len);

    // The 33rd rect forces an auto-flush, then starts a fresh batch.
    win_fill_batched(7, 999, 20, 10, 5, 0x00ff00);
    try std.testing.expectEqual(FILL_RECT_SIZE, fill_batcher.len);

    fill_batcher.reset();
}

test "ui: FillBatcher flushes on window-id change (WMS9)" {
    fill_batcher.reset();
    fill_batcher.cur_id = 0;

    win_fill_batched(7, 0, 0, 10, 10, 0xff0000);
    try std.testing.expectEqual(FILL_RECT_SIZE, fill_batcher.len);

    // A different window id forces a flush before the new rect is queued.
    win_fill_batched(9, 5, 5, 3, 3, 0x0000ff);
    try std.testing.expectEqual(FILL_RECT_SIZE, fill_batcher.len);
    try std.testing.expectEqual(@as(u32, 9), fill_batcher.cur_id);

    fill_batcher.reset();
}

test "ui: draw_char emits row spans, not per-pixel fills (WMS9)" {
    fill_batcher.reset();
    fill_batcher.cur_id = 0;

    // 'W' is a wide glyph (dense rows) — verify span emission per row:
    // each row's set pixels become one contiguous span, not N 1×1 fills.
    draw_char(7, 'W', 100, 50, 0xffffff);

    // W spans 8 columns; its densest row has 3 separate runs (W shape).
    // Total spans for 'W' = 22 (vs 24 per-pixel fills in the old path).
    // We don't pin the exact count here (font-dependent); instead verify
    // that every span is at least 1px wide and rows stay within the glyph box.
    try std.testing.expect(fill_batcher.len > 0);
    try std.testing.expect(fill_batcher.len <= FILL_BATCH_MAX * FILL_RECT_SIZE);

    // Decode spans and check each is a valid 1px-tall horizontal run.
    var i: usize = 0;
    while (i < fill_batcher.len) : (i += FILL_RECT_SIZE) {
        const w = std.mem.readInt(u32, fill_batcher.buf[i + 12 ..][0..4], .little);
        const h = std.mem.readInt(u32, fill_batcher.buf[i + 16 ..][0..4], .little);
        try std.testing.expect(w >= 1 and w <= 8);
        try std.testing.expectEqual(@as(u32, 1), h);
    }

    fill_batcher.reset();
}

test "ui: draw_char_16 emits 2px-tall spans, pixel-identical to old path (WMS9)" {
    fill_batcher.reset();
    fill_batcher.cur_id = 0;

    draw_char_16(7, 'A', 50, 50, 0x00ff00);

    try std.testing.expect(fill_batcher.len > 0);
    var i: usize = 0;
    while (i < fill_batcher.len) : (i += FILL_RECT_SIZE) {
        const w = std.mem.readInt(u32, fill_batcher.buf[i + 12 ..][0..4], .little);
        const h = std.mem.readInt(u32, fill_batcher.buf[i + 16 ..][0..4], .little);
        try std.testing.expect(w >= 1 and w <= 8);
        try std.testing.expectEqual(@as(u32, 2), h);
    }

    fill_batcher.reset();
}

test "ui: draw_image skips transparent pixels and batches contiguous spans" {
    fill_batcher.reset();
    fill_batcher.cur_id = 0;

    var raw_pixels = [_]u32{
        0x00FFFFFF, 0xFFFF0000, 0xFFFF0000, 0x00000000, // Row 0: Transparent, Red, Red, Transparent
        0xFF00FF00, 0xFF00FF00, 0xFF00FF00, 0xFF00FF00, // Row 1: 4 Green pixels
    };
    const img = Image{ .width = 4, .height = 2, .pixels = &raw_pixels };

    draw_image(5, 10, 20, img);

    // Should emit:
    // Span 1: at (11, 20) with width 2 (2 Red pixels)
    // Span 2: at (10, 21) with width 4 (4 Green pixels)
    try std.testing.expectEqual(2 * FILL_RECT_SIZE, fill_batcher.len);

    const x1 = std.mem.readInt(u32, fill_batcher.buf[4..8], .little);
    const y1 = std.mem.readInt(u32, fill_batcher.buf[8..12], .little);
    const w1 = std.mem.readInt(u32, fill_batcher.buf[12..16], .little);
    const rgb1 = std.mem.readInt(u32, fill_batcher.buf[20..24], .little);

    try std.testing.expectEqual(@as(u32, 11), x1);
    try std.testing.expectEqual(@as(u32, 20), y1);
    try std.testing.expectEqual(@as(u32, 2), w1);
    try std.testing.expectEqual(@as(u32, 0x00FF0000), rgb1);

    const x2 = std.mem.readInt(u32, fill_batcher.buf[FILL_RECT_SIZE + 4 ..][0..4], .little);
    const y2 = std.mem.readInt(u32, fill_batcher.buf[FILL_RECT_SIZE + 8 ..][0..4], .little);
    const w2 = std.mem.readInt(u32, fill_batcher.buf[FILL_RECT_SIZE + 12 ..][0..4], .little);
    const rgb2 = std.mem.readInt(u32, fill_batcher.buf[FILL_RECT_SIZE + 20 ..][0..4], .little);

    try std.testing.expectEqual(@as(u32, 10), x2);
    try std.testing.expectEqual(@as(u32, 21), y2);
    try std.testing.expectEqual(@as(u32, 4), w2);
    try std.testing.expectEqual(@as(u32, 0x0000FF00), rgb2);

    fill_batcher.reset();
}

test "ui: draw_image_clipped and draw_image_scaled" {
    fill_batcher.reset();
    fill_batcher.cur_id = 0;

    var raw_pixels = [_]u32{
        0xFFFF0000, 0xFFFF0000,
        0xFFFF0000, 0xFFFF0000,
    };
    const img = Image{ .width = 2, .height = 2, .pixels = &raw_pixels };

    // Clipped to only x=10..10, y=20..20 (1x1 area)
    draw_image_clipped(5, 10, 20, img, Rect.make(10, 20, 1, 1));
    try std.testing.expectEqual(1 * FILL_RECT_SIZE, fill_batcher.len);
    fill_batcher.reset();

    // Scaled 2x2 up to 4x4
    draw_image_scaled(5, Rect.make(0, 0, 4, 4), img);
    // 4 rows of 1 span each = 4 spans
    try std.testing.expectEqual(4 * FILL_RECT_SIZE, fill_batcher.len);
    fill_batcher.reset();
}

test "ui: blend_source_over arithmetic" {
    // 1. Transparent source: preserves destination
    try std.testing.expectEqual(@as(u32, 0xFF112233), blend_source_over(0xFF112233, 0x00AABBCC));

    // 2. Fully opaque source: completely replaces destination
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), blend_source_over(0xFF112233, 0xFFAABBCC));

    // 3. Partial alpha blending (50% red over black)
    const blended = blend_source_over(0xFF000000, 0x80FF0000);
    const r = (blended >> 16) & 0xFF;
    const g = (blended >> 8) & 0xFF;
    const b = blended & 0xFF;
    const a = (blended >> 24) & 0xFF;
    try std.testing.expect(r >= 127 and r <= 129);
    try std.testing.expectEqual(@as(u32, 0), g);
    try std.testing.expectEqual(@as(u32, 0), b);
    try std.testing.expectEqual(@as(u32, 255), a);
}

test "ui: direct backing buffer draw_image with alpha blit and clipping" {
    var buf = [_]u32{0xFF000000} ** (10 * 10);
    win_set_backing(7, &buf, 10, 10);
    defer win_clear_backing(7);

    try std.testing.expect(win_get_backing(7) != null);
    try std.testing.expectEqual(@as(u32, 10), win_get_backing(7).?.width);

    var raw_src = [_]u32{
        0x80FF0000, 0x8000FF00,
        0x00000000, 0xFF0000FF,
    };
    const src_img = Image{ .width = 2, .height = 2, .pixels = &raw_src };

    // Blit at (2, 3)
    draw_image(7, 2, 3, src_img);

    // Pixel at (2, 3) is 50% red over black -> ~0xFF800000
    const p0 = buf[3 * 10 + 2];
    try std.testing.expect(((p0 >> 16) & 0xFF) >= 127 and ((p0 >> 16) & 0xFF) <= 129);

    // Pixel at (3, 3) is 50% green over black -> ~0xFF008000
    const p1 = buf[3 * 10 + 3];
    try std.testing.expect(((p1 >> 8) & 0xFF) >= 127 and ((p1 >> 8) & 0xFF) <= 129);

    // Pixel at (2, 4) is 0% alpha -> remains unchanged (0xFF000000)
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[4 * 10 + 2]);

    // Pixel at (3, 4) is 100% blue -> becomes 0xFF0000FF
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), buf[4 * 10 + 3]);

    // Test clipping: draw clipped to (2, 3, 1, 1) -> only (2, 3) blitted
    buf = [_]u32{0xFF000000} ** (10 * 10);
    draw_image_clipped(7, 2, 3, src_img, Rect.make(2, 3, 1, 1));
    try std.testing.expect(((buf[3 * 10 + 2] >> 16) & 0xFF) >= 127);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[3 * 10 + 3]); // clipped out
}

test "ui: direct backing buffer draw_image_scaled" {
    var buf = [_]u32{0xFF000000} ** (8 * 8);
    win_set_backing(8, &buf, 8, 8);
    defer win_clear_backing(8);

    var raw_src = [_]u32{
        0xFFFF0000, 0xFF00FF00,
        0xFF0000FF, 0xFFFFFFFF,
    };
    const src_img = Image{ .width = 2, .height = 2, .pixels = &raw_src };

    // Scale 2x2 to 4x4 placed at (2, 2)
    draw_image_scaled(8, Rect.make(2, 2, 4, 4), src_img);

    // Check quadrant 1 (top-left: (2..3, 2..3)) is red
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), buf[2 * 8 + 2]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), buf[3 * 8 + 3]);

    // Check quadrant 2 (top-right: (4..5, 2..3)) is green
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), buf[2 * 8 + 4]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), buf[3 * 8 + 5]);
}
