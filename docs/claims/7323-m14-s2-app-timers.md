# Claim: Milestone 14 Card S2 — the bounded per-process application timer facility (ADR 0007 slots 40–41)

- **Owner:** buffy (`freebuff/new-worktree-who-dis-84637f8c-617d-4718-b605-bebdba7963d9`)
- **Prompt / plan:** `docs/march-m14.md`
- **Scope:** Milestone 14, Card S2 (Issue #176: application timers — a bounded per-process timer facility, ADR 0007 slots 40–41, posting `TIMER` events on the ADR 0009 queue; wishlist 12)
- **Depends on:** S1 (claim 0169, same branch)
- **Status:** ✅ done 2026-08-18 — the bounded per-process application timer facility (ADR 0007 slots 40–41) is live on VZ: TIMER.BIN arm → block in sys_wait_event → TIMER event → cancel (0/1) round-trips, and the syscalls report shows implemented=42 with sys_timer_set calls=3 / sys_timer_cancel calls=2; tools/verify-live-timers.sh PASS 1/1

## Notes

Text apps currently make "wait a while" mean `sys_sleep` in a spin loop —
the very pattern this card exists to remove. This card adds ONE bounded
per-process app timer: a fixed BSS table (one slot per process, zero heap)
counting SCHEDULER ticks, firing exactly one `TIMER` event into the process's
ADR 0009 event queue when the countdown reaches zero.

- `sys_timer_set(delay_ticks)` — slot 40. Arm the CALLING process's timer to
  fire once after `delay_ticks` scheduler ticks (0 clamps to 1 — the
  `sys_sleep` minimum — and a delay over the fixed bound truncates honestly
  at `app_timers.max_delay_ticks`; re-arming replaces any pending timer).
  Returns 0; `EINVAL` for a non-process caller.
- `sys_timer_cancel()` — slot 41. Disarm the calling process's timer.
  Returns 1 if a pending timer was canceled, 0 if none was armed; `EINVAL`
  for a non-process caller.

Layering: NEW `kernel/src/app_timers.zig` (a `[max_processes]` armed-flag +
countdown + counters table, no allocation); the fire is driven from the
scheduler's `on_tick` (the same host-testable tick seam that wakes sleepers)
so the real IRQ tick and host tests share one path. `events.zig` gains the
`TIMER` kind (9). Process lifecycle resets the slot on create/exec/exit
(alongside `events.reset` / `file_table.reset_process`), so a recycled pid
never inherits a stale timer and no timer fires for a dead process. The
countdown fires by pushing an event — a task blocked in `sys_wait_event`
wakes through the existing `on_event_pushed` hook; a non-blocked app finds
it on its next poll.

`ui.zig` exposes `timer_set`/`timer_cancel` + the `EVENT_TIMER` constant.
The proof program `TIMER.BIN` (`user/src/timertest.zig`, the twenty-third
ESP program) arms → blocks in `sys_wait_event` → observes the `TIMER`
event → prints a marker, then proves cancel (nothing pending → 0), re-arms
→ fires again, and cancels a live pending timer (→ 1) before exiting.

- Class-A tests at every layer (app_timers module; the TIMER event kind;
  syscall dispatch + fault safety for slots 40/41; the tick-driven fire
  through the scheduler seam; the report rows).
- Live gate `tools/verify-live-timers.sh`: exec `TIMER.BIN` on VZ, assert
  the arm/fire/cancel markers, then the `syscalls` report
  (`implemented=42`, slots 40/41 with calls > 0).
- ADR 0007 amendment documents slots 40–41 (`implemented_count` 40 → 42).
- Stale live gates asserting `implemented=40` are bumped to 42.

## Result

- Class A green end to end (app_timers module 5/5; the TIMER event kind;
  syscall dispatch + tick-driven fire + clamping for slots 40/41; the
  report rows; ui wrappers; TIMER.BIN builds and embeds) and the full
  `verify-portable` set passed.
- Class B `tools/verify-live-timers.sh` **PASS 1/1 on VZ** — TIMER.BIN
  armed a 2-tick timer, blocked in `sys_wait_event` (no spin loop) and
  received the TIMER event (`timertest: fired seq=1`), cancel with nothing
  pending → 0, re-arm → `fired2 seq=2`, cancel a live pending timer → 1
  (it never fired), exited status 23, and the syscalls report shows
  `implemented=42` with `sys_timer_set calls=3` / `sys_timer_cancel
  calls=2`. Wiring the timer into NOTEPAD's cursor blink / a live clock /
  TOP refresh is card S3's composition scope.
