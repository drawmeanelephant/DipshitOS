# Log — `agent/buffy/m14-s2-timers`: application timers (claim 5390)

## 2026-08-19 — branch opened

- Claimed (claim 5390): Milestone 14 card S2 — bounded per-process timers
  posting `TIMER` events on the ADR 0009 queue (issue #176). Slots 40/41
  (`sys_timer_set`/`sys_timer_cancel`), fixed 8-entry BSS timer table tied
  to the scheduler tick, NOTEPAD timer-driven cursor blink, TOP timer-driven
  refresh, `TMRTEST.BIN` + the class-B gate `tools/verify-live-timers.sh`.
  `implemented_count` 40 → 42.
- Branch based on `agent/buffy/m14-s1-clipboard` (PR #195 — M14 S1 — carries
  slots 38/39 + `implemented_count` 40; S2 is stacked on it and layers slots
  40/41 on top, so S2's PR depends on S1 merging first).

## 2026-08-19 — done

- Landed `kernel/src/timers.zig` (fixed 8-entry BSS table, per-process owned,
  auto-cancel on exit), `events.zig` kind 9 (`TIMER`), syscall slots 40/41
  (`sys_timer_set`/`sys_timer_cancel`, `implemented_count` 40 → 42), and the
  scheduler tick + `exit_current` hooks. NOTEPAD gains a 1-tick timer-driven
  cursor blink; TOP a 2-tick timer-driven refresh (no spin/sleep).
- Added `TMRTEST.BIN` (twenty-fourth ESP program) + the class-B gate
  `tools/verify-live-timers.sh`. Renamed the program from "TIMERTEST" to
  "TMRTEST" because the 9-char stem exceeds the FAT 8.3 bound the ESP layer
  enforces (the `name_too_long` write path).
- Class-A green (fmt, 461 console + 22 unit tests + timers/syscall/events
  suites, byte-identical transcript, build/image/inspect, swift build,
  coordination). Live gate PASS 1/1 on VZ: one-shot fire + oneshot spent +
  periodic x3 + cancel clean + stale refused, `sys_timer_set calls=2` /
  `sys_timer_cancel calls=2`, exit 0 + reaped.
