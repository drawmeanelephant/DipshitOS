//! VirelaiOS Dynamically Linked User Application (DYNAPP.BIN, Milestone 30).
//!
//! Uses LIBUI.SO and LIBFONT.SO loaded by LD.SO runtime linker at EL0.

const std = @import("std");

pub const Event = extern struct {
    kind: u16,
    flags: u16,
    seq: u32,
    arg0: u32,
    arg1: u32,
};

// External symbols imported from LIBUI.SO
extern fn ui_win_open(title: [*:0]const u8, x: u32, y: u32, w: u32, h: u32, flags: u32) i64;
extern fn ui_win_fill(wid: u32, x: u32, y: u32, w: u32, h: u32, color: u32) i64;
extern fn ui_win_present(wid: u32) i64;
extern fn ui_win_close(wid: u32) i64;
extern fn ui_poll_event(ev: *Event) i64;
extern fn ui_wait_event(ev: *Event) i64;
extern fn ui_write(fd: u64, buf: [*]const u8, len: usize) i64;
extern fn ui_exit(code: u64) noreturn;
extern fn ui_theme_bg() u32;
extern fn ui_theme_surface() u32;
extern fn ui_theme_border() u32;
extern fn ui_theme_text_primary() u32;
extern fn ui_theme_accent() u32;
extern fn ui_draw_string(wid: u32, text: [*:0]const u8, x: u32, y: u32, fg: u32) void;
extern fn ui_draw_button(wid: u32, text: [*:0]const u8, x: u32, y: u32, w: u32, h: u32, hovered: bool, pressed: bool) void;

// External symbols imported from LIBFONT.SO
extern fn font_measure_8x8(str: [*:0]const u8) u32;

pub export fn _start() callconv(.c) noreturn {
    _ = ui_write(1, "dynapp: launched via LD.SO dynamic runtime linker!\n", 51);

    const wid_res = ui_win_open("Dynamic App", 120, 100, 320, 200, 0);
    if (wid_res < 0) {
        _ = ui_write(1, "dynapp: failed to open window\n", 30);
        ui_exit(1);
    }
    const wid: u32 = @intCast(wid_res);

    _ = ui_win_fill(wid, 0, 0, 320, 200, ui_theme_bg());
    _ = ui_win_fill(wid, 10, 10, 300, 30, ui_theme_surface());
    ui_draw_string(wid, "VirelaiOS Dynamic Linking", 20, 20, ui_theme_accent());

    ui_draw_string(wid, "Shared libraries: LIBUI.SO, LIBFONT.SO", 20, 55, ui_theme_text_primary());
    ui_draw_button(wid, "Click Me", 20, 85, 100, 28, false, false);
    ui_draw_button(wid, "Exit", 130, 85, 80, 28, false, false);

    _ = ui_win_present(wid);
    _ = ui_write(1, "dynapp: window rendered, event loop active\n", 43);

    var ev: Event = undefined;
    var count: usize = 0;
    while (count < 10) : (count += 1) {
        if (ui_poll_event(&ev) > 0) {
            if (ev.kind == 8) break; // WIN_CLOSE
        }
        // Yield/sleep
        _ = asm volatile ("svc #0"
            :
            : [num] "{x8}" (@as(u64, 4)),
              [arg0] "{x0}" (@as(u64, 1)),
            : .{ .memory = true });
    }

    _ = ui_win_close(wid);
    _ = ui_write(1, "dynapp: dynamic execution complete, exiting status=0\n", 53);
    ui_exit(0);
}
