//! DipshitOS twenty-third ESP user program — CLIPTEST.BIN (Milestone 14,
//! Card S1, claim 2611).
//!
//! Headless class-B proof for the shared clipboard seam (ADR 0007 slots
//! 38/39): set → get (byte-exact) → truncated get (non-consuming) →
//! over-long set truncation → clear → empty → EFAULT on both directions —
//! one sequence, printing a marker after each step for
//! `tools/verify-live-clipboard.sh`.

const std = @import("std");
const ui = @import("lib/ui.zig");

fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    @memcpy(buf[pos .. pos + src.len], src);
    return pos + src.len;
}

fn fmt_u64(buf: []u8, value: u64) []const u8 {
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }
    return buf[i..];
}

pub export fn _start() callconv(.c) noreturn {
    // 1. Set "hello" (slot 38).
    const set_len = ui.clipboard_set("hello");
    if (set_len != 5) {
        ui.write_console("clip: set failed\n");
        ui.exit_process(1);
    }
    ui.write_console("clip: set 5\n");

    // 2. Get it back byte-exact (slot 39).
    var buf: [ui.clipboard_max]u8 = [_]u8{0} ** ui.clipboard_max;
    const got = ui.clipboard_get(&buf);
    if (got != 5 or !std.mem.eql(u8, buf[0..5], "hello")) {
        ui.write_console("clip: get failed\n");
        ui.exit_process(1);
    }
    ui.write_console("clip: got hello\n");

    // 3. A get with max=3 truncates and does NOT consume.
    var small: [8]u8 = [_]u8{0} ** 8;
    const trunc = ui.clipboard_get(small[0..3]);
    if (trunc != 3 or !std.mem.eql(u8, small[0..3], "hel")) {
        ui.write_console("clip: trunc failed\n");
        ui.exit_process(1);
    }
    ui.write_console("clip: trunc hel\n");

    // 4. The full content is still held (get is non-consuming).
    const again = ui.clipboard_get(&buf);
    if (again != 5 or !std.mem.eql(u8, buf[0..5], "hello")) {
        ui.write_console("clip: still failed\n");
        ui.exit_process(1);
    }
    ui.write_console("clip: still hello\n");

    // 5. EFAULT: a bad pointer is refused on both directions (a raw
    //    address outside every EL0 region — the claim-6120 contract). The
    //    clipboard is NON-EMPTY here ("hello" still held), so the get path
    //    reaches the copy_out validation instead of the empty-clipboard 0.
    if (ui.syscall2(ui.sys_clipboard_set_num, 0xF0000000, 5) != -3) {
        ui.write_console("clip: set efault failed\n");
        ui.exit_process(1);
    }
    ui.write_console("clip: set efault\n");
    if (ui.syscall2(ui.sys_clipboard_get_num, 0xF0000000, 5) != -3) {
        ui.write_console("clip: get efault failed\n");
        ui.exit_process(1);
    }
    ui.write_console("clip: get efault\n");

    // 6. An over-long set truncates at clip_max and reports the stored
    //    length (the documented truncation).
    var big: [ui.clipboard_max + 10]u8 = [_]u8{'x'} ** (ui.clipboard_max + 10);
    const capped = ui.clipboard_set(&big);
    if (capped != ui.clipboard_max) {
        ui.write_console("clip: cap failed\n");
        ui.exit_process(1);
    }
    var capbuf: [64]u8 = undefined;
    var cpos: usize = 0;
    cpos = append_str(&capbuf, cpos, "clip: cap ");
    cpos = append_str(&capbuf, cpos, fmt_u64(capbuf[cpos..], @intCast(capped)));
    capbuf[cpos] = '\n';
    ui.write_console(capbuf[0 .. cpos + 1]);

    // 7. A zero-length set clears; a following get returns 0.
    if (ui.clipboard_set("") != 0) {
        ui.write_console("clip: clear failed\n");
        ui.exit_process(1);
    }
    ui.write_console("clip: cleared\n");
    if (ui.clipboard_get(&buf) != 0) {
        ui.write_console("clip: empty failed\n");
        ui.exit_process(1);
    }
    ui.write_console("clip: empty\n");

    ui.write_console("clip: done\n");
    ui.exit_process(0);
}
