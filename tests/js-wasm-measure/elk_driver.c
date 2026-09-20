/* Console-only Elk driver: eval `1+2*3`, write the result to fd 1, exit.
 * Bounded subset from #1456: no timers, no DOM, no network. */
#include "elk.h"
#include "virelai.h"

static char g_js_mem[8192];

void _start(void) {
    struct js *js = js_create(g_js_mem, sizeof(g_js_mem));
    jsval_t v = js_eval(js, "1+2*3", ~0U);
    const char *s = js_str(js, v);
    unsigned long n = 0;
    while (s[n]) n++;
    v_write(1, s, n);
    v_write(1, "\n", 1);
    v_exit(0);
}
