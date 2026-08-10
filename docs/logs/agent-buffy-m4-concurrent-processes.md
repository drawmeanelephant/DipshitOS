# Log — milestone-four follow-on: concurrent processes (two live user address spaces)

- **Branch:** `agent/buffy/m4-concurrent-processes`
- **Claim:** [`docs/claims/0826-concurrent-user-address-spaces.md`](../claims/0826-concurrent-user-address-spaces.md)
- **Prompt / plan:** [`docs/m4-concurrent-processes-prompt.md`](../m4-concurrent-processes-prompt.md)
- **Started:** 2026-08-10

## Progress

- **Claimed** (2026-08-10): claimed the milestone-four follow-on card
  (concurrent processes — two live user address spaces) on
  `agent/buffy/m4-concurrent-processes` with claim 0826 (deterministic ID
  from branch+slug), branched off `origin/main` (`a1df132`, PRs #71/#72
  merged). Written plan first
  (`docs/m4-concurrent-processes-prompt.md`) — the plan's Stage A (the
  multi-root MMU + per-process pages + relaxed exec gate + per-task syscall
  regions + host tests) is this claim's first landing.

- **Survey** (2026-08-10): read the binding inputs — claim 3848's process
  registry (`kernel/src/process.zig`: bounded 8-descriptor BSS array,
  create/recycle/bind/on_task_exit/reap), `kernel/src/mmu.zig` (the fixed
  256-page table carve-out; `build_user_root` clones the identity tree into
  the ONE global `user_root_value`; `clean_table_storage` cleans the whole
  carve-out), `kernel/src/scheduler.zig` (the fixed 5-slot pool
  shell/worker/user/spare/idle; `user_root_in_use` gates exec on the single
  current user root; `register_exec_user` reuses the static
  `user_kernel_stack` + `user_stack`), `kernel/src/exec.zig` (the DSK1
  loader + `rebuild_user_root`, which maps the shared `program` text buffer
  + static stack), `kernel/src/syscall.zig` + `kernel/src/uaccess.zig` (the
  module-global regions re-armed at every rebuild), and the live-procs gate.
  **Key observations:** (a) the table carve-out holds ~256 tables vs ~45
  needed for identity + two user-root clones — no carve-out growth needed;
  (b) the static `user_stack` AND the static `user_kernel_stack` are each a
  single object — two live EL0t tasks cannot share either (a second user
  task's exception frames would clobber the first's saved vector frame), so
  exec'd processes must own their own EL1 exception stack too; (c) the
  uaccess regions must follow the current task, so `handle_svc` arms them
  from the TCB at SVC entry (syscall → scheduler import already exists, no
  cycle); (d) the pool's spare-slot pattern (`spawn_demo`, slot 3) is
  exactly the second user slot — max_tasks=5 fits shell + idle + worker +
  two live user tasks.

