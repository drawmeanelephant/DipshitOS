/*
 * wc.c — M35 W5 capstone fixture (issue #766): the real tool — byte/line/
 * word counts — ported to wasm via `zig cc` and shipped as an HF4 app.
 *
 * Provenance (the W5 acceptance rule): this file was written from
 * docs/wasm-import-contract.md + the shim it blesses (tests/virelai.h)
 * alone — §5.1 file rows for env.file_open/file_read/file_close, §3
 * pointer conventions (byte slices), §4 error model (negative errno),
 * §7 author recipe for the compile line. No interpreter source was read
 * while authoring; the only out-of-band fact is the W1a D3 freeze
 * ("the capstone is wc; ship it as wc.wasm running via exec WASM.BIN").
 *
 * Semantics: reads /host/WC.TXT in 64-byte chunks (the kernel clamps
 * read caps at 2048; small chunks prove the multi-chunk path), counts
 * bytes/lines/words — a word is a maximal run of non-whitespace (space,
 * tab, \n, \r, \v, \f) and the in-word flag survives chunk boundaries —
 * prints the classic wc line with each count right-aligned to the widest
 * count, and exits with the total byte count (fileapp's length proof:
 * gate asserts the process-report exit status). Error exits: 41 open
 * failed, 42 read failed (fileapp's 31/32/33 discipline).
 *
 * Native cross-run: `cc -DVIRELAI_NATIVE wc.c -o wc-native` runs the SAME
 * counting/printing code against a host file; the gate and the host test
 * cross-validate wasm output against the Python-precomputed expected line.
 */
#ifdef VIRELAI_NATIVE
/* Native smoke harness: declare the §5 signatures directly (they match
   tests/virelai.h byte-for-byte — the shim's import attributes would be
   meaningless to a host linker). V_MODE_READ per contract §5.1. */
#define V_MODE_READ 0x1
int v_write(int fd, const void *buf, unsigned long n);
void v_exit(int status);
int v_file_open(const char *path_ptr, unsigned long path_len, unsigned long flags);
int v_file_read(int fd, void *buf, unsigned long cap);
int v_file_close(int fd);
#else
#include "virelai.h"
#endif

static char g_buf[64];
static unsigned long g_bytes;

/* decimal digits of v (v >= 0) */
static int ulen(unsigned long v) {
    int n = 1;
    while (v >= 10) {
        v /= 10;
        n += 1;
    }
    return n;
}

/* right-align u in a `width` field: (width - digits) spaces, then digits */
static void put_pad(unsigned long u, int width) {
    char tmp[12];
    int nd = 0; /* digit count, kept separate from the pad counter */
    do {
        tmp[nd] = (char)('0' + (int)(u % 10));
        nd += 1;
        u /= 10;
    } while (u > 0 && nd < 12);
    {
        int pad = nd;
        while (pad < width) {
            v_write(1, " ", 1);
            pad += 1;
        }
    }
    while (nd > 0) {
        nd -= 1;
        v_write(1, &tmp[nd], 1);
    }
}

static int ws(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

/* Count `fd` to EOF (0 = cleanup happened upstream), print the wc line. */
static void wc_run(int fd) {
    unsigned long lines = 0, words = 0;
    int in_word = 0;
    int n;
    g_bytes = 0;
    for (;;) {
        n = v_file_read(fd, g_buf, sizeof(g_buf));
        if (n <= 0) break;
        g_bytes += (unsigned long)n;
        {
            int i;
            for (i = 0; i < n; i++) {
                char c = g_buf[i];
                if (c == '\n') lines += 1;
                if (ws(c)) {
                    in_word = 0;
                } else if (!in_word) {
                    in_word = 1;
                    words += 1;
                }
            }
        }
    }
    if (n < 0) {
        v_write(1, "w5-wc: read failed\n", 19);
        v_exit(42);
    }
    {
        int width = ulen(lines);
        if (ulen(words) > width) width = ulen(words);
        if (ulen(g_bytes) > width) width = ulen(g_bytes);
        put_pad(lines, width);
        v_write(1, " ", 1);
        put_pad(words, width);
        v_write(1, " ", 1);
        put_pad(g_bytes, width);
        v_write(1, " /host/WC.TXT\n", 14); /* space + 12-char path + \n */
    }
}

void _start(void) {
    static const char path[] = "/host/WC.TXT";
    int fd = v_file_open(path, sizeof(path) - 1, V_MODE_READ);
    if (fd < 0) {
        v_write(1, "w5-wc: open failed\n", 19);
        v_exit(41);
    }
    wc_run(fd);
    v_file_close(fd);
    v_exit((int)g_bytes);
}

#ifdef VIRELAI_NATIVE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE *g_in;

int v_file_open(const char *path_ptr, unsigned long path_len, unsigned long flags) {
    char tmp[128];
    unsigned long i;
    (void)flags;
    if (path_len == 0 || path_len >= sizeof(tmp)) return -1;
    for (i = 0; i < path_len; i++) tmp[i] = path_ptr[i];
    tmp[path_len] = 0;
    g_in = fopen(tmp, "rb");
    return g_in ? 1 : -1;
}

int v_file_read(int fd, void *buf, unsigned long cap) {
    (void)fd;
    return (int)fread(buf, 1, (size_t)cap, g_in);
}

int v_file_close(int fd) {
    (void)fd;
    fclose(g_in);
    return 0;
}

int v_write(int fd, const void *buf, unsigned long n) {
    (void)fd;
    return (int)fwrite(buf, 1, (size_t)n, stdout);
}

void v_exit(int status) {
    exit(status);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    {
        int fd = v_file_open(argv[1], strlen(argv[1]), V_MODE_READ);
        if (fd < 0) return 3;
        wc_run(fd);
        v_file_close(fd);
        v_exit((int)g_bytes);
    }
}
#endif /* VIRELAI_NATIVE */