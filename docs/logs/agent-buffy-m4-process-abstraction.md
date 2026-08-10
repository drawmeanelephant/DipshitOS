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

- **Implemented — Stage B (the `procs` command + the live gate)**
  (2026-08-10): `kernel/src/monitor.zig` — the `procs` registry row
  (help "process registry: image, address space, lifecycle, exit status")
  and `cmd_procs`, which prints the process table one line per descriptor:
  `procs: id=<n> name=<name> state=<s> task=<id|reaped|-> stack=0x…
  exit=<status|->` (counts decimal, addresses hex — the `tasks`/`addrspaces`
  style). The exited process reports its status with `task=reaped` (the
  binding dissolved at exit); created/running show `-`. Registry count
  28→29 on this branch (card 2's `mount` — also 28→29 — is not merged
  yet; the merge will reconcile). shell.zig help row + the transcript
  fixture updated DELIBERATELY (byte-exact single-line perl insertion —
  the fixture's mixed CRLF/LF preserved). New monitor host test pins the
  exact two-process table (exited boot payload `exit=7` + running
  USER.BIN bound to task 2). New class-B gate `tools/verify-live-procs.sh`
  (registered in gate-inventory + `just verify-vz`).

- **Verification — Stage B** (2026-08-10): class A all green — fmt, unit
  tests (monitor 167), transcript byte-identical, build/image/inspect,
  swift build, context, coordination, test-coordination, mmu-debt. Class
  B on VZ: new `verify-live-procs.sh` **PASS 1/1** — the live table is
  `procs: id=0 name=user-el0 state=exited task=reaped stack=0x… exit=7`
  and `procs: id=1 name=USER.BIN state=running task=2 stack=0x… exit=-`
  (the ASLR-randomized stack), plus the process report `procs USER.BIN
  exited status=43` and the unchanged task lifecycle; live-exec
  regression 1/1 (evidence `artifacts/live-procs-*`). Two gate-script
  bugs fixed en route: `grep -x` on the `exec: loaded` line (it is a
  partial line) and the `user: hello from the ESP` marker (it carries a
  `dipshit> ` prompt prefix on the serial line) — both now substring
  matches like live-exec's proven assertions.

- **Docs reconciled — claim closed** (2026-08-10): claim 3848 → ✅;
  march-m4 row 3 ✅ (network remains ⬜; card 2's row lands with PR
  #71); roadmap process-abstraction sketch → done; status.md
  milestone-four row + related-docs pointer + 28→29 command count;
  README (29 commands, card-3 paragraph); gate-inventory `live-procs`
  row + `verify-vz` aggregate (Stage B); indexes refreshed. Committed +
  PR #72 finalized.
