# Log — milestone four card 3: process abstraction (claim 3848)

- **Branch:** `agent/buffy/m4-process-abstraction`
- **Claim:** [`docs/claims/3848-process-abstraction.md`](../claims/3848-process-abstraction.md)
- **Prompt / plan:** [`docs/m4-process-abstraction-prompt.md`](../m4-process-abstraction-prompt.md)
- **Started:** 2026-08-10

## Progress

- **Claimed** (2026-08-10): claimed milestone-four card 3 (process
  abstraction) on `agent/buffy/m4-process-abstraction` with claim 3848,
  branched off `origin/main` (`d2f163d`, PRs #69/#70 merged; card 2's PR
  #71 is independent). Written plan first
  (`docs/m4-process-abstraction-prompt.md`) — the plan's Stage A (the
  process object + registry + exec/scheduler integration) is this claim's
  first landing.

- **Survey** (2026-08-10): read the binding inputs — march-m4 row 3,
  roadmap ("Eventually: a process abstraction"), `kernel/src/scheduler.zig`
  (the fixed pool: Task = name/state/sp/elr/spsr/sp_el0/ttbr0/counters/
  exit_status/wakeup_tick; spawn/reap lifecycle; exit_current +
  maybe_report), `kernel/src/exec.zig` (the loader: DSK1 parse, the
  rebuild_user_root sequence, register_exec_user, and the sticky module
  globals `loaded_flag`/`loaded_name_buf`/`loaded_content_len`/
  `loaded_entry_va`), `kernel/src/userspace.zig` (text_va/stack_va, the
  user root), `tools/verify-live-exec.sh` (the live chain + script
  semantics) and the runner's script handling (the whole script file is
  forwarded once after `--script-after`; the shell consumes scripted lines
  on its own quanta). **Key observation:** in the captured live-exec serial
  log the shell processes the scripted `echo` BEFORE the background
  program's first marker, so a `procs` read after `exec` deterministically
  shows the process `running`; the post-exit state must be proven by a
  process-level exit report line (printed once at exit), not a second
  `procs` read.

- **Implemented — Stage A (the process object + registry + consumers)**
  (2026-08-10): new `kernel/src/process.zig` — a bounded BSS registry
  (`max_processes = 8`, no allocation) where each Process owns the loaded
  image (entry VA + content length), the address space (root phys, text/
  stack VAs + lengths), the lifecycle state (free → created → running →
  exited), the exit status (snapshotted at exit, survives the task reap),
  and the binding to its executor pool slot. `create` takes the first free
  slot, else recycles the OLDEST exited process (never a live one);
  `on_task_exit` (called from `scheduler.exit_current` — pure writes,
  exception-context safe) marks exited + snapshots status + sets the
  report-pending flag; `take_exit_report` drains it from the shell idle
  loop (`procs <name> exited status=<n>`, mirroring the task report).
  `exec_file` now creates + binds a process (its sticky module globals
  are gone; `loaded()` reads the current process; `ExecResult` gains
  `process_full` for the registry-exhausted case); the boot-time static
  EL0 payload registers as a process too (`register_user`, best-effort);
  `scheduler.init` resets the registry (boot + test isolation). 6 new
  process host tests (lifecycle, status-survives-reuse, bounded-recycle,
  no-op guards) + exec test asserts the two-process table after exec.

- **Verification — Stage A** (2026-08-10): class A all green — fmt, unit
  tests (process 6, exec 87, scheduler 53 — two scheduler report tests
  updated DELIBERATELY for the new process exit line, monitor 166),
  transcript byte-identical (no fixture change), build/image/inspect,
  swift build, context, coordination, test-coordination, mmu-debt. Class
  B sanity on VZ: `live-exec` **1/1** — the serial log now shows the
  process reports `procs user-el0 exited status=7` and
  `procs USER.BIN exited status=43` (the status surviving the task reap)
  alongside the unchanged task lifecycle; boot-path regressions
  tasks/userspace/lifecycle/svc all 1/1.
