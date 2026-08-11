# Log — milestone-four follow-on 3, card 3f: IPC — distinct processes exchange data

- **Branch:** `agent/buffy/m4-ipc`
- **Claim:** [`docs/claims/5965-ipc-mailbox.md`](../claims/5965-ipc-mailbox.md)
- **Prompt / plan:** [`docs/m4-ipc-prompt.md`](../m4-ipc-prompt.md)
- **Started:** 2026-08-10

## Progress

- **Claimed** (2026-08-10): claimed the milestone-four follow-on 3 card 3f
  (IPC mailbox) on `agent/buffy/m4-ipc` with claim 5965 (deterministic ID
  from branch+slug `ipc-mailbox`, verified via
  `tools/status/claim-id.sh`), stacked on the card-3e tree (PR #78; merge
  order #77 → #78 → #79). Written plan first (`docs/m4-ipc-prompt.md`,
  split from `docs/m4-args-ipc-scale-prompt.md`), claim + log +
  `refresh-indexes.sh` before code.
- **Stage A (2026-08-10):** implemented — `kernel/src/mailbox.zig` (a
  pure-BSS per-process ring: `max_processes` × 4 slots × 64 B, send /
  peek / drop / pending / info / reset / init, per-pid sent+recv
  counters); the ABI amendment (slots 5 `sys_ipc_send` + 6
  `sys_ipc_recv`, `ENOSPC` = -5, `implemented_count` 5→7, `syscalls`
  report rows 0–6; ADR 0007 updated with the slots-5/6 + -5 amendment
  section); the syscall handlers (send: len-0 no-op, >64 truncation,
  target validated against the process registry — free/exited/out-of-range
  → `EINVAL`, full ring → `ENOSPC`, uaccess copy_in → `EFAULT`; recv:
  `max` clamp to 64, caller's pid via `process.find_by_task`, empty → 0,
  peek → uaccess copy_out → drop, so a bad buffer never loses the
  message); the seams (`mailbox.init()` in `scheduler.init`,
  `mailbox.reset(pid)` after `process.create` on the exec path and the
  boot-payload registration); `mbox [<pid>]` monitor command (registry
  31→32) printing per-process `pending/sent/recv` + the pending message
  bytes; user payloads — `user/src/peer.zig` (PEER.BIN: recv-loop, echo
  `peer: got ` + the received bytes, never exits) and COUNTER.BIN gains
  the argc/argv target-pid parse (naked-asm decimal, 2 digits; argc==0 →
  no sending, byte-identical to claim 4613) plus a periodic send every
  3rd iteration (`ipc: ping <d>` console marker via sys_write + the same
  `ping <d>\n` bytes via sys_ipc_send, built on its own stack); the
  build pipeline embeds the third program (`build.zig` peer executable +
  install + image arg, `make-image.sh` PEER_BIN embed + DSK1 check +
  listing self-verify, `mkfat32.py` peer cluster chain + dir entry +
  docstring). Host tests: mailbox ring wrap/full/empty/reset, syscall
  round-trip / full / empty / isolation / truncation / marshaling, mbox
  output, exec-by-name of PEER.BIN + COUNTER.BIN with the 5/5
  `pool_full` third exec. Full class A green (including the transcript
  fixture + mock test gaining the mbox help row, and the sleep gate's
  `implemented=5` assertion moved to 7).
- **Stage B (2026-08-10):** live gate `tools/verify-live-ipc.sh` PASS 1/1
  on VZ — `exec PEER.BIN` + `exec COUNTER.BIN 1` back to back: the
  counter's `ipc: ping <d>` sends and the peer's `peer: got ping <d>`
  echoes interleave across the whole log (the peer echoes the same bytes
  it received — end-to-end data flow between two never-exiting
  processes), both `state=running` at the final `procs`, `mbox` shows
  the peer's ring drained (pending ≤ 1 — the honest in-flight window —
  with its recv count tracking the echo count) and the counter's ring
  empty (nobody sends to it), a third exec is `pool_full` (5/5, no
  spare), shell responsive (evidence `artifacts/live-ipc-*`). Full
  12-gate shared-seam live sweep green — exec/procs/concurrent/tasks/
  lifecycle/addrspaces/sleep/svc/uaccess/userspace/entropy/long-lived
  all PASS 1/1, plus the new ipc gate and the existing args/kill gates.
- **Stage C (2026-08-10):** docs reconciled (march-m4 row + Buffy
  summary, roadmap bullet, status paragraph, README follow-on 3
  paragraph, gate-inventory live-ipc row + machine record + verify-vz
  aggregate — which also regains the live-args recipe the 3e card left
  out of justfile), indexes refreshed. Claim flipped; PR #79 staged after
  the card-3e tree (PR #78).

## Live evidence (VZ, 2026-08-10, Apple M4)

`tools/verify-live-ipc.sh` PASS 1/1 — `artifacts/live-ipc-serial-01.log`
(6 725 serial bytes, runner-rc=0):

- The two execs load (`exec: loaded PEER.BIN size=…`, `exec: loaded
  COUNTER.BIN size=…`); the phase-1 `procs` shows `name=PEER.BIN
  state=running` and `name=COUNTER.BIN state=running` with distinct
  task ids and distinct ASLR stack VAs.
- Byte-exact data flow across the whole log (lines 82–137):
  `ipc: ping 1` → `peer: got ping 1` → `ipc: ping 2` → `peer: got ping
  2` → … → `ipc: ping 5` → `peer: got ping 5` — every send echoed, the
  first echo after the first send, 5 sends + 5 echoes. The counter also
  wrote `counter: alive` 17 times (still running at the end of the 60 s
  window).
- The phase-2 `mbox` snapshot: `mbox: id=1 name=PEER.BIN pending=0
  sent=1 recv=1` (the bounded ring drained — sent − recv == pending,
  pending ≤ 1) and `mbox: id=2 name=COUNTER.BIN pending=0 sent=0
  recv=0` (nobody sends to the counter).
- The third exec is `exec: no free scheduler pool slot` (5/5 pool —
  counter + peer + shell + worker + idle — no spare), both processes
  still `state=running` at the final `procs`, neither ever exits (no
  `state=exited` row for either), shell responsive, no exception park.
- **Two findings fixed on the way:** (1) the first payload draft wrote
  the message's trailing newline one byte past the uaccess stack
  region's exclusive top (`sp+64` = the region bound) — the send would
  have EFAULTed; the scratch now builds the payload inside `sp..sp+63`
  (host-audited, never shipped). (2) The first live run showed only 2
  sends/echoes in the 60 s window: the worker consumes most of each
  round, so the counter runs ~17 iterations per window and an
  every-8th-iteration send yielded 2; the cadence was switched to every
  3rd iteration (`cmp x23, #3` + reset) and the re-run showed 5
  sends + 5 echoes.
- The full 12-gate shared-seam live sweep PASS 1/1 (exec/procs/
  concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/userspace/
  entropy/long-lived), plus the args and kill gates — all green against
  the mailbox ABI (ADR 0007 slots 5/6) and the third ESP image.
