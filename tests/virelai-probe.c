/*
 * virelai-probe.c — contract-level compile probe (W3 #764 acceptance
 * item: "the virelai.h shim compiles a host program against the contract
 * alone"). References EVERY frozen import so wasm-ld retains the full
 * `env.*` import table; tools/verify-virelai-probe.py asserts the exact
 * set. Not runnable — the imports are dispatched by the interpreter.
 */
#include "virelai.h"

struct v_dirent g_dirs[2];
struct v_audio_info g_audio;
static char g_buf[64];

void _start(void) {
    long acc = 0;
    acc += v_write(1, g_buf, 0);
    acc += v_file_open("/host/X", 8, V_MODE_READ);
    acc += v_file_read(0, g_buf, 64);
    acc += v_file_write(0, g_buf, 0);
    acc += v_file_close(0);
    acc += v_dir_list(g_buf, 0, g_dirs, 2);
    acc += v_file_delete(g_buf, 0);
    acc += v_file_rename(g_buf, 0, g_buf, 0);
    acc += v_file_truncate(0, 0);
    acc += v_file_free(0);
    acc += v_win_open(0, 0, 0, 0);
    acc += v_win_fill(0, 0, 0, 0, 0, 0);
    acc += v_win_present(0);
    acc += v_win_close(0);
    acc += v_win_move(0, 0, 0);
    acc += v_win_raise(0);
    acc += v_win_get(0, g_buf);
    acc += v_win_query(0, g_buf);
    acc += v_win_set_visible(0, 0);
    acc += v_audio_info(&g_audio);
    acc += v_audio_play(g_buf, 0);
    acc += v_audio_volume(0);
    acc += v_audio_mute(0);
    acc += v_timer_set(0);
    acc += v_timer_cancel();
    acc += v_mmap(0, 0, 0, 0);
    acc += v_munmap(0, 0);
    acc += v_procs(g_buf, 0);
    acc += v_wait(0);
    v_exit((int)acc);
}