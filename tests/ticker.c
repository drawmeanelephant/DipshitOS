/*
 * ticker.c — M70e (#1457) author-proof corpus app: the SMALLEST v2 module, to
 * prove a narrow capability set is enough for a real app and that the §9 gate
 * does not force every module to ask for the whole §5 surface.
 *
 * Provenance: docs/wasm-import-contract.md §5.4 (timer_set/timer_cancel), §7
 * (compile line), §9 (the declaration below). Same no-interpreter-source rule
 * as trio.c.
 *
 * The section this module carries:
 *
 *     virelai.abi=2
 *     capabilities=debug,timer
 *
 * It imports exactly four names — `write`, `exit`, `timer_set`,
 * `timer_cancel` — and is the module a manifest row that omits `timer` must
 * be refused for: that refusal is the gate's capability-escalation negative.
 * Armed for 3600 ticks and cancelled immediately, for the same determinism
 * reason trio.c documents.
 *
 * Error exits: 51 arm, 52 cancel.
 */
#include "virelai.h"

void _start(void) {
    int armed = v_timer_set(3600);
    int canceled = v_timer_cancel();
    if (armed != 0) {
        v_write(1, "ticker: arm failed\n", 19);
        v_exit(51);
    }
    if (canceled != 1) {
        v_write(1, "ticker: cancel failed\n", 22);
        v_exit(52);
    }
    v_write(1, "ticker: ok\n", 11);
    v_exit(0);
}
