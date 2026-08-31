//! VirelaiOS Shared UI Library (LIBUI.SO, Milestone 30 Dynamic Linking, ADR 0011).
//!
//! Freestanding shared library implementing GUI window primitives, micro-widgets,
//! theme styling, and event polling with zero libc/POSIX dependencies.

const std = @import("std");
pub const ui = @import("lib/ui.zig");
pub const font8x8 = @import("lib/font8x8.zig");

// Re-export common syscall numbers and types
pub const Event = ui.Event;
pub const Rect = ui.Rect;
pub const Color = u32;

pub export fn ui_win_open(title: [*:0]const u8, x: u32, y: u32, w: u32, h: u32, flags: u32) i64 {
    const title_slice = std.mem.sliceTo(title, 0);
    return ui.syscall6(ui.sys_win_open_num, @intFromPtr(title_slice.ptr), title_slice.len, x | (@as(u64, y) << 32), w | (@as(u64, h) << 32), flags, 0);
}

pub export fn ui_win_fill(wid: u32, x: u32, y: u32, w: u32, h: u32, color: u32) i64 {
    return ui.syscall6(ui.sys_win_fill_num, wid, x | (@as(u64, y) << 32), w | (@as(u64, h) << 32), color, 0, 0);
}

/// M32 WMS9 (issue #629): batched fills — one SVC per up-to-32 rects
/// (slot 46). The shared library exposes the same FillBatcher the static
/// toolkit uses, so dynamically-linked apps get the same syscall collapse.
pub export fn ui_win_fill_batched(wid: u32, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    ui.win_fill_batched(wid, x, y, w, h, color);
}

pub export fn ui_flush_fills() void {
    ui.flush_fills();
}

pub export fn ui_win_present(wid: u32) i64 {
    return ui.syscall1(ui.sys_win_present_num, wid);
}

pub export fn ui_win_close(wid: u32) i64 {
    return ui.syscall1(ui.sys_win_close_num, wid);
}

pub export fn ui_poll_event(ev: *Event) i64 {
    return ui.syscall1(ui.sys_poll_event_num, @intFromPtr(ev));
}

pub export fn ui_wait_event(ev: *Event) i64 {
    return ui.syscall1(ui.sys_wait_event_num, @intFromPtr(ev));
}

pub export fn ui_write(fd: u64, buf: [*]const u8, len: usize) i64 {
    return ui.syscall3(ui.sys_write_num, fd, @intFromPtr(buf), len);
}

pub export fn ui_exit(code: u64) noreturn {
    _ = ui.syscall1(ui.sys_exit_num, code);
    while (true) {}
}

pub export fn ui_theme_bg() u32 {
    return ui.theme_bg();
}

pub export fn ui_theme_surface() u32 {
    return ui.theme_surface();
}

pub export fn ui_theme_border() u32 {
    return ui.theme_border();
}

pub export fn ui_theme_text_primary() u32 {
    return ui.theme_text_primary();
}

pub export fn ui_theme_text_muted() u32 {
    return ui.theme_text_muted();
}

pub export fn ui_theme_accent() u32 {
    return ui.theme_accent();
}

pub export fn ui_theme_btn_pressed() u32 {
    return ui.theme_btn_pressed();
}

pub export fn ui_theme_btn_hover() u32 {
    return ui.theme_btn_hover();
}

pub export fn ui_theme_btn_idle() u32 {
    return ui.theme_btn_idle();
}

pub export fn ui_draw_char_8x8(wid: u32, char: u8, px: u32, py: u32, fg: u32) void {
    ui.draw_char(wid, char, px, py, fg);
}

pub export fn ui_draw_string(wid: u32, text: [*:0]const u8, x: u32, y: u32, fg: u32) void {
    const str = std.mem.sliceTo(text, 0);
    ui.draw_text(wid, str, x, y, fg);
}

pub export fn ui_draw_rect(wid: u32, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    ui.draw_rect(wid, ui.Rect.make(x, y, w, h), color);
}

pub export fn ui_draw_button(wid: u32, text: [*:0]const u8, x: u32, y: u32, w: u32, h: u32, hovered: bool, pressed: bool) void {
    const bg_color = if (pressed) ui.theme_btn_pressed() else if (hovered) ui.theme_btn_hover() else ui.theme_btn_idle();
    ui.win_fill_batched(wid, x, y, w, h, bg_color);
    ui.win_fill_batched(wid, x, y, w, 1, ui.theme_border());
    ui.win_fill_batched(wid, x, y + h - 1, w, 1, ui.theme_border());
    ui.win_fill_batched(wid, x, y, 1, h, ui.theme_border());
    ui.win_fill_batched(wid, x + w - 1, y, 1, h, ui.theme_border());

    const str = std.mem.sliceTo(text, 0);
    const text_w = @as(u32, @intCast(str.len)) * 8;
    const tx = if (w > text_w) x + (w - text_w) / 2 else x + 2;
    const ty = if (h > 8) y + (h - 8) / 2 else y + 2;
    ui.draw_text(wid, str, tx, ty, ui.theme_text_primary());
}
