# Claim: Pool scale — a third live user process (card 3g)

- **Owner:** Buffy (`agent/buffy/m4-pool-scale`)
- **Prompt / plan:** milestone-four follow-on 3 card 3g (the capstone,
  after claim 5965 / PR #79, card 3f). Written plan first:
  [`docs/m4-pool-scale-prompt.md`](../m4-pool-scale-prompt.md) (split
  from the combined `docs/m4-args-ipc-scale-prompt.md`).
- **Scope:** (1) grow the scheduler pool `max_tasks` 5 → 7
  (`kernel/src/scheduler.zig`; `idle_id` stays `max_tasks - 1`) — shell +
  worker + 3 live user programs + ONE spare + idle; (2) audit the
  page-table carve-out (`tables=NN/256` in `mmu.build_user_root`): the
  kernel root + 3 user roots must fit, counted in the survey and asserted
  in the addrspaces live gate; (3) re-derive EVERY pool-capacity host
  test: `pool_full` at the new budget, `has_free_slot` still first-checked,
  the refused path still leak-free with an exact free-count assertion;
  (4) new class-B gate `tools/verify-live-scale.sh`: exec COUNTER.BIN +
  USER.BIN + USER.BIN + USER.BIN (FOUR live user programs — the 7-slot
  budget's headline, shell + worker + 4 users + idle = 7/7); `procs`
  shows FOUR `state=running` rows with distinct task ids + stack VAs;
  the programs' markers interleave with the worker's advances; a FIFTH
  exec is `pool_full`; the 3b long-lived gate's one-spare scenario
  re-derives at the new budget (counter + two users + spare).
- **Depends on:** claim 5965 / PR #79 (card 3f — this branch stacks on
  the merged main tree so the mailbox ABI, the third image, and the
  report FIFOs are current). Independent of cards 3c/3d/3e's mechanics.
- **Status:** ✅ done — landed 2026-08-11 (claim flipped after class-A
  green + the class-B scale gate PASS 1/1 on VZ + the full re-derived
  shared-seam sweep; branch stacked on merged main at the card-3f merge
  `0ee8b47`)

## Notes

**Why it matters:** every prior card documents the 5-slot budget with one
spare or none (3b/3c/3f state "5/5, NO spare"; 3a/3e document one spare).
This card DELIBERATELY raises the budget and re-derives the gates — the
machinery's scale proof, and the capstone that unblocks future cards
needing 3+ live user programs.

**Key design facts (from the survey):**

- `max_tasks` is a single const (`kernel/src/scheduler.zig`); `idle_id =
  max_tasks - 1` so the idle slot follows the growth. Growing 5 → 7 adds
  TWO exec slots: shell + worker + FOUR user programs + idle = 7 (the
  4th user slot is the "spare" while only three are live). Nothing else
  in the switching core changes (ADR 0007, the lifecycle states, and the
  ring mechanics stay untouched — the capstone is a BUDGET change, not a
  mechanics change).
- The pool is a BSS array of `Task` structs (per-task TTBR0 roots,
  regions, kernel stacks are allocator-backed per process — the pool
  growth is bounded BSS, no allocation).
- The page-table carve-out: `mmu.build_user_root` draws table pages from
  the fixed 256-page carve-out. The addrspaces live gate reads
  `addrspaces: tables=NN/256`. The survey must count the kernel root +
  3 user roots (each ~15 + leaf tables) and the gate must assert the new
  headroom.
- Every capacity assertion re-derives: the exec host tests (`pool_full`
  at 5→7, exact free-count on the refused path), the transcript fixture
  (`tasks: pool=4/5` line → `pool=4/7`: the boot snapshot is shell +
  worker + user-el0 + idle = 4 registered over the 7-slot budget), and
  the live gates that exercise the budget (long-lived's one-spare
  scenario, args/ipc's `pool_full` — those refusals move to the FIFTH
  exec at the new budget, so their scripts/assertions re-derive).
- The new live gate runs FOUR programs at once — the strongest
  simultaneous-marker proof yet, built on the 3f data-flow machinery.

## Verification

- **Class A:** fmt, unit tests (the re-derived pool-capacity tests:
  `pool_full` at the new budget with exact free-count assertions,
  `has_free_slot` first-check), transcript byte-identical (the
  `tasks: pool=4/5` fixture line → `pool=4/7`), build/image/inspect,
  swift build, context, coordination ×2, mmu-debt — all green.
- **Class B — the new gate:** `tools/verify-live-scale.sh` PASS 1/1 on
  VZ — `exec COUNTER.BIN` + `exec USER.BIN` + `exec USER.BIN` + `exec
  USER.BIN`: FOUR `state=running` rows with distinct task ids + stack
  VAs, the counter's markers interleaving with the USER.BIN runs' markers
  and the worker's advances, a fifth exec `pool_full` (7/7 — shell +
  worker + 4 users + idle), and the addrspaces `tables=NN/256`
  assertion at the new headroom. Evidence under `artifacts/live-scale-*`.
- **Class B — shared-seam regressions:** the full 12-gate live sweep
  (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/
  userspace/entropy/long-lived) plus the args/kill/ipc gates all PASS 1/1
  against the 7-slot pool (their pool_full refusals re-derived).

## Stage C (2026-08-11)

- Docs reconciled: march-m4 row + Buffy lane, roadmap bullet, status
  paragraph, README follow-on 3 paragraph, gate-inventory (live-scale row
  + GATE machine record + verify-vz aggregate), claim flipped. PR #80
  opened (real observed evidence only).
