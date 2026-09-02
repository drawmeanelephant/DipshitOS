/*
 * winapp.c — W3 live-gate fixture (issue #764): a wasm window app. Opens
 * a 96x48 window at (100,100), fills it 0xFF0000, provokes a kernel-side
 * error (win_set_visible(id, 2) must return -1 per contract §5.2 — the
 * error-mapping proof through the whole stack), presents, and exits 21.
 * Written against tests/virelai.h alone (the "contract alone" rule).
 */
#include "virelai.h"

void _start(void) {
    int id = v_win_open(100, 100, 96, 48);
    if (id < 0) v_exit(26);
    /* dynamic id: print it so the gate greps the exact window number */
    v_write(1, "w3: win open=", 13);
    {
        char c = (char)('0' + id);
        v_write(1, &c, 1);
        v_write(1, "\n", 1);
    }
    if (v_win_fill(id, 0, 0, 96, 48, 0xFF0000) < 0) v_exit(27);
    if (v_win_set_visible(id, 2) != -1) v_exit(28); /* EINVAL proof */
    if (v_win_present(id) < 0) v_exit(29);
    v_write(1, "w3: win ok\n", 11);
    /* Hold the window open ~10-15s of interpreted wasm so the live gate's
       `dui` snapshots, the post-raise composite (`dui raise 2` blits the
       window into the scanout — post-WMS the kernel no longer composites
       user windows unprompted), and the screen captures all observe it
       (z-order row + blits counter + the 0xFF0000 fill on the scanout
       prove the pixel path end to end). The monitor stays responsive —
       this process merely burns its own time slice. Pure i32 compute,
       clang keeps the volatile accumulator live. 15M iterations measured
       ~10-15s on the gate host (120M never finished inside the runner's
       120s window — claim 3456 review round). */
    volatile long acc = 0;
    for (long i = 0; i < 15000000L; i++) acc += (i * i) | 1;
    if (acc == 123456789L) v_write(1, "w3: unreachable\n", 16);
    v_exit(21);
}