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
    /* Hold the window open until the LIVE GATE closes it, so the `dui`
       snapshots, the post-raise composite (`dui raise 2` blits the window
       into the scanout — post-WMS the kernel no longer composites user
       windows unprompted), and the screen captures all observe it (z-order
       row + blits counter + the 0xFF0000 fill on the scanout prove the
       pixel path end to end). The hold POLLS v_win_query: the syscall
       returns -1 (EINVAL) the moment the window leaves the registry, and
       the gate's script3 `dui close <id>` releases it — a hold measured in
       GATE CHOREOGRAPHY, not interpreter speed. (The old 15M-iteration spin
       was calibrated "~10-15s"; the interpreter since outgrew it — the hold
       collapsed to milliseconds and the window died before script2, the
       live-wasm red of issue #1020.) Bounded: 1e7 polls → exit 30 so a
       wedged gate can never hang the boot. */
    {
        unsigned long q[8];
        long i;
        for (i = 0; i < 10000000L; i++) {
            if (v_win_query(id, q) == -1) break; /* window released */
        }
        if (i >= 10000000L) v_exit(30); /* gate never closed it */
    }
    v_exit(21);
}