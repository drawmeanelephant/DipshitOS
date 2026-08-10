# Claim: concurrent processes — two live user address spaces

- **Owner:** Buffy (`agent/buffy/m4-concurrent-processes`)
- **Prompt / plan:** milestone-four follow-on card (the process abstraction,
  claim 3848 / PR #72, made image + address space + lifecycle + exit status
  one object; this card removes the last single-program constraint — the
  exec gate). Written plan first:
  [`docs/m4-concurrent-processes-prompt.md`](../m4-concurrent-processes-prompt.md).
- **Scope:** (1) survey the MMU table carve-out + user-stack/page-table
  budget for TWO live user roots; (2) per-process address spaces — each
  Process owns its own TTBR0 user root + allocator-backed text/stack/kernel
  stacks instead of the shared static `user_stack`, with per-process
  `syscall.set_user_regions` bounds (armed per task at SVC entry); (3) relax
  the exec gate so a second program loads and runs while the first is alive
  (the pool's spare-slot pattern, one extra EL0t slot); (4) observable live —
  a `procs` table with TWO `state=running` processes and a live gate that
  execs twice without waiting for the first to exit; (5) docs/march-m4
  reconciliation + claim + PR. Syscall ABI (ADR 0007) frozen; no
  libc/POSIX/heap; host tests first; class B on VZ.
- **Depends on:** milestone-four card 3 (claim 3848 — the process registry,
  `procs`, the process exit report), claims 6783 (ESP exec), 5804 (per-task
  address spaces), 6729 (task lifecycle), 0635 (blocking syscalls — the
  `blocked` state), 2665/3693 (ASLR stack placement), the physical
  allocator (claims 3972/5162 — the per-process page source).
- **Status:** ✅ done — Stage A (the multi-root MMU, per-process pages,
  relaxed gate, per-task syscall regions + host tests) and Stage B (the
  live concurrent gate + full shared-seam regression sweep) landed
  2026-08-10; Stage C (docs reconciliation, this flip) complete.
- **PR:** pending — the branch `agent/buffy/m4-concurrent-processes` is
  ready to open against `main`.

## Notes

**Why it matters:** the process abstraction (claim 3848) gave every program
image + address space + lifecycle + exit status as one object, but the exec
gate (`scheduler.user_root_in_use`, one user program at a time) still forces
a single live user root — every user program runs alone against
`mmu.user_root_phys()`. Two live programs cannot exist: the second exec is
refused until the first exits and its task slot is reaped. This card makes
concurrency real: each exec builds a FRESH user root (the identity-tree
clone machinery already returns per-call roots — `build_user_root` just
overwrites the one global), allocates its own text + user-stack + EL1
exception-stack pages from the physical allocator (the boot payload keeps
the static `.userbss` stack), and arms the syscall/uaccess regions per task
at SVC entry, so the bounds always follow the CURRENT process. The exec
gate becomes capacity: the pool's free slot, the page-table carve-out, the
process registry.

**Key design facts (from the survey):**

- **MMU table budget:** the fixed carve-out is 256 table pages (1 MiB BSS).
  The identity map uses ~10–15; each user-root clone costs ~10–15 + leaf
  tables. Two concurrent user roots ≈ 45 of 256 pages (~18%) — ample
  headroom; `build_user_root` returns null (→ `ExecResult.table_full`) when
  the carve-out is exhausted, and `addrspaces` gains a `tables=NN/256`
  line so the budget is observable.
- **Stack budget:** the static `user_stack` (`.userbss`, 8 KiB) is a single
  object — it cannot serve two live processes. Exec'd processes allocate
  their own pages from the physical allocator (5 pages per exec: 1 text +
  2 user stack + 2 EL1 exception stack), freed when the process is reaped
  or recycled. The EL1 exception stack MUST be per process too: two EL0t
  tasks sharing `user_kernel_stack` would clobber each other's saved vector
  frames (a preempted task's frame is only safe if no other user task
  pushes onto the same stack).
- **Regions:** the uaccess regions are module globals set by the last
  rebuild; with two live tasks they must follow the CURRENT task.
  `syscall.handle_svc` now arms the regions from the current task's TCB at
  every SVC entry (syscall already imports scheduler — no new import cycle).

## Verification

- **Class A:** fmt, unit tests (mmu/process/scheduler/syscall/exec/monitor
  — the exec tests arm the physical allocator with a fixture map so the
  per-process page path is exercised on the host), transcript
  byte-identical, build/image/inspect, swift build, context, coordination
  ×2, mmu-debt — all green.
- **Class B — the live gate:** `tools/verify-live-concurrent.sh` **PASS
  1/1 on VZ** — exec USER.BIN TWICE without waiting for the first to exit;
  the `procs` snapshot shows TWO `name=USER.BIN state=running` rows with
  distinct task ids (2/3) and distinct ASLR stack VAs; every EL0 marker
  lands twice and the worker's advance lines appear between the programs'
  sleep/wake phases (true interleaving); both programs reach `user: awake`
  (the exit/reap report flags are single-slot "first wins while undrained",
  so those lines assert ≥1); shell responsive; no exception park. Evidence
  `artifacts/live-concurrent-*`.
- **Class B — shared-seam regressions:** the FULL sweep against the
  relaxed gate PASSes 1/1 each — exec, procs, addrspaces (with the new
  `tables=` line), tasks, userspace, svc, uaccess, lifecycle, sleep, and
  entropy (2 boots, distinct ASLR placements). Nothing to fix.
- **Table budget (observed):** the fixed 256-page carve-out holds the
  identity map + the boot root + two exec'd roots with ample headroom
  (`addrspaces: tables=NN/256`).
