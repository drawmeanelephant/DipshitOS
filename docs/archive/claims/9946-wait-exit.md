# Claim: exit-status propagation — a bounded `sys_wait` block (card 4c)

- **Owner:** Buffy (`agent/buffy/m4-wait-exit`)
- **Prompt / plan:** milestone-four follow-on 4, card 4c (the third card
  of the 4a/4b/4c set — the proposal doc
  [`docs/m4-followon4-prompt.md`](../m4-followon4-prompt.md), split per
  card: [`docs/m4-wait-exit-prompt.md`](../m4-wait-exit-prompt.md)).
  Written plan first; stacked on the card-4b tree (PR #82), merge order
  4a → 4b → 4c.
- **Scope:** (1) **ADR 0007 amendment** (this card's ONE ABI change —
  `implemented_count` 8 → 9, `syscalls` rows 0–8): `sys_wait(pid)` =
  slot 8 — block the CALLER until the process with id `pid` exits (or is
  already exited), then return its snapshotted status (the registry keeps
  it past the reap — claim 3848). Follows the `sys_sleep` slot-4
  block/resume precedent (blocked task drops out of the ring with its SVC
  frame saved; the wakeup flips it back to `ready`); the switching core
  and the lifecycle states are untouched. NOT POSIX wait — no zombies, no
  fds, no process-tree, no wait-any: a bounded, kernel-owned block. (2)
  **The wakeup seam:** `exit_current` resolves the exiting task's pid
  BEFORE the registry flip (`find_by_task` maps only RUNNING tasks), then
  wakes every waiter on that pid, patching the status into each waiter's
  saved SVC frame's x0 (the dispatch layer's result slot) — the resumed
  `sys_wait` returns the exact status. The wait table is bounded BSS
  (`wait_max = max_tasks` — a blocked waiter occupies its pool slot; a
  full table is EINVAL). (3) **Refusals, documented + host-tested:** a
  pid outside the registry / free / never-a-process (the shell, worker,
  and idle are TASKS — the console can never be waited on); SELF-wait →
  EINVAL; an already-exited target returns immediately; wait-table-full →
  EINVAL. (4) **Host tests:** block → target exit → status return;
  already-exited returns immediately; refusals; the slot-8 frame
  marshaling; the `syscalls` rows 0–8; the exit/reap FIFO reports still
  print exactly once with a waiter present. (5) **New class-B gate
  `tools/verify-live-wait.sh`:** phase 1 `exec COUNTER.BIN 2` — the
  counter's argv[1] is the wait target; it prints `counter: waiting <pid>`
  then blocks in `sys_wait`; phase 2 (after the waiting marker)
  `exec USER.BIN` — USER.BIN (pid 2) exits status 43; the counter wakes
  and prints `counter: saw exit 43` after the exit line — end-to-end
  exit-status propagation between live processes at the 7-slot pool (a
  blocked waiter occupies its slot; the counter never exits, shell
  responsive). Do NOT grow the pool (`max_tasks` stays 7), touch the
  switching core / lifecycle states, or add POSIX wait semantics /
  pipes/fds/signals/heap. No libc/POSIX; host tests first; class B on VZ.
- **Depends on:** cards 4a (claim 5799 / PR #81) + 4b (claim 3179 /
  PR #82) — this branch stacks on the card-4b tree (ADR 0007's slot-7
  amendment, the 8-slot mailbox, and the bursty PEER/COUNTER are
  current); merge order 4a → 4b → 4c. Independent of 4a/4b mechanics
  (the wait path is orthogonal to sys_procs and the mailbox capacity).
