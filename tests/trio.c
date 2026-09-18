/*
 * trio.c — M70e (#1457) author-proof corpus app: file + window + timers in
 * ONE module, which is the combination deliverable 3 asks for.
 *
 * Provenance: written from docs/wasm-import-contract.md alone — §5.1
 * (file_open/file_read/file_close, MODE_READ, honest truncation, 0 = EOF),
 * §5.2 (win_open/win_fill/win_present/win_get/win_close, window ids 2..5),
 * §5.4 (timer_set/timer_cancel, one-shot per-process app timer, 3600-tick
 * clamp), §3 (byte-slice paths, no NUL), §4 (negative = −errno, no global
 * errno), §7 (the compile line), and §9 (the v2 declaration below). No
 * interpreter source was read while writing this file — that is the §7/W5
 * provenance rule the corpus exists to exercise.
 *
 * The v2 section this module must carry (added by the build, not by a
 * linker):
 *
 *     virelai.abi=2
 *     capabilities=debug,file,timer,window
 *
 * Determinism: the timer is armed for 3600 ticks (the contract's maximum,
 * several seconds) and cancelled immediately, so `canceled=1` is not a race
 * between the scheduler and two adjacent calls; the window geometry is read
 * back through win_get rather than assumed, so the printed rect is the
 * kernel's answer. The exit status is the byte count of the file read, the
 * same length-proof discipline fileapp/wc use.
 *
 * Error exits (fileapp's 41/42/43 discipline): 41 open, 42 read, 43 win_open,
 * 44 win_fill, 45 win_get.
 */
#include "virelai.h"

static char g_buf[32];
static char g_win[16]; /* win_get: x,y,w,h as 4 x u32 LE */

static void put_lit(const char *s) {
    unsigned long n = 0;
    while (s[n] != 0) n += 1;
    v_write(1, s, n);
}

static void put_u(unsigned long v) {
    char tmp[20];
    int nd = 0;
    do {
        tmp[nd] = (char)('0' + (int)(v % 10));
        nd += 1;
        v /= 10;
    } while (v != 0);
    while (nd > 0) {
        nd -= 1;
        v_write(1, &tmp[nd], 1);
    }
}

static unsigned long le32(const char *p) {
    return (unsigned long)(unsigned char)p[0] |
           ((unsigned long)(unsigned char)p[1] << 8) |
           ((unsigned long)(unsigned char)p[2] << 16) |
           ((unsigned long)(unsigned char)p[3] << 24);
}

void _start(void) {
    /* §5.1 — the share file the gate drops next to this module. */
    static const char path[] = "/host/TRIO.TXT";
    int fd = v_file_open(path, sizeof(path) - 1, V_MODE_READ);
    if (fd < 0) {
        put_lit("trio: open failed\n");
        v_exit(41);
    }
    unsigned long total = 0;
    for (;;) {
        int n = v_file_read(fd, g_buf, sizeof(g_buf));
        if (n < 0) {
            put_lit("trio: read failed\n");
            v_exit(42);
        }
        if (n == 0) break; /* EOF (§5.1) */
        total += (unsigned long)n;
    }
    v_file_close(fd);
    put_lit("trio: bytes=");
    put_u(total);
    put_lit("\n");

    /* §5.2 — a window, filled and presented, geometry read back. */
    int id = v_win_open(40, 40, 96, 48);
    if (id < 0) {
        put_lit("trio: win failed\n");
        v_exit(43);
    }
    if (v_win_fill(id, 0, 0, 96, 48, 0x00CC66) != 0) {
        put_lit("trio: fill failed\n");
        v_exit(44);
    }
    if (v_win_present(id) != 0) {
        put_lit("trio: present failed\n");
        v_exit(46);
    }
    if (v_win_get(id, g_win) != 0) {
        put_lit("trio: get failed\n");
        v_exit(45);
    }
    put_lit("trio: win rect=");
    put_u(le32(g_win + 0));
    put_lit(",");
    put_u(le32(g_win + 4));
    put_lit(",");
    put_u(le32(g_win + 8));
    put_lit(",");
    put_u(le32(g_win + 12));
    put_lit("\n");
    v_win_close(id);

    /* §5.4 — arm the contract's longest delay, then cancel it. */
    int armed = v_timer_set(3600);
    int canceled = v_timer_cancel();
    put_lit("trio: timers armed=");
    put_u((armed == 0) ? (unsigned long)1 : (unsigned long)0);
    put_lit(" canceled=");
    put_u((canceled == 1) ? (unsigned long)1 : (unsigned long)0);
    put_lit("\n");

    put_lit("trio: ok\n");
    v_exit((int)total);
}
