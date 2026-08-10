# Milestone four, card 3 — process abstraction above the fixed task pool

Planning-first prompt doc for DipshitOS, milestone-four card 3 (march-m4 row 3).

- **Branch:** `agent/buffy/m4-process-abstraction` (claim 3848)
- **Date:** 2026-08-10
- **Depends on:** milestone-three close-out (tag `m3-userspace`), the task
  lifecycle (claim 6729), ESP exec (claim 6783), per-task address spaces
  (claim 5804), the syscall ABI (ADR 0007). Card 2 (general filesystem,
  claim 3678) is independent of this card and merged separately.

## The card

Today a user program has no identity of its own. The loaded-image descriptor
lives in `exec.zig` module globals (`loaded_flag`, `loaded_name_buf`,
`loaded_content_len`, `loaded_entry_va`), the address space is a global
"current user root" (`mmu.user_root_phys()` + `userspace.current_stack_va`),
and the exit status lives only in the pool slot's zombie until the idle task
reaps it — the unit that owns image + address space + state + exit status
does not exist. Build it:

1. **Process object + registry** (`kernel/src/process.zig`): a bounded BSS
   registry where each Process owns the loaded-image descriptor (name,
   entry VA, content length), the address space (root phys, text VA/len,
   stack VA/len), the lifecycle state, the exit status (snapshotted at exit
   so it survives the task slot's reuse), and the binding to its executor
   pool slot. The task pool stays the executor; the process is the unit
   that owns the program.
2. **Real consumers**: `exec_file` creates + binds a process (its sticky
   module globals migrate into the descriptor); the boot-time static EL0
   payload (claim 8215, `register_user`) registers as a process too; the
   scheduler's exit path notifies the registry so exit status flows
   Task-zombie → Process and outlives the reap. The exec gate (one user
   program at a time) is unchanged — the process table and the task pool
   both drain through the claim-6729 lifecycle.
3. **Observability** (`procs` monitor command, registry 29→30): prints the
   process table (id, name, state, bound task, stack VA, exit status),
   grep-able and deterministic, plus a process-level exit report line from
   the shell idle loop (the deterministic live proof — a `procs` table read
   after the program exits is racy because the shell consumes scripted
   lines on its own quanta before the background program runs, observed in
   live-exec's own serial logs).
4. **Live gate** (`tools/verify-live-procs.sh`): boot the VM, exec the ESP
   user program, assert the process table (the exec'd process `running`
   with its image/stack VA — deterministic, the shell prints it before the
   program's first quantum), the process-level exit report (`status=43`),
   the unchanged task lifecycle lines, and shell responsiveness.
5. **Docs**: march-m4 row 3 ⬜ → ✅; roadmap "Eventually: a process
   abstraction" → done; status.md milestone-four row + command count
   29→30; README; gate-inventory + `just verify-vz`. This prompt doc lives
   at `docs/m4-process-abstraction-prompt.md`.

## Why the process is not a rename of Task

The pool slot (Task) is the executor: context, TTBR0 switch, quantum
bookkeeping, zombie/reap. The Process is the program: what was loaded
(image), where it runs (address space), its lifecycle, and its exit status.
The deltas that matter, all observable:

- **Exit status survives the task reap.** Today `terminated_status` dies
  with the idle task's `reap`; the process keeps it (and `procs` shows it)
  until the descriptor is recycled.
- **Per-process identity.** Exec twice → two process descriptors; `loaded()`
  reads the current process instead of one sticky global.
- **The boot payload is a process too** — one table shows the static
  payload's exited status=7 AND the exec'd program's lifecycle over a boot.

## Design

### `kernel/src/process.zig` (new)

- `pub const max_processes: usize = 8` — fixed BSS array, no allocation,
  no libc, no POSIX (module discipline).
- `State`: `free`, `created` (loaded, not yet bound/run), `running` (bound
  task live), `exited` (bound task became a zombie; status snapshotted).
  Reap frees (`free`); the registry recycles the oldest `exited` when a
  create needs a slot (never a `created`/`running` process).
- `Process` fields: `name`, `state`, `image { entry_va, content_len }`,
  `addr_space { root_phys, text_va, text_len, stack_va, stack_len }`,
  `task_id` (bound slot; cleared at exit), `exit_status`.
- API (all pure, console-free, no allocation):
  - `init()`, `reset()` (host tests),
  - `create(name, image, addr_space) ?usize` (first free, else oldest
    exited; null when only live processes exist → `process_full`),
  - `bind(proc_id, task_id)`, `on_task_exit(task_id, status)` (marks
    `exited`, snapshots status, clears the binding, sets a report-pending
    flag — callable from exception context, same pattern as the task
    exit report),
  - `current()` / `find_by_task(task_id)`, `lookup(id)`, `count()`,
    `info(id) ?ProcessInfo`, `stats()`.
- Host tests: full lifecycle transition sequence, status surviving a task
  reap + slot reuse, bounded registry + oldest-exited recycle, bind/
  unbind, create-then-bind ordering, no live-process eviction.

### `kernel/src/exec.zig`

- `exec_file` replaces its module globals: after `rebuild_user_root`
  returns the stack VA, `process.create(...)` (image + the new address
  space), `register_exec_user`, then `process.bind(proc_id, task_id)`.
  `ExecResult` gains `process_full` (registry exhausted while processes
  live); `loaded()` reads the current process's descriptor.
- The exec reply format is unchanged (`exec: loaded USER.BIN size=… entry=…
  stack=… head=…`) — transcript/live-gate strings untouched.

### `kernel/src/scheduler.zig`

- `exit_current` calls `process.on_task_exit(current, status)` after
  staging the zombie (IRQ-context safe: pure registry writes, no console).
- `register_user` (boot static payload) creates + binds a process before
  spawn, so the boot payload is process 0. Its image is the static
  payload (no file name; entry VA via `image_user_va`), its address space
  the current user root at the fixed `userspace.stack_va`.
- `maybe_report` prints the process exit report (one line, pending flag,
  mirroring `tasks … exited`): `procs <name> exited status=<n>`.
- Scheduler → process import is one-way (no cycle); `process.zig` knows
  nothing about the scheduler's internals.

### `procs` monitor command (Stage B)

- Registry row between `pci` and `random` alphabetically (registry_count
  29→30); help/usage in shell.zig + the transcript fixture (byte-exact
  perl edit — never let str_replace normalize the mixed CRLF/LF fixture).
- Output, one line per non-free process:
  `procs: id=<i> name=<name> state=<s> task=<id|reaped> stack=0x… exit=<status|->`
  (ids/counts decimal via print_u64; addresses/sizes hex).
- Host test pins the format with a seeded registry.

### Live gate `tools/verify-live-procs.sh` (Stage B)

- Boot with the same script pattern as live-exec (script-after = the
  static payload's exit line, so the user root is free): script
  `ls\nexec USER.BIN\nprocs\necho rx-procs-ok\n`, expect =
  `tasks user-exec reaped` (the run covers the full lifecycle).
- Asserted, all deterministic:
  - `exec: loaded USER.BIN size=…` (process created),
  - a `procs:` line showing `name=user-exec state=running stack=0x…`
    (the shell prints it before the program's first quantum — the
    observed live-exec ordering: the echo reply lands before the program
    markers, so the pre-run `procs` is guaranteed),
  - the static payload's process `exited status=7` in the same table,
  - the program markers + `tasks user-exec exited status=43` + `tasks
    user-exec reaped` (unchanged lifecycle),
  - the process exit report `procs user-exec exited status=43` (the
    post-exit status the task lifecycle alone cannot show),
  - `rx-procs-ok` (shell responsive), no `[EXC] parking:`.
- Registered in `docs/gate-inventory.md` + `just verify-vz`.

## Do not

- Touch the syscall ABI (ADR 0007) or the scheduler's switching core.
- Change the exec gate (`user_root_in_use`) — one user program at a time
  stays; two LIVE user address spaces are the natural follow-on card.
- Add libc/POSIX/heap allocation anywhere; use a `const` function-pointer
  table (ADR 0005).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
- Claim hardware behavior without a saved VZ log (`artifacts/`).

## Process

1. Claim first (🔄): claim 3848 in `docs/claims/3848-process-abstraction.md`,
   log in `docs/logs/agent-buffy-m4-process-abstraction.md`,
   `refresh-indexes.sh`.
2. Write this plan (done), then implement: Stage A — `process.zig` +
   exec/scheduler integration + host tests (class A green); Stage B —
   `procs` command + fixture + live gate + regressions; Stage C — docs
   reconciliation, claim flip, PR.
3. Class A: `zig fmt --check`, unit tests (register `process` in
   `tools/verify-unit-tests.sh`), `zig build test-console`, `zig build`,
   `zig build image`, `zig build inspect`, `swift build --package-path
   host/vm-runner`, `zig build context`, coordination ×2, mmu-debt.
4. Class B live gate `tools/verify-live-procs.sh` (registered in
   gate-inventory + `just verify-vz`) + shared-seam regressions
   (exec/tasks/lifecycle/addrspaces/userspace/entropy/gfs/fs). Evidence
   under `artifacts/live-procs-*`.
5. Reconcile docs (march-m4 row 3, roadmap, status, README,
   gate-inventory), append the log, flip the claim to ✅, refresh indexes,
   open the PR.

## Definition of done

A bounded process registry where the loaded image, address space, lifecycle
state, and exit status are one object; exec and the boot payload are real
processes; `procs` shows the lifecycle and the exit status survives the
task reap; all class A + class B gates green; docs reconciled; claim
closed; PR open.