- **Status:** ✅ done 2026-08-11 on `agent/buffy/m4-wait-exit` (PR #83)

## Notes

**Why it matters:** a process can EXIT with a status (3d), be KILLED
(3c), and be observed by the monitor (4a) — but no other PROCESS can wait
for that outcome. The kernel already owns lifetime; this lets one process
block until another's exit and receive its status — the "block on a
peer's death" half of the real-OS proof, complementing 4a's "who is
alive".

**Key design facts:**

- **The sleep precedent, exactly:** `sleep_current` saves the caller's
  SVC frame (sp/elr/spsr/sp_el0), parks the task (`state=blocked`), and
  stages the next task; `wake_expired` flips it back to `ready` and the
  ring resumes it from the same frame. `sys_wait` uses the identical park
  seam (`scheduler.wait_current`) — but its wakeup is keyed on the
  TARGET PROCESS's exit, not a tick deadline, and the tick clock never
  touches an event-blocked task (`wake_expired` skips tasks whose
  `wait_pid` is set). The status lands in the waiter's saved x0 (the
  slot the dispatch layer writes every syscall result into) — patched by
  `wake_waiters` at exit — so the resumed `sys_wait` returns it — no new
  resume mechanism.
- **The wakeup is exception-context-safe:** `exit_current` runs from the
  exiting task's exception frame; the wait state lives ON THE TASK TCB
  (`wait_pid` — bounded by the pool itself, a blocked waiter occupies
  its pool slot; no separate table, no allocation, no console), and
  `wake_waiters` only flips task states and patches a saved frame's x0.
- **The pid is resolved AFTER the registry records the exit:**
  `on_task_exit` now RETURNS the pid of the process it flipped (the
  registry flip is the wake trigger), and `exit_current` calls
  `wake_waiters(pid, status)` right after it — the waiter's saved frame
  gets the status before the ring can reach it again.
- **The console can never be waited on:** the shell, the worker, and the
  idle task have NO process descriptor — `sys_wait` from an EL1h task is
  EINVAL. Free/out-of-range pids, a `created` (loaded, not yet running)
  target (it may never run — the kernel refuses a waiter that could
  never wake), and self-wait (the deadlock) are all EINVAL; an
  already-exited target returns its stored status immediately. A blocked
  waiter occupies its pool slot (documented pool math: STATUS43 + the
  counter + shell + worker + idle = 5/7 in the live gate).

## Verification

- **Class A:** fmt, unit tests (the wait table row; already-exited →
  immediate; the EINVAL refusals — non-process caller, free/out-of-range
  pid, self-wait, created target; the full block → target exit → wake →
  status-in-saved-frame cycle; the slot-8 frame marshaling; `syscalls`
  rows 0–8), transcript byte-identical, build/image/inspect (the fourth
  ESP program embedded + self-verified), swift build, context,
  coordination ×2, mmu-debt — all green.
- **Class B — the new gate:** `tools/verify-live-wait.sh` PASS 1/1 on VZ
  — phase 1 `ls | exec STATUS43.BIN | exec COUNTER.BIN 0 1 | procs |
  echo` (argv[0] = 0 keeps the IPC path silent, argv[1] = 1 is the wait
  target), phase 2 (after `ipc: waiting pid=1`) `tasks | procs | echo`:
  the serial log shows `status43: alive`, the counter's `ipc: waiting
  pid=1`, a `tasks` snapshot with TWO `state=blocked` user-exec rows (the
  sleeping STATUS43 + the waiting counter — the blocking proof) while
  `procs` still shows `id=1 name=STATUS43.BIN state=running` (the target
  ALIVE while the waiter is blocked), then `status43: exiting`, the
  counter's `ipc: saw pid=1 status=43` (the observation — the ring
  resumes the counter directly after the target's exit, its slot being
  next, so the observation precedes the shell's report drain), and the
  agreeing kernel records `tasks user-exec exited status=43` /
  `procs STATUS43.BIN exited status=43` / `tasks user-exec reaped` (the
  runner's `--script-expect` terminal line). Evidence under
  `artifacts/live-wait-*`.
- **Class B — shared-seam regressions:** the full 12-gate live sweep
  (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/
  userspace/entropy/long-lived) all PASS 1/1, plus the args/kill/ipc/
  scale and card-4a procs-syscall gates.
