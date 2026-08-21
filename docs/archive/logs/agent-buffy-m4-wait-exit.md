# Log — milestone-four follow-on 4, card 4c: exit-status propagation — a bounded `sys_wait` block

- **Branch:** `agent/buffy/m4-wait-exit` (stacked on the card-4b tree,
  PR #82; merged order 4a → 4b → 4c).
- **Plan:** [`docs/m4-wait-exit-prompt.md`](../m4-wait-exit-prompt.md).
- **Claim:** 9946 (deterministic, prompt-first).

## 2026-08-11 — implementation

- Claim 9946 registered (deterministic, prompt-first); claim doc +
  prompt doc + this log written before any kernel code.
- ADR 0007 amendment: `sys_wait(pid)` = slot 8 — block the caller until
  the target process exits (or is already exited), then return its
  snapshotted status; `implemented_count` 8 → 9, `syscalls` rows 0–8.
- Kernel: the event block lives ON THE TASK TCB (`Task.wait_pid` — a
  blocked waiter occupies its pool slot; no separate table),
  `scheduler.wait_current` parks the caller with the claim-0635 sleep
  seam, `wake_waiters` (called from `exit_current` right after the
  registry records the exit — `process.on_task_exit` now returns the
  exited pid) flips the waiter back to `ready` and patches the status
  into its saved frame's x0, and `wake_expired` never wakes an
  event-blocked task (the block is exit-driven, not time-driven).
- Handler semantics host-tested: already-exited → immediate status
  return; EINVAL for a non-process (EL1h) caller, a free/out-of-range
  pid, a `created` (loaded, not yet running) target, and self-wait (the
  refused deadlock).
- The THIRD program `user/src/status43.zig` → STATUS43.BIN (a fourth ESP
  image through the build/image pipeline: `build.zig` step + `mkfat32.py`
  + `make-image.sh` wiring, self-verified in the listing): alive marker →
  6-tick sleep (the deterministic blocked-window) → exiting marker →
  `sys_exit(43)`.
- COUNTER.BIN gains the wait mode: argv[1] = wait target pid (parsed
  alongside the existing argv[0] IPC target; `exec COUNTER.BIN 0 1`
  keeps the IPC path silent); prints `ipc: waiting pid=<n>`, blocks in
  `sys_wait`, prints `ipc: saw pid=<n> status=<s>` after the wake, then
  resumes the permanent-occupant marker loop (the wait runs exactly once;
  marker shapes host-pinned).
- Class A green: fmt, unit tests (244 incl. the new wait tests),
  transcript byte-identical, build/image/inspect (STATUS43.BIN embedded),
  swift build, context, coordination, mmu-debt.
- Class B green on VZ: the new `tools/verify-live-wait.sh` PASS 1/1 —
  phase-2 `tasks` snapshot shows TWO `state=blocked` user-exec rows (the
  sleeping STATUS43 + the waiting counter) while `procs` still shows
  STATUS43 `state=running` (the target ALIVE while the waiter is blocked),
  then `status43: exiting`, `ipc: saw pid=1 status=43` (the observation —
  the ring resumes the counter directly after the target's exit, so it
  precedes the shell's report drain), and the agreeing kernel records
  `tasks user-exec exited status=43` / `procs STATUS43.BIN exited
  status=43` / `tasks user-exec reaped`; full 12-gate shared-seam sweep +
  args/kill/ipc/scale + the card-4a procs-syscall gate all PASS 1/1
  (evidence under `artifacts/live-wait-*`).
- Docs reconciled (ADR 0007, march-m4, roadmap, status, README,
  gate-inventory), claim flipped, PR #83 opened.
