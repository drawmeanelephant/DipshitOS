//! virelai-probe.zig — contract-level compile probe, the Zig sibling of
//! tests/virelai-probe.c (W3 #764 acceptance item, extended to the
//! `virelai.zig` shim by claim 4912). References EVERY frozen import so
//! wasm-ld retains the full `env.*` import table;
//! tools/verify-virelai-probe.py asserts the exact set. Not runnable —
//! the imports are dispatched by the interpreter.
const v = @import("virelai.zig");

var g_dirs: [2]v.VDirEntry = undefined;
var g_audio: v.VAudioInfo = undefined;
var g_buf: [64]u8 = undefined;

export fn _start() noreturn {
    var acc: i64 = 0;
    acc += @as(i64, v.write(1, &g_buf, 0));
    acc += @as(i64, v.file_open("/host/X", 8, v.V_MODE_READ));
    acc += @as(i64, v.file_read(0, &g_buf, 64));
    acc += @as(i64, v.file_write(0, &g_buf, 0));
    acc += @as(i64, v.file_close(0));
    acc += @as(i64, v.dir_list(&g_buf, 0, @ptrCast(&g_dirs), 2));
    acc += @as(i64, v.file_delete(&g_buf, 0));
    acc += @as(i64, v.file_rename(&g_buf, 0, &g_buf, 0));
    acc += @as(i64, v.file_truncate(0, 0));
    acc += @as(i64, v.file_free(0));
    acc += @as(i64, v.win_open(0, 0, 0, 0));
    acc += @as(i64, v.win_fill(0, 0, 0, 0, 0, 0));
    acc += @as(i64, v.win_present(0));
    acc += @as(i64, v.win_close(0));
    acc += @as(i64, v.win_move(0, 0, 0));
    acc += @as(i64, v.win_raise(0));
    acc += @as(i64, v.win_get(0, &g_buf));
    acc += @as(i64, v.win_query(0, &g_buf));
    acc += @as(i64, v.win_set_visible(0, 0));
    acc += @as(i64, v.audio_info(@ptrCast(&g_audio)));
    acc += @as(i64, v.audio_play(&g_buf, 0));
    acc += @as(i64, v.audio_volume(0));
    acc += @as(i64, v.audio_mute(0));
    acc += @as(i64, v.timer_set(0));
    acc += @as(i64, v.timer_cancel());
    acc += @as(i64, v.mmap(0, 0, 0, 0));
    acc += @as(i64, v.munmap(0, 0));
    acc += @as(i64, v.procs(&g_buf, 0));
    acc += @as(i64, v.wait(0));
    v.exit(@intCast(acc));
}
