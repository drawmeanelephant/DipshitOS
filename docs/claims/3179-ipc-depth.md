# Claim: IPC depth — more messages per process ring (card 4b)

- **Owner:** Buffy (`agent/buffy/m4-ipc-depth`)
- **Prompt / plan:** milestone-four follow-on 4, card 4b (the second card
  of the 4a/4b/4c set — the proposal doc
  [`docs/m4-followon4-prompt.md`](../m4-followon4-prompt.md), split per
  card: [`docs/m4-ipc-depth-prompt.md`](../m4-ipc-depth-prompt.md)).
  Written plan first; stacked on the card-4a tree (the repo's per-card
  stacking precedent, like card 3f on the 3e tree), merge order
  4a → 4b → 4c.
- **Scope:** (1) **Option B — more messages** (documented in ADR 0007): the
  per-process mailbox ring grows `max_messages` 4 → 8 (256 → 512 B per
  pid, still a fixed BSS array — a DATA-PATH CONSTANT, NOT a syscall
  number; the ABI stays frozen; the follow-on 4 set's ABI changes are
  ONLY slots 7/8 on cards 4a/4c). The truncation contract is unchanged: a
  message longer than 64 B still truncates at the slot bound, a full ring
  still refuses with the same `ENOSPC` -5 (now at the 9th send), the same
  empty → 0 recv, the same drain invariant `sent − recv == pending ≤
  capacity`, the same cross-process isolation. (2) Re-derive every host
  test pinning the 4-slot constant (mailbox ring wrap/full/empty/reset —
  fill 8, 9th refuses, counters track 9; the ipc syscall full/truncation
  tests; the `mbox` output shape). (3) COUNTER.BIN's send cadence becomes
  a BURST: every 6th iteration it sends 6 messages back-to-back in ONE
  quantum (the peer cannot drain mid-burst), then 5 quiet iterations (the
  peer drains 1 per round — the ring peaks at 6 of the 8 slots and drains
  to 0 before the next burst: NO ENOSPC, deterministically); each send
  checks its return and prints a distinct `ipc: enospc` marker on failure
  (the gate asserts ZERO); `argc == 0` stays byte-identical claim-4613
  behavior. (4) Re-derive the live gate `tools/verify-live-ipc.sh`: the
  burst proves >4 messages queue with no ENOSPC, the `mbox` snapshot
  re-derives to `pending ≤ 8` + the invariant, every send except the
  last in-flight burst window (≤ 6) has its byte-exact echo, the
  `pool_full` FIFTH-exec assertion stays at 7/7. Do NOT grow the pool
  (`max_tasks` stays 7), touch the switching core / lifecycle states, or
  add pipes/fds/signals/heap. No libc/POSIX; host tests first; class B on
  VZ.
- **Depends on:** card 4a (claim 5799 / PR #81) — this branch stacks on
  the card-4a tree (ADR 0007's slot-7 amendment and the extended
  PEER.BIN are current); merge order 4a → 4b. Independent of card 4a's
  mechanics (the mailbox capacity is orthogonal to sys_procs).
- **Status:** ✅ done 2026-08-11 (PR #82, stacked after PR #81 card 4a)

## Notes

**Why it matters:** the card-3f mailbox is 4 × 64 B per process — only
four outstanding messages fit, so a bursty flow (more than 4 sends before
the peer drains) would refuse with ENOSPC. Depth makes the IPC path useful
for bursty flows while staying bounded: the ring is a fixed BSS array, the
refusal is still honest, and the drain invariant is unchanged.

**Key design facts:**

- **A data-path constant, not an ABI change**: `mailbox.max_messages` is
  a compile-time BSS bound. Raising it 4 → 8 grows `storage` from
  ~2 KiB to ~4 KiB of fixed BSS — no allocation, no syscall-number
  change, ADR 0007 frozen (the follow-on 4 set's ABI amendments are ONLY
  slots 7/8 on cards 4a/4c). The ENOSPC refusal, the empty → 0 result,
  the 64 B message truncation, and the cross-process isolation are all
  byte-identical contracts re-derived at the new capacity.
- **The live proof is a burst**: sending >4 messages with no ENOSPC
  requires the ring to accumulate — the counter sends 6 messages
  back-to-back in ONE quantum (the peer is not scheduled mid-burst, so
  the ring peaks at 6 of 8), then rests 5 iterations (the peer drains 1
  per round → the ring drains to 0 before the next burst). Deterministic,
  never over 8, never refused. The send-return check prints a distinct
  `ipc: enospc` marker on ANY failure, so the gate asserts its ABSENCE.
- **The 3f gate re-derives, not rewrites**: the echo tracking, the
  first-echo-after-first-send order, the both-still-running / never-exit
  assertions, and the 7/7 pool_full all stay; only the mbox pending bound
  (≤ 1 → ≤ 8) and the in-flight echo window (last 1 → last ≤ 6 sends of
  the final burst) move, and the no-enospc + burst assertions are added.

## Verification

- **Class A:** fmt, unit tests (mailbox ring wrap/full/empty/reset at 8
  slots; the ipc send full→ENOSPC at the 9th; the mbox output; the
  counter's burst marker shapes), transcript byte-identical, build/image/
  inspect, swift build, context, coordination ×2, mmu-debt — all green.
- **Class B — the re-derived gate:** `tools/verify-live-ipc.sh` PASS 1/1
  on VZ — `exec PEER.BIN` + `exec COUNTER.BIN 1`: the counter's bursts
  of 6 `ipc: ping N` sends (contiguous in the log — no echo between)
  and the peer's byte-exact `peer: got ping N` echoes interleave, ZERO
  `ipc: enospc` lines, the log's peak (sends − echoes) = 6 (> 4
  messages queued at once, never over the 8-slot bound), every send
  except the last in-flight burst window (≤ 6) echoed, first echo after
  the first send; the `mbox` snapshot shows the peer's ring drained at
  the new bound (pending ≤ 8, sent − recv == pending — observed
  `pending=5 sent=6 recv=1` mid-drain) and the counter's ring empty,
  both still running / never exit, a fifth exec is `pool_full` (7/7),
  shell responsive. Evidence under `artifacts/live-ipc-*`.
- **Class B — shared-seam regressions:** the full 12-gate live sweep
  (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/
  userspace/entropy/long-lived) all PASS 1/1, plus the args/kill/scale
  gates and the card-4a procs-syscall gate.
