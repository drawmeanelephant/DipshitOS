# Claim: per-process exit reports — kill the first-wins collapse

- **Owner:** Buffy (`agent/buffy/m4-exit-report-fifo`)
- **Prompt / plan:** milestone-four follow-on 3 card 3d (after claim 4613 /
  PR #75). Written plan first:
  [`docs/m4-exit-reports-prompt.md`](../m4-exit-reports-prompt.md).
- **Scope:** (1) replace the single pending exit/reap report flags in the
  scheduler AND the process registry with small bounded FIFOs (4 slots of
  name+status) drained IN ORDER by the shell idle loop (no double-
  printing); (2) overflow behavior documented + host-tested (oldest
  dropped, honestly reported); (3) host tests: 2–3 exits in one window →
  exactly N report lines, in order; (4) tighten the existing live gates
  from ≥1 to EXACT counts — `verify-live-concurrent` (both USER.BIN exits
  → exactly 2 report lines each) and `verify-live-long-lived` (the
  phase-1 USER exit + the phase-2 re-exec exit stay distinct → exactly 2
  of each; the boot payload's exit stays its own distinct line); (5) full
  shared-seam live sweep green. Do NOT touch ADR 0007, the scheduler
  switching core, or the process lifecycle states — this card is the
  REPORTING machinery only. No libc/POSIX/heap; host tests first; class B
  on VZ.
- **Depends on:** claim 4613 (the documented single-slot collapse — PR
  #75), claim 3848 (the process exit report), claim 0826 (two concurrent
  exits in one window). Independent of card 3c (kill).
- **Status:** ✅ done — Stage A (the bounded FIFO report machinery + exact
  host tests) and Stage B (the tightened exact-count gates + full
  shared-seam sweep on VZ) landed 2026-08-10; Stage C (docs reconciliation,
  claim flip, PR) closes it out.

## Notes

**Why it matters:** the documented debt from claims 0826/4613 — the
exit/reap report is a single first-wins-while-undrained flag, so N exits
in one idle-loop window collapse to ONE report line and the
concurrent/long-lived gates must assert ≥1 instead of exact counts. The
report is evidence: when two programs exit in the same idle-loop window,
the log should show BOTH exits, in order.

**Key design facts (from the survey):**

- **Three single-slot flags collapse today.** `scheduler.exit_report_pending`
  (the `tasks <name> exited status=N` line), `process.exit_report_pending`
  (the `procs <name> exited status=N` line), and
  `scheduler.reap_report_pending` (the `tasks <name> reaped` line) are all
  first-wins-while-undrained. Two exits in one idle-loop window → one
  `tasks ... exited`, one `procs ... exited`, and (if two reaps land in
  one window) one `tasks ... reaped`.
- **The consumer is the shell idle loop** (`scheduler.maybe_report`,
  called every idle poll in `boot_and_park`). The FIFOs are pushed from
  exception context (`exit_current`, `process.on_task_exit`, the idle
  task's reap) — pure BSS writes, console-free — and drained in order by
  the shell loop. `process.take_exit_report` is the same drain, now
  FIFO-ordered.
- **Task names are static slices** (string literals: "user-exec",
  "user-el0", "spawn-demo", ...) so the scheduler FIFO can snapshot the
  name pointer; the process FIFO needs per-slot name buffers (the process
  name is an owned copy).
- **The overflow policy is drop-oldest** (a full 4-slot FIFO evicts the
  oldest entry to admit the newest — the newest exits are the most
  relevant), documented and host-tested.
- **Exact counts require the full window.** The tightened gates capture
  the whole run (no early script-expect), so every exit's report lines
  land in the log and the exact assertions hold: `verify-live-concurrent`
  → exactly 2 `tasks user-exec exited status=43` / 2 `procs USER.BIN
  exited status=43` / 2 `tasks user-exec reaped`; `verify-live-long-lived`
  → exactly 2 of each (the phase-1 USER.BIN and the phase-2 re-exec both
  exit status 43) plus the boot payload's own distinct `tasks user-el0
  exited status=7` line (its report is drained before the script is
  forwarded — the `--script-after` trigger).

## Verification

- **Class A:** fmt, unit tests (scheduler: two/three exits in one window
  → exactly N ordered report lines, no double-print, overflow drops the
  oldest; process: same; existing exit-report tests updated to the FIFO
  drain), transcript byte-identical, build/image/inspect, swift build,
  context, coordination ×2, mmu-debt — all green.
- **Class B — the tightened gates:** `tools/verify-live-concurrent.sh`
  and `tools/verify-live-long-lived.sh` with the EXACT-count assertions —
  PASS 1/1 each on VZ (two USER.BIN exits → exactly 2 report lines each,
  in order; the long-lived re-exec's exit stays distinct from the
  phase-1 exit and the boot payload's exit).
- **Class B — shared-seam regressions:** the full live sweep
  (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/
  userspace/entropy/long-lived) all PASS 1/1.
