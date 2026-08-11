# Milestone-four follow-on 4, card 4c — exit-status propagation: a bounded `sys_wait` block

> **PLANNING-FIRST — this is the per-card split of
> [`m4-followon4-prompt.md`](m4-followon4-prompt.md) (the proposal for
> the whole 4a/4b/4c set). The follow-on-4 set's ABI amendments are slots
> 7 AND 8 (cards 4a/4c) — this card's ONE change is slot 8. No
> libc/POSIX/heap anywhere. New branch `agent/buffy/m4-wait-exit` stacked
> on the card-4b tree (the repo's per-card stacking precedent), claim 9946
> (deterministic).

## Why

A process can EXIT with a status (card 3d), be KILLED (card 3c), and be
observed by the monitor (card 4a) — but no other PROCESS can wait for
that outcome. The kernel already owns lifetime; this card lets one
process block until another's exit and receive its status — the second
half of the "real OS" proof: not just "who is alive / what did they
return" (4a), but "block on a peer's death and learn its status".

## Scope

1. **ADR 0007 amendment** (this card's ONE ABI change): `sys_wait(pid)` =
   slot 8 — block the CALLER until the process with id `pid` exits (or is
   already exited), then return its snapshotted status (the registry keeps
   it past the reap — claim 3848). `implemented_count` 8 → 9; `syscalls`
   rows 0–8. Follow the `sys_sleep` slot-4 block/resume precedent (the
   blocked task drops out of the ring with its SVC frame saved; the wakeup
   flips it back to `ready` and the ring resumes it from that same frame)
   — do NOT touch the switching core or the lifecycle states. NOT POSIX
   wait: no zombies, no fds, no process-tree semantics — a bounded,
   kernel-owned "block until target exits, then return its status".
2. **The wakeup seam:** the exit path (`scheduler.exit_current` →
   `process.on_task_exit`) resolves the exiting task's pid BEFORE the
   registry flip (the registry only maps RUNNING tasks), then wakes every
   waiter on that pid, patching the status into each waiter's saved SVC
   frame's x0 (the same slot the dispatch layer writes the syscall result
   into) — so the resumed `sys_wait` returns the status. The wait table
   is bounded BSS (`wait_max = max_tasks` — a blocked task occupies its
   pool slot, one waiter per slot; a full table is EINVAL, documented).
3. **Refusals, documented + host-tested:** a pid outside the registry /
   a free pid / a pid that never belonged to a process (the shell, the
   worker, and the idle task are TASKS, not processes — the console can
   never be waited on and always survives); SELF-wait (the caller waiting
   on its own pid — it can never be woken: deadlock) → EINVAL; an
   ALREADY-EXITED target returns immediately (no block); the bounded
   wait-table-full → EINVAL.
4. **Host tests:** the block → target exit → status return path (the
   waiter parks, the target exits, `wake_waiters` patches the frame, the
   resumed `sys_wait` returns the exact status); already-exited → returns
   immediately without blocking; the refusals (nonexistent / free /
   never-a-process / self); the frame/syscall marshaling for slot 8; the
   `syscalls` report rows 0–8; the exit/reap FIFO reports still print
   exactly once with a waiter present.
5. **Live gate `tools/verify-live-wait.sh`** (new, class B): phase 1
   `exec COUNTER.BIN 2` — the counter's argv[1] is the wait target pid;
   it prints `counter: waiting <pid>`, then blocks in `sys_wait`. Phase 2
   (after the waiting marker) `exec USER.BIN` — USER.BIN (pid 2) runs and
   exits status 43. The counter wakes and prints `counter: saw exit 43`
   after the exit line — end-to-end exit-status propagation between live
   processes at the 7-slot pool (a blocked waiter occupies its slot; the
   counter is still running at the final `procs`, never exits). The
   shared-seam live sweep must stay green.

## Sequence

1. Claim first (this prompt + `docs/claims/9946-wait-exit.md` +
   `docs/logs/agent-buffy-m4-wait-exit.md` + `refresh-indexes.sh`).
2. Class A first: fmt, unit tests, transcript byte-identical
   (`zig build test-console`), build/image/inspect, swift build, context,
   coordination ×2, mmu-debt.
3. Class B on VZ: the new `verify-live-wait.sh` + the FULL 12-gate
   shared-seam live sweep (exec/procs/concurrent/tasks/lifecycle/
   addrspaces/sleep/svc/uaccess/userspace/entropy/long-lived) plus the
   args/kill/ipc/scale + procs-syscall gates, evidence saved under
   `artifacts/`.
4. Docs reconciliation: ADR 0007 (slot-8 amendment), march-m4 row, roadmap,
   status, gate-inventory (new live-wait row), README, claim flip, log
   append, PR per the repo template (real observed evidence only).

## Do not

- Grow the pool (`max_tasks` stays 7); touch the switching core or the
  lifecycle states.
- Add POSIX wait semantics — no zombies, no fds, no process-tree, no
  wait-any (`waitpid(-1)`).
- Touch syscall numbers 0–7 (slot 8 is THIS card's only ABI change).
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