- **Implemented — Stage A (per-process address spaces + relaxed exec gate)**
  (2026-08-10): `mmu.build_user_root` now RETURNS the fresh root's phys
  (`?u64`) instead of only overwriting the global `user_root_value` (which
  stays as the "most recently built" root for the diagnostics); new
  `mmu.reset()` + `mmu.tables_used()`; `process.zig` — `AddrSpace` gains
  allocator-owned `text_phys/text_pages/stack_phys/stack_pages`, Process
  gains a `KernelStack {phys, pages}` (the executor's EL1 exception stack),
  and reap/recycle free the owned pages via the physical allocator;
  `scheduler.zig` — `user_root_in_use` is GONE (exec never rebuilds a live
  root now), replaced by capacity: `has_free_slot()`, per-task `UserRegions`
  in the TCB (+ `current_user_regions()`), `register_exec_user(entry_va,
  root_phys, text_len, stack_va, stack_len, kstack)`; `syscall.handle_svc`
  arms the current task's regions at entry; `exec.zig` — per-process text +
  user-stack + kernel-stack pages from the physical allocator (5 pages per
  exec), `rebuild_user_root(text_phys, text_len, stack_phys, stack_len)
  ?RootInfo`, `ExecResult` drops `user_busy` and gains `out_of_memory`;
  `monitor.zig` — the `exec` reply's `stack=` reads the process descriptor,
  `addrspaces` prints `tables=NN/256`; `main.zig` — the boot ASLR rebuild
  passes the static stack phys explicitly. Host tests: mmu multi-root test,
  process page-ownership/free tests, scheduler two-live-user-task test,
  exec two-exec-without-exit test (exec USER.BIN twice while the first is
  alive → TWO `state=running` processes with distinct roots/stacks, third
  exec → pool_full), syscall region-arm tests.

- **Verification — Stage A** (2026-08-10): class A all green —
  `zig fmt --check` clean; `verify-unit-tests.sh` (every present module
  passed; exec.zig 121/121 incl. the two-new tests, monitor 179/179);
  `zig build test-console` (203/203 + transcript byte-identical to the
  canonical fixture); `zig build` / `zig build image` / `zig build inspect`
  (KERNEL.BIN + USER.BIN built, image assembled); `swift build`;
  `zig build context`; `verify-coordination.sh` (indexes in sync);
  `test-coordination.sh` (15/15); `verify-mmu-debt.sh` PASS.

- **Implemented — Stage B (the live concurrent gate)** (2026-08-10):
  `tools/verify-live-concurrent.sh` — scripts `ls | exec USER.BIN | exec
  USER.BIN | procs | echo rx-concurrent-ok`, asserts TWO
  `procs: … name=USER.BIN state=running` rows with DISTINCT task ids and
  stack VAs, every EL0 marker twice (both programs execute fully —
  `user: awake` x2 is the completion proof), the worker's advance lines
  between the programs' sleep/wake phases (true interleaving), the boot
  payload's exited row, exit/reap reports ≥1 each (the report flags are
  single-slot "first wins while undrained", so two exits in one idle-loop
  window collapse to one line — an inherent report-machinery property the
  gate documents), a responsive shell, and no exception park. The runner
  runs WITHOUT `--script-expect`: the 1 s scheduler tick makes a USER.BIN
  lifetime ~10 s, so the gate captures the full window (timeout) instead
  of tearing down at the first reap. Registered in `docs/gate-inventory.md`
  (`live-concurrent`, B/gate, + the verify-vz aggregate row),
  `justfile verify-vz`, and README.

- **Verification — Stage B** (2026-08-10): `bash tools/verify-live-concurrent.sh`
  PASS 1/1 on VZ — evidence `artifacts/live-concurrent-serial-01.log`:
  `procs: id=1 name=USER.BIN state=running task=2 stack=0x…4c570000` +
  `procs: id=2 name=USER.BIN state=running task=3 stack=0x…51e50000`
  (two live processes, distinct tasks + stacks), hello/ok/sleeping/awake
  all x2, worker advances between the programs' phases. Shared-seam live
  regressions on the relaxed gate all PASS 1/1: `verify-live-exec` (the
  single-exec path with per-process pages), `verify-live-procs` (process
  table + exit reports), `verify-live-addrspaces` (per-task TTBR0 + the
  new `tables=` line).

- **Verification — Stage B complete (full shared-seam sweep)** (2026-08-10):
  every remaining shared-seam live regression PASSes 1/1 against the
  relaxed gate — `verify-live-tasks` (worker advances across real context
  switches), `verify-live-userspace` (EL0 + SVC round-trip + timer
  preemption), `verify-live-svc` (write/yield/exit counters + ordered
  post-SVC shell), `verify-live-uaccess` (EFAULT contract + real data
  abort recovery), `verify-live-lifecycle` (spawn/exit/reap + explicit
  states), `verify-live-sleep` (blocking sleep/yield/wakeup with worker
  progress during the sleep), `verify-live-entropy` (2 boots: DIFFERENT
  random sequences, exec stack placements, and boot-stack placements —
  the per-process ASLR consumers are non-deterministic across boots, and
  within one boot the exec stack and boot stack land at distinct VAs).
  Nothing to fix — the syscall/lifecycle/uaccess seams are untouched by
  the relaxed gate.

- **Implemented — Stage C (docs reconciliation + claim flip)** (2026-08-10):
  `docs/march-m4.md` gains row 3a (concurrent processes, ✅ done, claim
  0826 + prompt link, stage-by-stage notes incl. the first-wins report
  collapse and the 1 s-tick full-window capture) and the intro + best-agent
  split mention the follow-on; `docs/roadmap.md` gains a "Concurrent
  processes is DONE" bullet next to the process-abstraction bullet;
  `docs/status.md`'s milestone-four row and tracker mention updated (cards
  1 + 2 + 3 + 3a); README + `docs/gate-inventory.md` (`live-concurrent`
  gate) were updated during Stage B. Claim 0826 flipped ✅ done (Stage A +
  B + C complete; PR pending). Indexes refreshed; coordination + test-
  coordination checks green. Remaining: the PR itself.
