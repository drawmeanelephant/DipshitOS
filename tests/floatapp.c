/*
 * floatapp.c — W4 live-gate fixture (issue #765): a temperature unit
 * converter — the "named float utility" the W4 card ties float growth
 * to. Written against tests/virelai.h alone (env.write/env.exit), built
 * with the W3 determinism recipe:
 *
 *   zig cc -target wasm32-freestanding -nostdlib -fno-sanitize=undefined \
 *          -g0 -I tests tests/floatapp.c -o floatapp.wasm
 *
 * What it proves in-guest (byte-exact pinned output):
 *   - f64 chains C*9/5+32 and (F-32)*5/9  -> f64.mul/div/add/sub
 *   - the same chains in f32 (separate float path, not promoted)
 *   - fixed-point milli-degree inputs     -> i64->f64 convert (0xB9)
 *   - the two-decimal formatter's cast    -> i64.trunc_f64_s (0xFC 2)
 *   - `x < 0.0` / `-x` in the formatter   -> f64 compare + f64.neg
 *   - bit-pattern lines via __builtin_bit_cast -> f64/f32 reinterpret
 *     lanes (0xBF/0xBE), pinning exact IEEE results (decimal formatting
 *     alone would tolerate small arithmetic drift)
 *   - volatile input tables keep clang from constant-folding the math at
 *     compile time (the whole point is that the OPS run in-guest)
 *
 * Every line is emitted with env.write and the exit status is the total
 * number of bytes written (fileapp's length proof, reused).
 *
 * Native cross-check build (host IEEE arithmetic == wasm IEEE):
 *   cc -DVIRELAI_NATIVE tests/floatapp.c -o /tmp/floatapp-native && \
 *   /tmp/floatapp-native          # expected bytes the gate pins
 */
void _start(void); /* entry; the native main() below calls it */

#ifndef VIRELAI_NATIVE
#include "virelai.h"
#define VIRELAI_EMIT(s, n) v_write(1, (s), (n))
#define VIRELAI_EXIT(s) v_exit((s))
#else
#include <stdio.h>
#define VIRELAI_EMIT(s, n) fwrite((s), 1, (n), stdout)
#define VIRELAI_EXIT(s) (void)(s)
int main(void) { _start(); return 0; }
#endif

static unsigned long long g_bytes; /* total written; the exit status */
static char g_buf[96];
static unsigned g_len;

static void put_ch(char c) { g_buf[g_len++] = c; }
static void put_str(const char *s) { while (*s) put_ch(*s++); }

static void put_i64(long long v) {
    char t[24];
    int n = 0;
    int neg = 0;
    if (v < 0) { neg = 1; v = -v; }
    if (v == 0) t[n++] = '0';
    while (v) { t[n++] = (char)('0' + v % 10); v /= 10; }
    if (neg) put_ch('-');
    while (n) put_ch(t[--n]);
}

/* fixed two-decimal formatter for |x| < 1e5; round-half-up of x*100 */
static void put_f2(double x) {
    int neg = 0;
    if (x < 0.0) { neg = 1; x = -x; }          /* f64.lt + f64.neg */
    long long scaled = (long long)(x * 100.0 + 0.5); /* f64.mul/add, trunc */
    long long ip = scaled / 100;
    long long fp = scaled % 100;
    if (neg) put_ch('-');
    put_i64(ip);
    put_ch('.');
    put_ch((char)('0' + fp / 10));
    put_ch((char)('0' + fp % 10));
}

static void put_hex16(unsigned long long v) {
    for (int sh = 60; sh >= 0; sh -= 4) put_ch("0123456789abcdef"[(v >> sh) & 0xf]);
}
static void put_hex8(unsigned int v) {
    for (int sh = 28; sh >= 0; sh -= 4) put_ch("0123456789abcdef"[(v >> sh) & 0xf]);
}

static void emit_line(void) {
    put_ch('\n');
    if (VIRELAI_EMIT(g_buf, g_len) != (int)g_len) VIRELAI_EXIT(91);
    g_bytes += g_len;
    g_len = 0;
}

