# Claim: user task lifecycle (explicit states, spawn/exit/reap, idle task)

- **Owner:** Buffy (`agent/buffy/m3-lifecycle`)
- **Prompt / plan:** milestone-three march card 5 ([`docs/march-m3.md`](../march-m3.md)),
  following the per-task address spaces card (claim 5804). Card text: user
  task lifecycle — **spawn / exit / reap, explicit task states, and an idle
  task around the existing tick-driven scheduler**.
- **Scope:** the milestone-three lifecycle half of the scheduler. Each pool
  slot carries an explicit `State` (`free -> ready -> running -> zombie ->
  free`); `spawn` allocates the first free slot (bounded, no allocation);
  `exit_current` (the `sys_exit` path) turns the current task into a
  zombie; the scheduler-owned **idle task** (registered at the last slot,
  always ready) reaps one zombie per iteration; a `spawn` monitor command
  exercises a runtime spawn with a dedicated demo stack; the `tasks`
  monitor command reports explicit states + pool/zombie counts; and — the
  card's hidden load-bearing fix — the **claim-9746 vector frame is
  extended from 20 to 32 slots to save the AAPCS callee-saved registers
  (x19..x28 + x29)**, without which a context switch corrupts a resumed
  task's live registers (root-caused on VZ; see the verification section).
- **Depends on:** claims 5275/8215 (tick scheduler + EL0 task), 5804
  (per-task TTBR0 roots), 3594 (syscall ABI — `sys_exit`), 9746/9187
  (exception vectors + timer IRQ), 6120 (uaccess EFAULT window).
- **Status:** ✅ done 2026-08-10

## Notes

**Why the lifecycle is explicit and bounded:** the pool is fixed at
comptime (`max_tasks = 5`: shell, worker, user-el0, one spawnable demo
slot, idle). `spawn` scans for the first `free` slot and returns `null`
when the pool is full — no dynamic allocation, no parent/child
relationship. `exit_current` refuses to exit the idle task and rolls back
if no successor exists (unreachable in a normal boot — the always-ready
idle task is the ring's fallback, so an exit always has a successor).
`reap` frees only a zombie slot, and the idle task's `reap_one_zombie`
frees one zombie per iteration so the pool drains without starving other
tasks. The freed slot is spawnable again — the lifecycle is a closed loop.

**The callee-saved vector-frame fix (the card's real bug, measured on VZ):**
the claim-9746 stubs pushed a 20-slot frame (x0..x17 + x30) — the
caller-saved registers only. That is fine for a plain IRQ that returns to
the same context, but a **context switch** resumes a DIFFERENT task, whose
live x19..x28 were never saved per-task. The resumed task therefore kept
the *preempting* task's callee-saved values. This is a latent claim-5275
design bug that the earlier code layout happened to dodge; adding the idle
task (+ one ring slot) shifted the codegen so the shell's `mon` (held live
in x19 across the loop) was clobbered by the worker's loop counter
(≈0x872): the shell's next `console.write` through `&mon.console` = 0x872
faulted with a synchronous external abort (`esr=0x96000021`, `far=0x872`,
DFSC=0x21). Without the idle task the same corruption produced a VM-level
error (state=3) instead of a guest-visible abort.

The fix: the stubs now push **x19..x28 + x29 first** (six `stp` pairs
appended at the frame top, slots [20..31]), and the inline 14-instruction
restore shrank to a 3-instruction setup + `b exc_restore_tail`, a shared
out-of-line tail that pops the full 32-slot frame and `eret`s. Stub bodies
stay 28 instructions (112 bytes) inside their 128-byte architectural
slots. The scheduler's per-task context (frame pointer + ELR/SPSR) is
unchanged — the frame now carries the complete register file, so a
resumed task gets its OWN x19..x28. The syscall ABI (frame slots [0..19])
is untouched.

**Per-task report slots (a starvation fix found by the live gate):**
`request_report`/`maybe_report` previously used ONE shared pending flag, so
the worker's every-64-iterations requests left it permanently pending and
starved the spawn-demo task's every-16-iterations reports. Reports are now
per-task (`report_pending[max_tasks]` + `report_advances[max_tasks]`), so
each task's progress prints independently.

**The addrspaces gate reconciled with the reaper:** claim 5804's gate
forwarded its script after the user's exit line and asserted the
`task user-el0 ttbr0=` row — possible because claim 5804's exited tasks
stayed zombies forever. Claim 6729's idle task reaps promptly, so the row
is legitimately gone by then. The `addrspaces` command now also prints
`user root=` directly from `mmu.user_root_phys()` (a fixed MMU fact, not a
task-table fact), and the gate's ownership assertion compares that root
against the kernel root.

**Design decisions (all verified against the codebase):**

1. **Explicit `State` enum replaces `registered`/`runnable`/`terminated`
   booleans.** `state_name` drives the `tasks` command's `state=` column.
   `scheduling_active` counts ready+running tasks; `next_runnable` scans
   `.ready` only, so zombies drop out of the ring naturally.
2. **Idle task = ring fallback + reaper.** Registered at the last slot by
   `init`, always ready, WFE-parked… no — a **bounded nop delay** (the
   shell's claim-6684 idle wait documents that a main-context WFE can stall
   the polled-RX loop on VZ). It reaps one zombie per iteration and
   snapshots the reap report (the freed slot's own name is zeroed by the
   reset, so `maybe_report` prints a snapshot).
3. **`spawn_demo` is explicitly bounded** (one demo spawn per boot — the
   pool has exactly one spare slot while the EL0 task is alive) on a
   dedicated stack.
4. **Exit report + reap report** print from the shell loop via
   `maybe_report` (main-context console discipline, claim 9187) — the
   exit/reap reports are separate from the per-task advance reports.

## Verification

- **Class A:** `zig fmt --check`, unit tests (165+ across all modules —
  scheduler now 44/44 including the new lifecycle tests), byte-identical
  transcript gate, build + image, coordination indexes — all green.
- **Class B on VZ (all 1/1):** the new `bash tools/verify-live-lifecycle.sh`
  (spawn id, demo advances, explicit states + pool header, exit to zombie,
  idle reap, shell echo, runner rc=0) plus regressions: addrspaces (with
  the new `user root=` assertion), uaccess, svc, userspace, tasks, timer,
  exceptions, transcript, fs, reboot.
- **Root-cause evidence:** `artifacts/live-addrspaces-serial-*.log` (the
  `[EXC] far=0x872` callee-saved corruption, then the fixed runs),
  `artifacts/live-lifecycle-*` (the gate's per-boot detail + serial logs).

**Observed vs inferred:** the callee-saved corruption (register values,
fault address, VM-error behavior) is directly observed on VZ; the worker's
loop counter as the source of 0x872 is inferred from the register dump and
disassembly.
