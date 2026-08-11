# Log — milestone-four follow-on 4, card 4a: process observability — sys_procs introspection syscall

- **Branch:** `agent/buffy/m4-procs-syscall`
- **Claim:** [`docs/claims/5799-procs-syscall.md`](../claims/5799-procs-syscall.md)
- **Prompt / plan:** [`docs/m4-procs-syscall-prompt.md`](../m4-procs-syscall-prompt.md) (per-card split of [`docs/m4-followon4-prompt.md`](../m4-followon4-prompt.md))
- **Started:** 2026-08-11

## Progress

- **Claimed** (2026-08-11): claimed the milestone-four follow-on 4 card 4a
  (process observability) on `agent/buffy/m4-procs-syscall` with claim
  5799 (deterministic ID from branch+slug `procs-syscall`, verified via
  `tools/status/claim-id.sh`), stacked on merged main d792c85 (PR #80,
  card 3g). Written plan first (`docs/m4-procs-syscall-prompt.md`, split
  from the `m4-followon4-prompt.md` proposal), claim + log +
  `refresh-indexes.sh` before code.
- **Stage A (2026-08-11):** implemented — `kernel/src/process.zig`
  `snapshot()` (fixed-width row marshaling: u64 pid, u64 state code, u64
  exit status, name[16] NUL-padded, 40-byte rows, free rows skipped — the
  exit status survives the reap per claim 3848); the ABI amendment (slot
  7 `sys_procs`, `implemented_count` 7→8, `syscalls` report rows 0–7
  with `implemented=8`; ADR 0007 updated with the slots-7 amendment
  section); the syscall handler (whole-row truncation at `max` — a
  partial row is never copied; `max==0` → 0 rows; EFAULT for a bad buf
  or a read-only target — the claim-6120 contract; fixed BSS scratch, no
  allocation, no caller-identity requirement); the re-derived
  expectations (`monitor.zig`'s syscalls test + `tools/
  verify-live-sleep.sh`'s `implemented=8` grep); the EL0 payload in
  `user/src/peer.zig` (phase-1 `sys_procs` poll once per quantum until a
  RUNNING non-self row appears, then `peer: sees <pid> <name> <state>`
  per row — including the exited boot payload's row — then the unchanged
  recv loop; marker shapes host-pinned via `sees_prefix`; the row parse
  is naked asm: decimal pid, NUL-bounded name, state-code → string).
  Host tests: the row shape/marshaling, whole-row truncation, EFAULT
  (unmapped + read-only target), the live-registry reflection
  (running/exited/created rows, pid reuse after recycle), and the
  slot-7 frame marshaling via handle_svc (all green). One payload bug
  caught in the asm: `mul x23, x22, #40` — the integrated assembler
  rejects an immediate third operand — fixed with the shift-add form
  (32·row + 8·row).
- **Stage B (2026-08-11):** new live gate `tools/verify-live-procs-syscall.sh`
  PASS 1/1 on VZ — `exec PEER.BIN` + `exec COUNTER.BIN 1` back to back:
  the serial log shows `peer: sees 0 user-el0 exited` / `peer: sees 1
  PEER.BIN running` / `peer: sees 2 COUNTER.BIN running` — the counter's
  RUNNING row read FROM EL0 (the headline, distinct from the EL1h
  monitor's `procs` read which shows both with distinct tasks + stacks),
  the IPC flow still echoes byte-exact after the snapshot (`peer: got
  ping N` — the phase-1 read doesn't disturb the recv loop), both
  processes `state=running` at the final procs, neither ever exits,
  shell responsive, no exception park (evidence
  `artifacts/live-procs-syscall-*`). (One gate bug fixed: my redundant
  state-string regex required the state immediately after the pid, but
  the name sits between — corrected to `[^ ]+`, re-run green.) Full
  12-gate shared-seam live sweep PASS 1/1 — exec/procs/concurrent/tasks/
  lifecycle/addrspaces/sleep/svc/uaccess/userspace/entropy/long-lived
  all green, plus the args/kill/ipc/scale gates (the extended PEER.BIN
  keeps the 3f ipc gate green: the `peer: sees` lines match no
  `name=`/`state=` pattern and the echo cadence is untouched).
- **Stage C (2026-08-11):** docs reconciled (march-m4 row 4a + lane
  summary, roadmap bullet, status paragraph, README follow-on 4
  paragraph, gate-inventory live-procs-syscall row + GATE record +
  verify-vz aggregate, justfile verify-vz + recipe), indexes refreshed,
  claim flipped. PR staged on `agent/buffy/m4-procs-syscall`.

## Live evidence (VZ, 2026-08-11, Apple M-series)

`tools/verify-live-procs-syscall.sh` PASS 1/1 —
`artifacts/live-procs-syscall-serial-01.log` (6 629 serial bytes,
runner-rc=0):

- The two execs load (`exec: loaded PEER.BIN size=…`, `exec: loaded
  COUNTER.BIN size=…`); the phase-1 EL0 read lands the snapshot rows:
  `peer: sees 0 user-el0 exited`, `peer: sees 1 PEER.BIN running`,
  `peer: sees 2 COUNTER.BIN running` — the counter visible FROM EL0.
- The monitor's own `procs` read shows `name=PEER.BIN state=running` and
  `name=COUNTER.BIN state=running` with distinct task ids + distinct
  ASLR stack VAs (the EL1h view, distinct from the EL0 one).
- The IPC flow still works: `ipc: ping N` sends and byte-exact
  `peer: got ping N` echoes interleave after the snapshot (the peer
  entered its recv loop); both processes still `state=running` at the
  final procs, neither ever exits, shell responsive, no [EXC] park.
- Full 12-gate shared-seam live sweep PASS 1/1 (exec/procs/concurrent/
  tasks/lifecycle/addrspaces/sleep/svc/uaccess/userspace/entropy/
  long-lived), plus args/kill/ipc/scale — all green against the slot-7
  ABI and the extended PEER.BIN.