/* ---- the conversion math (kept out of _start so it survives review) -- */
static double c2f64(double c) { return c * 9.0 / 5.0 + 32.0; }
static double f2c64(double f) { return (f - 32.0) * 5.0 / 9.0; }
static float c2f32(float c) { return c * 9.0f / 5.0f + 32.0f; }
static float f2c32(float f) { return (f - 32.0f) * 5.0f / 9.0f; }

#define BITS64(x) __builtin_bit_cast(unsigned long long, (x))
#define BITS32(x) __builtin_bit_cast(unsigned int, (x))

/* volatile input tables: force runtime loads so the float ops execute */
static volatile double g_celsius[] = { 0.0, 10.0, 21.5, -40.0, 100.0 };
static volatile double g_fahren[] = { 32.0, 50.0, 98.6, 212.0, -40.0 };
static volatile long long g_milli[] = { 0LL, 10000LL, 21500LL, -40000LL, 100000LL };
static volatile float g_cel32[] = { 21.5f, 100.0f, -40.0f };
static volatile float g_fah32[] = { 212.0f, 70.7f, -4.0f };
static volatile signed char g_deltas[] = { -40, -10, 0, 7, 21 };

void _start(void) {
    int i;

    for (i = 0; i < 5; i++) { /* C -> F, f64 */
        double c = g_celsius[i];
        double f = c2f64(c);
        put_str("c2f "); put_f2(c); put_str(" = "); put_f2(f); emit_line();
    }
    for (i = 0; i < 5; i++) { /* F -> C, f64 */
        double f = g_fahren[i];
        double c = f2c64(f);
        put_str("f2c "); put_f2(f); put_str(" = "); put_f2(c); emit_line();
    }
    for (i = 0; i < 5; i++) { /* fixed-point milli-degrees in, C -> F */
        long long mc = g_milli[i];
        double c = (double)mc / 1000.0; /* i64 -> f64 convert (0xB9) */
        put_str("mC "); put_i64(mc); put_str(" = "); put_f2(c2f64(c)); emit_line();
    }
    for (i = 0; i < 3; i++) { /* the f32 path (kept float end-to-end) */
        float c = g_cel32[i];
        put_str("f32 c2f "); put_f2(c); put_str(" = "); put_f2(c2f32(c)); emit_line();
    }
    for (i = 0; i < 3; i++) {
        float f = g_fah32[i];
        put_str("f32 f2c "); put_f2(f); put_str(" = "); put_f2(f2c32(f)); emit_line();
    }
    /* exact IEEE results, pinned via the reinterpret lanes */
    {
        double c = 21.5, f = c2f64(c);
        put_str("bits64 c2f 21.50 = "); put_hex16(BITS64(f)); emit_line();
    }
    {
        double c = -40.0, f = c2f64(c);
        put_str("bits64 c2f -40.00 = "); put_hex16(BITS64(f)); emit_line();
    }
    {
        double f = 98.6, c = f2c64(f);
        put_str("bits64 f2c 98.60 = "); put_hex16(BITS64(c)); emit_line();
    }
    {
        float c = 21.5f, f = c2f32(c);
        put_str("bits32 c2f 21.50 = "); put_hex8(BITS32(f)); emit_line();
    }
    {
        float f = 70.7f, c = f2c32(f);
        put_str("bits32 f2c 70.70 = "); put_hex8(BITS32(c)); emit_line();
    }
    /* sign-extension where it appears naturally: an i8 accumulator over
       the signed-char delta table wraps in i8 and re-widens (extend8_s) */
    {
        long chk = 0;
        for (i = 0; i < 5; i++) {
            signed char d = (signed char)(g_deltas[i] * 3); /* i8 wrap */
            chk += (long)d;                                  /* widen */
        }
        put_str("sext chk = "); put_i64(chk); emit_line();
    }
    if (g_len != 0) VIRELAI_EXIT(92); /* every line emitted via emit_line */
    VIRELAI_EXIT((int)g_bytes);
}
