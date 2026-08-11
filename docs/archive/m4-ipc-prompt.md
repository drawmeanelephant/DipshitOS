# Milestone-four follow-on 3, card 3f — IPC: distinct processes exchange data (claim 5965)

Planning-first prompt doc for DipshitOS, card 3f of the follow-on 3 set
(after card 3e / claim 4636 / PR #78). ADR 0007 stays frozen EXCEPT this
card's explicit slots 5/6 amendment (following the `sys_sleep` slot-4
precedent). No libc/POSIX/heap anywhere. Branch:
`agent/buffy/m4-ipc` (claim 5965, verified via `bash tools/status/claim-id.sh`
for branch + slug `ipc-mailbox`).

## Why

Coexistence is proven (claims 0826/4613), but two live processes cannot
COMMUNICATE — the strongest remaining proof of "real processes" is
end-to-end data flow between them, not just simultaneous markers.

## Sequence

1. Claim first: `docs/claims/5965-ipc-mailbox.md` + branch log
   `docs/logs/agent-buffy-m4-ipc.md` + `bash tools/status/refresh-indexes.sh`;
   split this prompt into `docs/m4-ipc-prompt.md`. Stack the branch on the
   card-3e tree (PR #78); merge order is #77 → #78 → #79.
2. Class A first (host tests before any VZ boot).
3. Class B on VZ: the new live gate + the FULL 12-gate shared-seam live
   sweep (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/
   uaccess/userspace/entropy/long-lived), evidence under `artifacts/`.
4. Docs reconciliation: march-m4 row 3f + Buffy lane, roadmap, status,
   gate-inventory, README, claim flip, log append, PR #79 per the repo
   template (real observed evidence only).

## Scope

1. **ADR 0007 amendment** (the card's one ABI change): `sys_ipc_send(target,
   buf, len)` = slot 5 and `sys_ipc_recv(buf, max)` = slot 6, following the
   `sys_sleep` slot-4 precedent. Update the ADR doc + `syscall.zig` table +
   `syscalls` command output.
2. Bounded per-process kernel mailbox: 4 × 64 B ring, BSS, no allocation.
   Send does uaccess `copy_in` from the caller's region; a full mailbox →
   documented ENOSPC-style result. Recv copies out; empty → documented
   empty result. A process can only reach ITS mailbox (recv) and the
   target's (send) — cross-process isolation, uaccess-bounded (host-test
   both directions).
3. `mbox [<pid>]` monitor command (registry 31→32) dumps pending messages.
4. Extend COUNTER.BIN with a periodic send (`ipc: ping n` every few
   quanta); add a third image PEER.BIN (`user/src/peer.zig` → PEER.BIN
   through the now-parameterized build pipeline — `build.zig`/
   `make-image.sh`/`mkfat32.py` embed a third program, self-verifying in
   the listing) that recv-loops and echoes `peer: got n` forever — TWO
   never-exiting programs communicating. Pool math at 5 slots: counter +
   peer + shell + worker + idle = 5/5, NO spare (document; a third exec
   is `pool_full` — reuse the 3b capacity proof under IPC).
5. Host tests: send/recv round-trip; mailbox full/empty results;
   cross-process isolation; truncation; the frame/syscall marshaling for
   the two new slots.
6. Live gate `tools/verify-live-ipc.sh`: exec COUNTER.BIN + PEER.BIN; the
   peer's `peer: got n` markers land interleaved with the counter's
   `ipc: ping n` sends across the whole log (end-to-end data flow between
   two live processes), both still running at the final `procs`, `mbox`
   shows the ring drained, a third exec is `pool_full`.

## Do not

- Grow the pool (5/5, no spare — the pool-scale card 3g is the capstone
  that raises the budget; do NOT change `max_tasks` here).
- Add POSIX-style pipes/fds/signals; unbounded mailboxes; touch the
  switching core or the lifecycle states.
- The ABI amendment is the ONLY syscall change in this card set — every
  other syscall number stays frozen.
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
