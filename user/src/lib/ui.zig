//! DipshitOS Micro-Widget Toolkit & Runtime (ADR 0011, Milestone 11).
//!
//! Reusable, lightweight GUI primitives with ZERO heap allocation.
//! All widget structures are pure value types operating over static BSS
//! or stack buffers.

const std = @import("std");
pub const font8x8 = @import("font8x8.zig");

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
pub const sys_udp_listen_num: u64 = 9;
pub const sys_udp_send_num: u64 = 10;
pub const sys_udp_recv_num: u64 = 11;
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
// Theme Palette Constants (ADR 0008 & ADR 0011)
// ---------------------------------------------------------------------------

pub const COLOR_BG: u32 = 0x182026;
pub const COLOR_SURFACE: u32 = 0x222d35;
pub const COLOR_BORDER: u32 = 0x334155;
pub const COLOR_TEXT_PRIMARY: u32 = 0xffffff;
pub const COLOR_TEXT_MUTED: u32 = 0x94a3b8;
pub const COLOR_ACCENT: u32 = 0x3b82f6;
pub const COLOR_BTN_IDLE: u32 = 0x2d3748;
pub const COLOR_BTN_HOVER: u32 = 0x4a5568;
pub const COLOR_BTN_PRESSED: u32 = 0x1a202c;
pub const COLOR_SUCCESS: u32 = 0x22c55e;
pub const COLOR_DANGER: u32 = 0xef4444;
pub const COLOR_WARNING: u32 = 0xf59e0b;

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

pub fn win_present(id: u32) void {
    _ = syscall1(sys_win_present_num, id);
}

pub fn win_close(id: u32) void {
    _ = syscall1(sys_win_close_num, id);
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

pub fn udp_listen(port: u16) i64 {
    return syscall1(sys_udp_listen_num, port);
}

pub fn udp_send(dst_ip: u32, dst_port: u16, payload: []const u8) i64 {
    return syscall4(sys_udp_send_num, dst_ip, dst_port, @intFromPtr(payload.ptr), payload.len);
}

pub fn udp_recv(port: u16, buf: []u8) i64 {
    return syscall3(sys_udp_recv_num, port, @intFromPtr(buf.ptr), buf.len);
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
    win_fill(win_id, rect.x, rect.y, rect.w, rect.h, rgb);
}

pub fn draw_rect_outline(win_id: u32, rect: Rect, thickness: u32, rgb: u32) void {
    if (rect.w == 0 or rect.h == 0 or thickness == 0) return;
    // Top
    win_fill(win_id, rect.x, rect.y, rect.w, thickness, rgb);
    // Bottom
    if (rect.h > thickness) {
        win_fill(win_id, rect.x, rect.y + rect.h - thickness, rect.w, thickness, rgb);
    }
    // Left
    win_fill(win_id, rect.x, rect.y, thickness, rect.h, rgb);
    // Right
    if (rect.w > thickness) {
        win_fill(win_id, rect.x + rect.w - thickness, rect.y, thickness, rect.h, rgb);
    }
}

pub fn draw_char(win_id: u32, ch: u8, x: u32, y: u32, fg_rgb: u32) void {
    if (ch < 0x20 or ch > 0x7e) return;
    const glyph = font8x8.glyphs[ch - 0x20];
    var row_idx: usize = 0;
    while (row_idx < 8) : (row_idx += 1) {
        const row_byte = glyph[row_idx];
        var col_idx: usize = 0;
        while (col_idx < 8) : (col_idx += 1) {
            if (font8x8.row_pixel(row_byte, col_idx)) {
                win_fill(win_id, x + @as(u32, @intCast(col_idx)), y + @as(u32, @intCast(row_idx)), 1, 1, fg_rgb);
            }
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
// Component: Button
// ---------------------------------------------------------------------------

pub const ButtonState = enum { idle, hover, pressed };

pub const Button = struct {
    rect: Rect,
    label: []const u8,
    state: ButtonState = .idle,
    bg_color: ?u32 = null,
    text_color: u32 = COLOR_TEXT_PRIMARY,
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
        const bg = if (self.is_active)
            COLOR_ACCENT
        else if (self.bg_color) |c|
            c
        else switch (self.state) {
            .idle => COLOR_BTN_IDLE,
            .hover => COLOR_BTN_HOVER,
            .pressed => COLOR_BTN_PRESSED,
        };

        draw_rect(win_id, self.rect, bg);
        draw_rect_outline(win_id, self.rect, 1, if (self.is_active) COLOR_TEXT_PRIMARY else COLOR_BORDER);
        draw_text_centered(win_id, self.label, self.rect, self.text_color);
    }
};

// ---------------------------------------------------------------------------
// Component: Label
// ---------------------------------------------------------------------------

pub const Label = struct {
    rect: Rect,
    text: []const u8,
    color: u32 = COLOR_TEXT_PRIMARY,
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
        draw_rect(win_id, self.rect, COLOR_SURFACE);
        draw_rect_outline(win_id, self.rect, 1, if (self.focused) COLOR_ACCENT else COLOR_BORDER);

        const text_y = self.rect.y + (self.rect.h - 8) / 2;
        const text_x = self.rect.x + 4;
        draw_text(win_id, self.get_text(), text_x, text_y, COLOR_TEXT_PRIMARY);

        // Draw cursor bar if focused
        if (self.focused) {
            const cursor_x = text_x + @as(u32, @intCast(self.cursor)) * 8;
            if (cursor_x + 2 <= self.rect.x + self.rect.w) {
                win_fill(win_id, cursor_x, text_y, 2, 8, COLOR_TEXT_PRIMARY);
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
            COLOR_ACCENT
        else if (row % 2 == 0)
            COLOR_SURFACE
        else
            COLOR_BG;

        draw_rect(win_id, row_rect, bg);
        draw_text(win_id, text, row_rect.x + 4, row_rect.y + (self.row_height - 8) / 2, COLOR_TEXT_PRIMARY);
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
