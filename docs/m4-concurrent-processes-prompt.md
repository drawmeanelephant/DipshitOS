# Milestone-four follow-on — concurrent processes: two live user address spaces

Planning-first prompt doc for DipshitOS, the milestone-four follow-on to
card 3 (the process abstraction, claim 3848, merged PR #72).

- **Branch:** `agent/buffy/m4-concurrent-processes` (claim 0826)
- **Date:** 2026-08-10
- **Depends on:** claim 3848 (the process registry — image + address space +
  lifecycle + exit status as one object), claims 6783 (ESP exec), 5804
  (per-task TTBR0 user roots), 6729 (task lifecycle), 0635 (blocking
  syscalls / `blocked`), 2665/3693 (ASLR stack placement), 3972/5162 (the
  physical page allocator — the per-process page source). The syscall ABI
  (ADR 0007) is frozen and untouched.

## The card

Claim 3848 made the program's image + address space + lifecycle + exit
status one object, but the **exec gate** (`scheduler.user_root_in_use` —
one user program at a time) still forces a single live user root: every
user program runs alone against `mmu.user_root_phys()`, and a second `exec`
is refused until the first program exits AND its task slot is reaped. Build
the concurrency the process object was created for:

1. **Survey the MMU table carve-out** (`build_user_root` /
   `clean_table_storage` / the `table_full` bound) and the
   user-stack/page-table budget for **two live user roots**.
2. **Per-process address spaces** — each Process owns its own root + stack
   pages instead of the shared static `user_stack`, with **per-process**
   `syscall.set_user_regions` bounds.
3. **Relax the exec gate** so a second program can load and run while the
   first is alive (the pool already has a spare-slot pattern from
   `spawn_demo`).
4. **Observe it live** — a `procs` table with TWO `state=running`
   processes and a live gate that execs twice without waiting for the first
   to exit.
5. **Docs/march-m4 reconciliation + claim + PR.**

Keep the syscall ABI (ADR 0007) frozen, no libc/POSIX/heap, host tests
first, class B on VZ.

## Survey (what the code actually looks like today)

- **One user root.** `mmu.build_user_root` clones the identity tree
  (`clone_into_user_root`) and stores the result in the SINGLE module
  global `user_root_value`; `mmu.user_root_phys()` returns it. Exec rebuilds
  it in place (`exec.rebuild_user_root`), which is exactly why the gate
  must prevent a second live task: rebuilding the root under a running task
  would strand it. The clone machinery is per-call — only the storage is
  global, so "return the fresh root" is a small API change.
- **Table budget.** The carve-out is `table_page_count = 256` table pages
  (1 MiB fixed BSS, `table_storage`). Identity map ≈ 10–15 tables; a user
  root clone ≈ 10–15 + leaf tables (the source comment says "the identity
  map uses ~15, the clone ~15"). **Two concurrent user roots ≈ 45 of 256
  pages (~18%) — ample headroom, no carve-out growth.** `new_table` returns
  null at the bound, which `build_user_root` propagates as `false` →
  `ExecResult.table_full`. The `addrspaces` command gains a `tables=NN/256`
  line so the budget is observable on a live boot.
- **Stack budget — the shared objects.** `scheduler.user_stack`
  (`.userbss`, 8 KiB, page-aligned) is the ONLY user stack; exec maps it at
  the randomized `stack_va` in the rebuilt root and `sp_el0 =
  stack_va + user_stack.len`. It is a single object — it cannot serve two
  live processes. **`scheduler.user_kernel_stack` (the EL1 exception stack)
  is also a single object**, and this one is a correctness trap, not just a
  capacity one: the claim-9746 vector frames of a PREEMPTED user task live
  on it, and a second user task taking an exception would push its frame
  over the first task's saved context. Each live user process therefore
  needs its OWN EL1 exception stack too.
- **Regions are global.** `syscall.set_user_regions` → `uaccess.set_regions`
  stores module globals re-armed at every root rebuild. With two live
  tasks, the bounds must follow the CURRENT task: the TCB gains the user
  regions and `syscall.handle_svc` arms them at SVC entry (syscall already
  imports scheduler — no new import cycle; the uaccess diag keeps reading
  the latest regions + latest root, which is fine because every process
  maps text at the same `userspace.text_va`).
- **The pool.** `max_tasks = 5`: shell (0) + worker (1) + user (2) + spare
  (3, the `spawn_demo` pattern) + idle (4). Two live user programs fit
  EXACTLY: shell + worker + user A + user B + idle. A third exec is
  `pool_full`. `spawn_demo` is `null` while two users run — acceptable
  (different command, and the gate doesn't use it).
- **Pages.** The physical allocator (claims 3972/5162) is armed post-boot
  from the captured map with kernel-image exclusions; exec runs from the
  shell, so `alloc.alloc_pages` is available. Per exec: 1 text page + 2
  user-stack pages + 2 EL1 exception-stack pages = 5 pages ≈ 20 KiB —
  trivial against the pool. Host tests arm the module allocator with a
  fixture map so the page path is exercised on the host, not only live.

## Design

### `kernel/src/mmu.zig` — per-process roots

- `build_user_root(...)` returns `?u64` (the NEW root's phys) instead of
  `bool`, still updating the `user_root_value` global (= "most recently
  built user root") so `user_root_phys()` keeps working for the
  `addrspaces`/`uaccess` diagnostics and the boot payload. `null` when the
  carve-out is exhausted (the `table_full` bound, unchanged).
- New `pub fn reset()` (table allocator + root tracking — host tests and
  `build_identity_map` reuse it) and `pub fn tables_used() usize` (the
  `addrspaces` budget line). `clean_table_storage` is unchanged (it cleans
  the whole carve-out once per rebuild — 1 MiB, cheap, and the ADR-0006/
  claim-1517 discipline stays).
- Host test: two `build_user_root` calls return DISTINCT roots and
  `user_root_phys()` tracks the latest (the clone machinery runs on the
  host against an empty root — it still consumes tables, so the API +
  budget accounting is pinned without hardware).

### `kernel/src/process.zig` — the process owns its pages

- `AddrSpace` gains the allocator-owned backing pages:
  `text_phys/text_pages/stack_phys/stack_pages` (counts 0 = static, e.g.
  the boot payload's `.usertext`/`.userbss` — never freed).
- Process gains `kernel_stack: KernelStack { phys, pages }` — the executor
  task's EL1 exception stack (a kernel-side resource owned with the
  process; allocator-backed for exec'd programs, the static
  `user_kernel_stack` for the boot payload).
- `reap` and the `create` recycle path free the owned pages through
  `alloc.free_pages` (no-op when unarmed — host tests that don't arm it
  still pass). Live processes are never reaped/recycled, so a running
  program's pages are never freed under it.
- `create(name, image, addr_space, kernel_stack)` — one new parameter;
  `ProcessInfo` gains the page fields so tests can assert ownership.

### `kernel/src/scheduler.zig` — per-task regions + capacity gate

- Task TCB gains `regions: UserRegions { text, stack }` (zero for EL1h
  tasks) + `pub fn current_user_regions() UserRegions`.
- `register_exec_user(entry_va, root_phys, text_len, stack_va, stack_len,
  kstack: []u8) ?usize` — the caller supplies the process's OWN root, user
  stack, and EL1 exception stack (sp_el0 = stack_va + stack_len; ttbr0 =
  root_phys). `register_user` (boot payload) keeps the static stacks +
  `mmu.user_root_phys()` and fills the TCB regions.
- `user_root_in_use()` is REMOVED — the gate's premise (rebuilding a live
  root) is gone. Exec gates on capacity instead:
  `pub fn has_free_slot() bool` (any `.free` pool slot), plus the existing
  `table_full` and `process_full` bounds.

### `kernel/src/syscall.zig` — the current task's regions

- `handle_svc` arms the uaccess regions from `scheduler.current_user_regions()`
  at every SVC entry (before dispatch), so `sys_write` bounds always follow
  the task that actually issued the syscall. No change to the ABI, table,
  or handlers; EL1h tasks never SVC so the zero-region arm is inert.

### `kernel/src/exec.zig` — per-process pages + relaxed gate

- Delete the `user_root_in_use()` gate (exec step 3). New order: validate
  → `has_free_slot()` (upfront `pool_full`, so a full pool never wastes
  pages/tables) → allocate 1 text + 2 user-stack + 2 kernel-stack pages
  (fail → `out_of_memory`, new ExecResult; nothing leaked) → copy the
  stripped DSK1 content into the text page → `rebuild_user_root(text_phys,
  text_len, stack_phys, stack_len) ?RootInfo{root_phys, stack_va}` (fail →
  free pages, `table_full`) → `process.create` (fail → free pages,
  `process_full`) → `register_exec_user` (fail → `process.reap` frees the
  pages, `pool_full` — defensive; the upfront slot check makes it
  unreachable) → `bind`. Each exec'd process now has its own text page,
  its own user stack, and its own EL1 exception stack — the shared
  `program` buffer is only a staging read buffer (the same-file hazard is
  gone: a different file can never overwrite a live program's text).
- `rebuild_user_root` signature: `(text_phys, text_len, stack_phys,
  stack_len) ?RootInfo` — the shared randomize → map → clean → re-arm
  sequence (claims 2665/3693), now with an explicit stack source.
- `LoadedInfo` gains `stack_va` (from the process descriptor) so the exec
  reply prints the process's OWN stack (reply format unchanged).
- `ExecResult`: drop `user_busy`, add `out_of_memory`; monitor + host tests
  follow.

### `kernel/src/main.zig` / `kernel/src/monitor.zig`

- `main.zig`: the boot ASLR rebuild passes the static stack phys explicitly:
  `exec.rebuild_user_root(user_text.base, user_text.len,
  scheduler.user_stack_phys(), user_stack.len)`.
- `monitor.zig`: `cmd_exec` prints `stack=` from `LoadedInfo.stack_va`
  (per-process), drops the `user_busy` failure line, adds `out_of_memory`;
  `cmd_addrspaces` prints `tables=<used>/<cap>`.

## Definition of done (this card)

Stage A (this landing): per-process roots + pages + regions, the exec gate
relaxed to capacity, all class A gates green, host tests pin two live
processes (exec twice without exit; distinct roots/stacks; third exec →
`pool_full`).

Stage B: live gate `tools/verify-live-concurrent.sh` — script `ls\nexec
USER.BIN\nexec USER.BIN\nprocs\necho rx-concurrent-ok\n`; assert TWO
`procs: … name=USER.BIN state=running` rows (distinct task ids + stack
VAs), both programs' markers interleaving, no `[EXC] parking:`, shell
responsive; registered in gate-inventory + `just verify-vz`; shared-seam
regressions green (exec/procs/tasks/lifecycle/addrspaces/sleep/uaccess/
svc/userspace/entropy).

Stage C: docs/march-m4 reconciliation (new row or follow-on note), roadmap
process bullet, status.md, README, gate-inventory, log append, claim flip,
PR.

## Do not

- Touch the syscall ABI (ADR 0007) or the scheduler's switching core (the
  frame/ELR/SPSR/TTBR0 switch is unchanged — only the TCB gains region
  fields and `register_exec_user` takes the process's own resources).
- Grow the table carve-out or the pool to make the demo fit — the budget
  survey is the deliverable; 256 tables and 5 slots are sufficient for two
  live processes and the numbers are documented.
- Add libc/POSIX/heap allocation anywhere.
- Hand-edit generated indexes (`refresh-indexes.sh` only).
- Claim hardware behavior without a saved VZ log (`artifacts/`).

## Process

1. Claim first (done): claim 0826 in `docs/claims/0826-concurrent-user-address-spaces.md`,
   log in `docs/logs/agent-buffy-m4-concurrent-processes.md`,
   `refresh-indexes.sh`.
2. Write this plan (done), then implement: Stage A — the multi-root MMU,
   per-process pages + regions, relaxed gate, host tests (class A green);
   Stage B — the live gate + regressions (class B on VZ); Stage C — docs
   reconciliation, claim flip, PR.
3. Class A: `zig fmt --check`, unit tests, transcript, build/image/inspect,
   swift build, context, coordination ×2, mmu-debt.
4. Class B: `tools/verify-live-concurrent.sh` + shared-seam regressions.
   Evidence under `artifacts/live-concurrent-*`.
5. Reconcile docs, append the log, flip the claim to ✅, refresh indexes,
   open the PR.
