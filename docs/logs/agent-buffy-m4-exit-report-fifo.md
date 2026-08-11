# Log — milestone-four follow-on 3, card 3d: per-process exit reports (exact)

- **Branch:** `agent/buffy/m4-exit-report-fifo`
- **Claim:** [`docs/claims/1014-exact-exit-reports.md`](../claims/1014-exact-exit-reports.md)
- **Prompt / plan:** [`docs/m4-exit-reports-prompt.md`](../m4-exit-reports-prompt.md)
- **Started:** 2026-08-10

## Progress

- **Claimed** (2026-08-10): claimed the milestone-four follow-on 3 card 3d
  (per-process exit reports — kill the first-wins collapse) on
  `agent/buffy/m4-exit-report-fifo` with claim 1014 (deterministic ID from
  branch+slug), branched off `origin/main` (independent of card 3c). Written
  plan first (`docs/m4-exit-reports-prompt.md`).

## Stage A — the FIFO report machinery (2026-08-10)

- Replaced the three single-slot first-wins report flags with bounded
  4-slot FIFOs: `scheduler.exit_report_pending` → a name+status ring,
  `process.exit_report_pending` → a per-slot name+status ring, and
  `scheduler.reap_report_pending` → a name ring. Push from exception
  context (pure BSS writes), drain in order from the shell idle loop and
  the monitor — no double-print across consumers.
- Overflow policy: drop-oldest (a full ring evicts the oldest to admit
  the newest), documented + host-tested.
- Host tests: scheduler + process two/three-exits-in-one-window → exactly
  N ordered report lines; no double-print; overflow drops the oldest;
  existing exit-report tests updated to the FIFO drain.

## Stage B — exact-count live gates (2026-08-10)

- Tightened `tools/verify-live-concurrent.sh` from ≥1 to EXACT counts:
  both USER.BIN exits → exactly 2 `tasks user-exec exited status=43` / 2
  `procs USER.BIN exited status=43` / 2 `tasks user-exec reaped`.
- Tightened `tools/verify-live-long-lived.sh` the same way: the phase-1
  USER.BIN exit + the phase-2 re-exec exit stay DISTINCT (exactly 2 of
  each) and the boot payload's `tasks user-el0 exited status=7` stays its
  own distinct line (exactly 1).
- **First run FAILED** on a gate bug, not the kernel: the long-lived
  gate still had a legacy `&& user_exited=1 || true` line from the old
  boolean-flag era that clobbered the new exact count (serial evidence
  showed both `tasks user-exec exited status=43` lines at 89/119, both
  reaps at 91/121 — the kernel was correct). Gave the exited-row check
  its own `exited_row` boolean; re-run PASS 1/1.
- Both tightened gates PASS 1/1 on VZ; the full 12-gate shared-seam sweep
  (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/
  userspace/entropy/long-lived) PASS 1/1 each — evidence under
  `artifacts/live-3d-*.txt`.

## Stage C — docs reconciliation + PR (2026-08-10)

- [tbd]
