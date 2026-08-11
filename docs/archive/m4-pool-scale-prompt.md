# Milestone-four follow-on 3, card 3g — pool scale: a third live user process

Planning-first prompt doc for DipshitOS, card 3g of the follow-on 3 set
(after card 3f / claim 5965 / PR #79). Split from
[`docs/m4-args-ipc-scale-prompt.md`](m4-args-ipc-scale-prompt.md). ADR
0007 stays frozen (the card-3f slots 5/6 amendment is the ONLY ABI change
in the set). No libc/POSIX/heap anywhere. Branch:
`agent/buffy/m4-pool-scale` (claim 5795, verified via
`bash tools/status/claim-id.sh` for branch + slug `pool-scale-seven`).

## Why

Every prior card documents the 5-slot budget with one spare or none (3b/
3c/3f: "5/5, NO spare"; 3a/3e: one spare). This card DELIBERATELY raises
the budget and re-derives the gates — the machinery's scale proof, and
the capstone that unblocks future cards needing 3+ live user programs.

## Sequence

1. Claim first: `docs/claims/5795-pool-scale-seven.md` + branch log
   `docs/logs/agent-buffy-m4-pool-scale.md` + `bash tools/status/refresh-indexes.sh`;
   split this prompt from the combined doc. Branch stacks on merged main
   (PRs #78 + #79 already merged; next PR is #80).
2. Class A first (host tests before any VZ boot).
3. Class B on VZ: the new live gate + the FULL 12-gate shared-seam live
   sweep (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/
   uaccess/userspace/entropy/long-lived) plus the args/kill/ipc gates,
   evidence under `artifacts/`.
4. Docs reconciliation: march-m4 row 3g + Buffy lane, roadmap, status,
   gate-inventory, README, claim flip, log append, PR #80 per the repo
   template (real observed evidence only).

## Scope

1. Grow `max_tasks` 5 → 7 (`kernel/src/scheduler.zig`; `idle_id` stays
   `max_tasks - 1`) — shell + worker + 3 user programs + one spare +
   idle. Re-derive the idle/spare budget. The switching core, lifecycle
   states, and ADR 0007 stay untouched — this is a BUDGET change.
2. Audit the page-table carve-out: the `tables=NN/256` budget
   (`mmu.build_user_root`) must hold the kernel root + 3 user roots —
   count it in the survey and assert it in the addrspaces gate.
3. Re-derive every pool-capacity host test: `pool_full` at the new
   budget; `has_free_slot` still first-checked; the refused path still
   leak-free with an exact free-count assertion. The transcript
   fixture's `tasks: pool=4/5` line re-derives to `pool=6/7`.
4. New live gate `tools/verify-live-scale.sh`: exec COUNTER.BIN +
   USER.BIN + USER.BIN (three live user programs); `procs` shows THREE
   `state=running` rows with distinct task ids + stack VAs; all three
   markers interleave with the worker's advances; a fourth exec →
   `pool_full`. The 3b long-lived gate's one-spare scenario re-derives at
   the new budget (counter + two users + spare). The args/kill/ipc
   gates' `pool_full` third-exec refusals re-derive to a fourth exec.

## Do not

- Grow the pool for any OTHER card (3c/3d/3e/3f document their own
  budgets); touch ADR 0007; touch the switching core or the lifecycle
  states; unbounded anything.
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).

## Shared process (this card)

1. Claim first: deterministic claim doc + branch log +
   `bash tools/status/refresh-indexes.sh`; planning-first prompt doc
   (this file).
2. Class A first: `zig fmt --check`, unit tests, transcript
   byte-identical (`zig build test-console` + `verify-transcript.sh`),
   build/image/inspect, swift build, context, coordination ×2, mmu-debt.
3. Class B on VZ: the card's new live gate + the FULL 12-gate shared-seam
   live sweep, evidence saved under `artifacts/`.
4. Docs reconciliation: march-m4 row + lane, roadmap, status,
   gate-inventory, README, claim flip, log append, PR per the repo
   template (real observed evidence only).

## Do not (this card)

- Touch ADR 0007's syscall numbers; the scheduler switching core; the
  process lifecycle states.
- Add libc/POSIX/heap allocation anywhere; grow anything unbounded.
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
