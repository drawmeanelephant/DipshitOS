# Claim: per-core scheduler state — current + pending_* staging indexed by core (SMP-ready ring)

- **Owner:** buffy (`agent/buffy/percore-scheduler-state`)
- **Prompt / plan:** make the scheduler's `pending_*` staging and `current` per-core so cores 1-3 could eventually run user tasks
- **Scope:** scheduler per-core state plumbing only; NOT the remaining SMP blockers (tick gate in `irq_dispatch`, shared-ring locking, task migration, cross-core wakeups)
- **Touches:** kernel/src/scheduler.zig, docs/claims/8477-percore-scheduler-state.md, docs/logs/agent-buffy-percore-scheduler-state.md
- **Depends on:** claim 7339 (per-core resume handoff), claim 8513 (per-core IRQ counters) — merged
- **Heartbeat:** 2026-09-02
- **Status:** ✅ done

## Notes

**Change.** `scheduler.current` is now `[smp.max_cores]usize` (the unwritten
`current_by_core` vestige folded into it) and the five `pending_*` staging
globals are per-core arrays. Every scheduler function that touches them
resolves `const c = smp.core_id()` at entry (host-guarded: 0 on tests /
non-aarch64 — `smp.core_id()` already has the guard) and indexes
`current[c]` / `pending_*[c]`. The critical seam: `apply_pending` now
writes `exceptions.resume_frame[c]` / `resume_sp_el0[c]` instead of the
hard-coded `[0]` — the claim-7339 per-core exception handoff is now fully
consistent end-to-end (staging on core c → apply on core c → stub eret on
core c). `yield_current`, `sleep_current`, `wait_current`,
`wait_event_current`, `tick` (timer_switch_context), and `current_id` all
follow. `current_task_for_core(cid)` returns `current[cid]` directly.

**Correctness argument.** Staging and apply never cross cores: `stage_current`/
`switch_context`/`exit_current` run in SVC context and `tick`/`apply_pending`
in IRQ context on the SAME core, so the per-core slots are only ever
touched by their owner — no new locking needed, and behavior on the
current 2-vCPU VM is byte-identical (every site resolves to slot 0 in
production today). The remaining single-core assumptions are now explicit
and localized: `irq_dispatch` still gates `timer.handle()` + `scheduler.tick()`
to PE 0, the shared ready ring (`tasks[]`/`next_runnable`) is unlocked,
and wakeups (`wake_expired`/`wake_waiters`/`on_event_pushed`) run on the
ticking core — the actual SMP-scheduling card can lift those one by one.

**Evidence.** Full unit suite PASS (incl. the round-robin/yield/sleep/wait/
wait_event scheduler tests, now indexed at slot 0), `zig build` PASS, BSS
budget PASS (511 080 B headroom; +~220 B for the arrays), fmt + coordination
clean, and four class-B gates under plain exec: verify-live-zc **4/4**,
verify-live-vf **4/4**, verify-cvc-echo **1/1**, verify-live-concurrent
**2/2** (live `sleeping=2 awake=2 interleave=1` — the per-core sleep path
exercised on hardware).

Verified: unit suite + BSS green; verify-live-zc 4/4, verify-live-vf 4/4,
verify-cvc-echo 1/1, verify-live-concurrent 2/2 plain-exec.