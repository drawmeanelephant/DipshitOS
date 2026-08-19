# Claim: Milestone 14 Card S2 — application timers / TIMER events

- **Owner:** buffy (`agent/buffy/m14-s2-timers`)
- **Prompt / plan:** `docs/march-m14.md`
- **Scope:** Milestone 14, Card S2 (Issue #176): bounded per-process timers
- **Depends on:** M14 S1 clipboard (claim 2611, PR #195); ADR 0009 event queue (M9)
- **Status:** ✅ done 2026-08-19

## Notes

A bounded kernel timer facility that wakes a process through its existing
ADR 0009 event queue (no new blocking primitive). `sys_timer_set(ticks,
periodic) -> id` (slot 40) and `sys_timer_cancel(id) -> i64` (slot 41); a
fixed 8-entry BSS timer table tied to the scheduler tick, expiry posting a
`TIMER` event (kind 9) to the owning process's FIFO. Timers are per-process
owned and auto-cancel on exit.

Consumers: NOTEPAD.BIN gains a timer-driven blinking cursor; TOP.BIN gains a
periodic timer-driven refresh (replacing its event-only refresh). A headless
`TMRTEST.BIN` (the twenty-fourth ESP program; the 8.3-short stem — "TIMERTEST"
is 9 chars and exceeds the FAT 8.3 bound) arms timers and reports each expiry
deterministically for the class-B gate `tools/verify-live-timers.sh`.

Verified by: class-A green (fmt, unit tests incl. timers + syscall + events,
byte-identical transcript, build/image/inspect, swift build, coordination),
and the live gate on VZ (`sys_timer_set`/`sys_timer_cancel` calls in the
syscalls report + TMRTEST expiry markers + exit status). `implemented_count`
40 → 42, and every gate asserting `implemented=40` is re-derived to 42.
