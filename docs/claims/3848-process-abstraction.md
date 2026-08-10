# Claim: process abstraction above the fixed task pool

- **Owner:** Buffy (`agent/buffy/m4-process-abstraction`)
- **Prompt / plan:** milestone-four march card 3 ([`docs/march-m4.md`](../march-m4.md)):
  "A process object above the fixed task pool (address space, state,
  exit/reap, loader) — the milestone-three task lifecycle is the seam
  (claims 6729/6783)". Written plan first:
  [`docs/m4-process-abstraction-prompt.md`](../m4-process-abstraction-prompt.md).
- **Scope:** the pool slot (Task) is the executor; the card adds the unit
  that owns the PROGRAM — image + address space + lifecycle state + exit
  status. New `kernel/src/process.zig` (bounded BSS registry, no alloc);
  `exec_file` creates + binds a process (its sticky module globals
  migrate into the descriptor); the boot-time static EL0 payload registers
  as a process too; `exit_current` notifies the registry so exit status
  survives the task reap; `procs` monitor command (registry 29→30) +
  process-level exit report; new class-B live gate. The exec gate (one
  user program at a time) and the syscall ABI (ADR 0007) are untouched.
- **Depends on:** milestone-three close-out (tag `m3-userspace`), claims
  6729 (task lifecycle), 6783 (ESP exec), 5804 (per-task address spaces),
  8215 (boot static EL0 payload), 3594/6120 (syscall ABI + uaccess).
- **Status:** 🔄 in progress 2026-08-10 — Stages A + B landed: the
  process object + registry + exec/scheduler integration (Stage A) and
  the `procs` monitor command + live gate (Stage B); Stage C (docs
  reconciliation + claim flip) remains.

## Notes

**Why it matters:** a loaded user program has no identity today — the image
descriptor lives in exec's module globals, the address space is a global
"current user root", and the exit status dies with the idle task's reap of
the zombie slot. The process makes image + address space + state + exit
status one bounded, observable object above the pool, and the exit status
survives the task slot's reuse.

**Stage A design:** `process.zig` — `max_processes = 8`, fixed BSS array;
`State = free | created | running | exited`; a Process carries `name`,
`image { entry_va, content_len }`, `addr_space { root_phys, text_va,
text_len, stack_va, stack_len }`, `task_id` (the bound executor slot,
cleared at exit), `exit_status` (snapshotted at exit). `create` takes the
first free slot, else recycles the oldest `exited` (never a live process).
`exit_current` calls `on_task_exit(current, status)` — pure registry
writes, exception-context safe, the same report-pending pattern as the
task exit report. Scheduler → process is a one-way import (no cycle).

## Verification

- **Class A:** fmt, unit tests (new `process` module registered in
  `tools/verify-unit-tests.sh`, plus exec/scheduler/monitor updates),
  transcript byte-identical, build/image/inspect, swift build, context,
  coordination ×2, mmu-debt.
- **Class B:** new `tools/verify-live-procs.sh` **PASS 1/1 on VZ** — the
  live table shows the exec'd program `name=USER.BIN state=running` (with
  its ASLR stack VA) alongside the boot payload's process
  `name=user-el0 state=exited task=reaped exit=7`, the process exit
  report `procs USER.BIN exited status=43` prints, the task lifecycle
  lines are unchanged, and the shell stays responsive; shared-seam
  regressions (exec/tasks/lifecycle/addrspaces/userspace) green.
- **Evidence:** `artifacts/live-procs-*`, `artifacts/live-exec-*`
  (evidence `artifacts/live-procs-serial-01.log` shows the full table).
