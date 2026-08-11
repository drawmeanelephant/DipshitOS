# Milestone-four follow-on 4, card 4b — IPC depth: bigger or more messages

> **PLANNING-FIRST — this is the per-card split of
> [`docs/m4-followon4-prompt.md`](m4-followon4-prompt.md) (the proposal for
> the whole 4a/4b/4c set). ADR 0007 stays frozen — this card is a
> DATA-PATH CONSTANT change, not a syscall number (the follow-on 4 set's
> ABI changes are ONLY slots 7/8, on cards 4a/4c). No libc/POSIX/heap
> anywhere. New branch `agent/buffy/m4-ipc-depth` stacked on the card-4a
> tree (the repo's per-card stacking precedent), claim 3179
> (deterministic).

## Why

The card-3f mailbox is 4 × 64 B per process — a message longer than 64 B
truncates and only four outstanding messages fit. The data-flow proof is
real but narrow; depth makes the IPC path useful for bursty flows, still
bounded.

## Scope (Option B — more messages; documented in ADR 0007)

1. **Choose Option B**: raise `mailbox.max_messages` 4 → 8 (the per-process
   ring grows 256 → 512 B, still a fixed BSS array — no allocation; a
   data-path constant, NOT a syscall number — the ABI stays frozen).
   Document the choice + the unchanged truncation contract (a message
   longer than 64 B still truncates at the slot bound; a full ring still
   refuses with the same `ENOSPC` -5; the same empty → 0 recv result; the
   same drain invariant `sent − recv == pending ≤ capacity`; the same
   cross-process isolation).
2. **Re-derive every host test that pins the 4-slot constant**: the
   mailbox ring wrap/full/empty/reset tests (fill 8, the 9th send
   refuses; the counters track 9), the ipc syscall truncation/full tests
   (ENOSPC now at the 9th send), the `mbox` command output shape.
3. **The counter's send cadence becomes a BURST** (the `>4 messages
   queued at once` live proof): every 6th iteration COUNTER.BIN sends a
   burst of 6 messages back-to-back in ONE quantum (the peer cannot drain
   mid-burst — it is not scheduled), then 5 quiet iterations (the peer
   drains 1 per round, so the ring peaks at 6 of the 8 slots and drains
   to 0 before the next burst — NO ENOSPC, deterministically). Each send
   checks its return: a failure prints a distinct `ipc: enospc` marker
   (the live gate asserts ZERO of them). `argc == 0` keeps the
   byte-identical claim-4613 behavior (no sends at all).
4. **Re-derive the live gate `tools/verify-live-ipc.sh`**: the counter's
   bursts of 6 prove >4 messages queue with no ENOSPC; the mbox snapshot
   re-derives to the new capacity (`pending ≤ 8` and the invariant
   `sent − recv == pending` — the ring is drained, never overflowing);
   every send except the last in-flight burst window (≤ 6) has its
   byte-exact echo; the pool_full assertion stays at the FIFTH exec
   (7/7).

## Sequence

1. Claim first (this prompt + `docs/claims/3179-ipc-depth.md` +
   `docs/logs/agent-buffy-m4-ipc-depth.md` + `refresh-indexes.sh`).
2. Class A first: fmt, unit tests, transcript byte-identical
   (`zig build test-console`), build/image/inspect, swift build, context,
   coordination ×2, mmu-debt.
3. Class B on VZ: the re-derived `verify-live-ipc.sh` + the FULL 12-gate
   shared-seam live sweep (exec/procs/concurrent/tasks/lifecycle/
   addrspaces/sleep/svc/uaccess/userspace/entropy/long-lived) plus the
   args/kill/scale gates + the card-4a procs-syscall gate, evidence saved
   under `artifacts/`.
4. Docs reconciliation: ADR 0007 (the Option-B data-path note), march-m4
   row, roadmap, status, gate-inventory (live-ipc row re-derived),
   README, claim flip, log append, PR per the repo template (real
   observed evidence only).

## Do not

- Grow the pool (`max_tasks` stays 7); touch the switching core or the
  lifecycle states.
- Add POSIX pipes/fds/signals; unbounded mailboxes or tables; heap.
- Touch the syscall numbering at all (this card is a data-path constant;
  slots 7/8 belong to cards 4a/4c).
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
