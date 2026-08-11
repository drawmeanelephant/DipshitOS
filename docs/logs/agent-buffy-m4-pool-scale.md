# Log — milestone-four follow-on 3, card 3g: pool scale — a third live user process

- **Branch:** `agent/buffy/m4-pool-scale`
- **Claim:** [`docs/claims/5795-pool-scale-seven.md`](../claims/5795-pool-scale-seven.md)
- **Prompt / plan:** [`docs/m4-pool-scale-prompt.md`](../m4-pool-scale-prompt.md)
- **Started:** 2026-08-11

## Progress

- **Claimed** (2026-08-11): claimed the milestone-four follow-on 3 card 3g
  (pool scale) on `agent/buffy/m4-pool-scale` with claim 5795
  (deterministic ID from branch + slug `pool-scale-seven`, verified via
  `tools/status/claim-id.sh`), stacked on merged main at the card-3f
  merge (`0ee8b47`; PRs #78 + #79 already merged). Written plan first
  (`docs/m4-pool-scale-prompt.md`, split from the combined
  `docs/m4-args-ipc-scale-prompt.md`), claim + log + `refresh-indexes.sh`
  before code.
- **Stage A (done, 2026-08-11):** grew `max_tasks` 5 → 7 in
  `kernel/src/scheduler.zig` (`idle_id` stays `max_tasks - 1`; the BSS
  task array follows — shell + worker + FOUR user slots + idle). The
  pool math is FOUR live user programs with a FIFTH exec `pool_full`
  (the 4th user slot is the "spare" while only three are live).
  Re-derived every pool-capacity host test: scheduler 100/100 (four user
  tasks fill 7/7, the fifth registration fails bounded), exec 152/152
  (FOUR USER.BINs load concurrently with distinct roots/pages/tasks, a
  FIFTH exec is `pool_full` with the exact free-count unchanged — the
  refused path leaks nothing; the permanent-occupant + recycle test
  re-derives at 4 programs), monitor 213/213 + shell (the
  `tasks: pool=4/5` transcript fixture → `pool=4/7` — the boot snapshot
  is shell + worker + user-el0 + idle = 4 registered over 7), mmu 13/13
  with a new 3-root budget pin (kernel root + 3 user roots stay under
  half the 256-page carve-out). The claim doc's draft gate arithmetic
  was off by one (it said a FOURTH exec fills the pool); corrected to
  the implemented truth — FIFTH exec at 7/7.
- **Stage B (done, 2026-08-11):** new live gate `tools/verify-live-scale.sh`
  **PASS 1/1 on VZ** — `exec COUNTER.BIN` + `exec USER.BIN` ×3 back to
  back: the procs snapshot shows FOUR `state=running` user rows (one
  counter + three USER.BINs) with FOUR distinct executor task ids +
  stack VAs; the programs' markers + the counter's `counter: alive`
  markers interleave with the worker's advances across the whole log
  (17 counter markers); a FIFTH exec is `exec: no free scheduler pool
  slot` (7/7 — shell + worker + 4 users + idle); `addrspaces:
  tables=150/256` stays inside the carve-out (106 pages headroom); the
  counter is still `state=running` at the final procs; the shell stays
  responsive (evidence `artifacts/live-scale-*`). Two gate bugs caught
  on the first live run: (1) the interleave assertion looked between the
  three USER.BIN hello markers, which all land in one scripted burst —
  fixed to use the counter's whole-log markers vs the worker's advances;
  (2) my tables assertion demanded ≤128/256, but the honest 4-root
  survey is 150/256 — relaxed to ≤200 with the observed value recorded.
  Full shared-seam sweep re-derived against the 7-slot pool, all PASS
  1/1: the 12-gate sweep (exec/procs/concurrent/tasks/lifecycle/
  addrspaces/sleep/svc/uaccess/userspace/entropy/long-lived) + args
  (re-derived to FOUR argv-distinguished USER.BINs — alpha/beta/gamma/
  delta — with a FIFTH exec `pool_full`) + kill (unchanged; one program
  at a time) + ipc (re-derived: counter + peer + two USER.BINs fill 7/7,
  FIFTH exec refused). The long-lived gate's ending re-derived to the
  one-spare scenario (counter + two users = 6/7, one spare) with an
  exact page-count relationship (phase-2 free == phase-1 free − 5, the
  second live USER.BIN's pages).
- **Stage C (done, 2026-08-11):** docs reconciled — march-m4 3g row +
  Buffy summary, roadmap bullet, status paragraph, README follow-on 3
  paragraph, gate-inventory (live-scale row + GATE machine record +
  verify-vz aggregate), claim flipped, PR #80 opened.
