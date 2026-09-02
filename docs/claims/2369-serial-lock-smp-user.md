# Claim: locked console TX — the first USER task runs on a secondary core

- **Owner:** buffy (`agent/buffy/serial-lock-smp-user`)
- **Prompt / plan:** add a lock around console/virtio-TX output so a user task (not just the kernel worker) can run on a secondary core, then prove it with a live gate
- **Scope:** serial TX lock + task pinning + secondary-core park; NOT task migration or cross-core wakeups (still core-0-owned timekeeping)
- **Touches:** kernel/src/main.zig, kernel/src/scheduler.zig, kernel/src/monitor.zig, kernel/src/exec.zig, user/src/smp1.zig, build.zig, tools/verify-live-smp1.sh, docs/claims/2369-serial-lock-smp-user.md, docs/logs/agent-buffy-serial-lock-smp-user.md
- **Depends on:** claims 7339 (per-core resume), 8513 (per-core counters), 8477 (per-core scheduler state), 9408 (tick gate lifted) — all merged
- **Heartbeat:** 2026-09-02
- **Status:** ✅ done

## Notes

**Change.** Three pieces make a USER program runnable on core 1:

1. **Serial TX lock (main.zig).** `uart_puts`/`uart_putc` now run under a
   holder-tracked `IrqSaveSpinlock` — IRQs are MASKED for the whole write.
   The mask is essential: SVC-context prints run with IRQs unmasked, so a
   timer tick could preempt a print mid-line and the resumed shell (SAME
   core, "holder") would write inside the critical section — the claim-9408
   holder pattern is a reentrancy check, not a preemption guard. The gate
   caught this live on the first run: `heap-oworker advances=18816` — the
   worker's report merged into MAIN.ELF's `heap-ok` line in verify-live-zc
   (one boot, pre-fix). With IRQs masked, a print is atomic on its core;
   the spinlock serializes across cores; holder tracking keeps fault-dump
   and putc-inside-puts reentrancy working.

2. **Task pinning (scheduler.zig, monitor.zig, exec.zig).** `Task.pin_core`
   (0 = any) + `pin_task(id, core)`; `next_runnable_for` skips a pinned
   candidate on every other core, so a pinned task is visible ONLY to its
   core. The monitor's `exec -c<core> <file>` parses the flag and threads
   it through `exec_file_pinned` → `register_exec_user` → `pin_task` (both
   the static DSK1/DSK3/ELF path and the dynamic-ELF path).

3. **Secondary-core park (scheduler.zig).** A core-1 task that must give
   up the CPU (sleep/wait/wait_event/exit) has no eligible successor — the
   old code rolled the SVC back (returned false; the task never blocked).
   `tick` now captures the WFE loop's frame (`park_sp/elr/spsr[c]`) the
   moment it starts a task from the parked state — a running task uses its
   OWN kstack, so the WFE bytes on the secondary stack survive intact —
   and `stage_secondary_park(c)` erets back to them: the task stays
   blocked/zombie for core 0's tick/reaper, and a later tick picks it up
   again (pin_core routes it back). Shared by exit/sleep/wait/wait_event.

**Evidence.** New gate `verify-live-smp1.sh`: `exec -c1 SMP1.BIN` → the
payload prints a marker, sleeps 2 ticks (core 1 parks on WFE, core 0 wakes
it), prints again, exits 0, is reaped. Assertions: byte-exact markers
(anti-interleaving proof), exit/reap lines, `smp: secondary runs=N
task=SMP1.BIN` (the claim-9408 evidence line now prints EVERY secondary
run with its name — a per-run ring, so a worker run between two user runs
can't mask the user name; observed runs 2 and 4 = SMP1.BIN, 1/3/5 =
worker), echo alive, no fatal. **3/3 PASS.** Regressions: verify-live-zc
**4/4** (caught + fixed the interleave), verify-live-concurrent **2/2**,
verify-cvc-echo **1/1**, verify-live-vf **4/4**, full unit suite PASS,
BSS PASS (507 368 B headroom), fmt/coordination clean.

**Boundary.** Only pinned tasks run on secondary cores; unpinned user
tasks stay on core 0 (their other syscalls touch unlocked core-0 state —
file/window/network). The worker's `secondary_ok` path is unchanged.
Task migration and cross-core wakeups remain out of scope.