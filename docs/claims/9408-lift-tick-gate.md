# Claim: lift the PE-0 tick gate — secondary cores run the scheduler tick on per-core state

- **Owner:** buffy (`agent/buffy/percore-scheduler-state`)
- **Prompt / plan:** lift the PE-0 tick gate in `irq_dispatch` so a secondary core can run the scheduler tick on its own per-core ring
- **Scope:** secondary-core tick + worker scheduling only; NOT user tasks on cores 1-3 (console TX is still core-0-only — user tasks stay on core 0 for now)
- **Touches:** kernel/src/scheduler.zig, kernel/src/main.zig, kernel/src/monitor.zig, tools/verify-live-zc.sh, docs/claims/9408-lift-tick-gate.md, docs/logs/agent-buffy-percore-scheduler-state.md
- **Depends on:** claim 7339 (per-core resume handoff), claim 8513 (per-core IRQ counters), claim 8477 (per-core scheduler state) — all merged
- **Heartbeat:** 2026-09-02
- **Status:** ✅ done

## Notes

**Change.** `irq_dispatch` no longer gates `timer.handle()` + `scheduler.tick()`
to PE 0: any core takes its own timer PPI and calls `tick()`. The
scheduler splits into two paths:

- **Secondary path (`tick()` on cidx != 0):** acquire `sched_lock`
  (spinlock — `try_lock` on the critical one-shot witness so a
  deadlocked core produces evidence instead of a silent hang), verify the
  task at `current[cidx]` is still the registered per-core worker slot,
  run its readiness + timeslice progress, then `apply_pending` exactly
  like core 0. If the worker has yielded/exited, the pick-next scan
  wraps per-core (worker slot → idle slot → shell slot 0) so the
  secondary core parks on the **idle** task.
- **Core-0 path (`on_tick`):** unchanged — full ready-ring pick, wakeups,
  exit reports.

**Locking.** `sched_lock` now guards the shared ring mutation entry points
(`spawn`/`request_kill`/`request_report`/`maybe_report`/`maybe_heartbeat`/
`wake_event_waiters`/`exit_current`/`tick`) with holder-tracked
acquire/release, because the event hook (`wake_event_waiters`) fires from
lock-held contexts (exit teardown, tick) *and* unlocked SVC contexts —
reentrancy-agnostic `lock()` self-deadlocked there (found live: WIN.BIN
exit → `driving_award.close_owner` → `events.push` → hook → `lock()` on the
same core). The hook checks `sched_lock_held` and skips when already held.

**Found in passing:** `exit_current` was already re-entering `tick`'s locked
body (`tick` → `exit_current` under lock) — a latent self-deadlock that only
the new locking exposed; the split into `exit_current_locked` fixes it.

**Evidence of the lift.** The `verify-live-zc` gate now asserts `secondary=1`:
the runner greps the monitor `smp` output for `task=worker state=online`
on a core other than 0 — i.e., core 1 demonstrably ran the worker task
through the lifted tick path, every boot. The monitor `smp` command prints
per-core `idle/worker/shell` task names + states.

**Known boundary.** Console TX is polled with no lock, so user tasks remain
on core 0; the worker task (`note_advance` + `request_report` + nop-spin)
is console-free by design. Task *migration* is still out of scope — a task
runs on the core it was spawned on.