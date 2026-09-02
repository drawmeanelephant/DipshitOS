/*
 * fileapp.c — W3 live-gate fixture (issue #764): a wasm file app. Opens
 * /host/FILE.TXT through env.file_open (M34 HF4 share transport),
 * streams it in 128-byte chunks with env.file_read, echoes each chunk
 * byte-exact to the console with env.write, and exits with the total
 * byte count (512 for the gate's fixture — asserted in the process
 * report). Written against tests/virelai.h alone.
 */
#include "virelai.h"

static char g_buf[128];

void _start(void) {
    int fd = v_file_open("/host/FILE.TXT", 14, V_MODE_READ);
    if (fd < 0) {
        v_write(1, "w3-file: open failed\n", 21);
        v_exit(31);
    }
    long total = 0;
    int n;
    for (;;) {
        n = v_file_read(fd, g_buf, 128);
        if (n <= 0) break;
        if (v_write(1, g_buf, (unsigned long)n) != n) v_exit(32);
        total += n;
    }
    if (n < 0) v_exit(33);
    v_file_close(fd);
    v_exit((int)total);
}