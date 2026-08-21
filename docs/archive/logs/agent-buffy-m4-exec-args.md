# Log — milestone-four follow-on 3, card 3e: exec context block (args to EL0)

- **Branch:** `agent/buffy/m4-exec-args`
- **Claim:** [`docs/claims/4636-exec-args.md`](../claims/4636-exec-args.md)
- **Prompt / plan:** [`docs/m4-exec-args-prompt.md`](../m4-exec-args-prompt.md)
- **Started:** 2026-08-10

## Progress

- **Claimed** (2026-08-10): claimed the milestone-four follow-on 3 card 3e
  (exec args) on `agent/buffy/m4-exec-args` with claim 4636 (deterministic
  ID from branch+slug, verified via `tools/status/claim-id.sh`), stacked on
  the card-3d tree (PR #77), which itself was made mergeable by resolving
  its conflict with main (PR #76).  Written plan first
  (`docs/m4-exec-args-prompt.md`), claim + log + `refresh-indexes.sh`
  before code.
- **Stage A (2026-08-10):** implemented — `exec_file(name, args)` packs
  the bounded argv block (8 × 32 B, NUL-terminated, per-arg 31-byte
  truncation, >8 refused as `too_many_args` before any disk work) into
  the staging buffer at `align8(content_len)`, the block is copied into
  the process's OWN text page (`text_len` extends over it — zero extra
  pages, the 5-page budget untouched), `argv_va_for` pins the offset + the
  exact 4 KiB boundary (`no_args_room`), `register_exec_user` gains
  argc/argv_va written into the claim-9746 frame's x0/x1 slots after
  `spawn` (the `build_initial_frame`-zeroes-the-frame seam; boot
  `register_user` untouched), `cmd_exec` forwards `args[1..]` with
  `max_args = 1 + max_exec_args`, and USER.BIN prints one `user:
  arg=<n>` line per arg before its existing markers (no-args execs
  byte-identical). Host tests: pack shape, truncation, too-many-args
  refusal, no-room guard at the page boundary, read-only-leaf uaccess
  contract both directions, per-exec distinct argv, frame x0/x1. Full
  class A green.
- **Stage B (2026-08-10):** live gate `tools/verify-live-args.sh` PASS
  1/1 on VZ — `exec USER.BIN alpha` + `exec USER.BIN beta` back to back:
  the SAME binary loads twice, the procs snapshot shows two
  `state=running` rows with distinct task ids + stack VAs, the distinct
  markers prove which invocation is which, both programs complete (status
  43, exact FIFO counts), a third exec is `pool_full`, shell responsive
  (evidence `artifacts/live-args-*`). The first live run caught a payload
  bug (prefix write length 11 vs the 10-char string — the newline write
  got swallowed, printing `user: arg=` and the arg on separate lines; the
  args were reaching EL0 — the kernel plumbing was right); fixed to #10
  and re-run green. A gate bug (exact-line grep missed the marker on the
  shell's trailing prompt line) fixed to substring match, re-run green.
  Full 12-gate shared-seam live sweep green — exec/procs/concurrent/
  tasks/lifecycle/addrspaces/sleep/svc/uaccess/userspace/entropy/
  long-lived/kill + args all PASS 1/1.
- **Stage C (2026-08-10):** docs reconciled (march-m4 row + Buffy
  summary, roadmap bullet, status paragraph, README follow-on 3
  paragraph, gate-inventory live-args row + machine record + verify-vz
  aggregate), claim flipped, PR #78 opened.
