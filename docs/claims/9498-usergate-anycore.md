# Claim: userspace-service gate — unpinned user tasks run on any core

- **Owner:** buffy (`agent/buffy/serial-lock-smp-user`)
- **Prompt / plan:** add locks (or per-core state) for the file/window/network syscall paths so unpinned user tasks can run on any core without the exec -c flag
- **Scope:** a coarse holder-tracked IRQ-masking gate over every userspace-service entry (syscall dispatch, monitor commands, exit/fault teardown, demand-paging faults); unpinned user tasks default to any core; the IRQ tick's rotation decoupled from the gate so contention never stalls the ring/reaper
- **Touches:** kernel/src/usergate.zig, kernel/src/scheduler.zig, kernel/src/syscall.zig, kernel/src/monitor.zig, kernel/src/exceptions.zig, kernel/src/alloc.zig, kernel/src/spinlock.zig
- **Depends on:** claims 7339/8513/8477/9408/2369 (per-core counters, per-core scheduler state, lifted tick gate, serial TX lock, `exec -c` pinning)
- **Heartbeat:** 2026-09-02
- **Status:** ✅ done

## Notes

Why a coarse gate: the file/window/network/mailbox/events/timer/registry subsystems were all written single-core and share module globals; per-subsystem locks need an audit of every cross-module call chain. One gate restores the single-core semantic ("the kernel is single-threaded through any userspace-service entry") on the multi-vCPU VM. It is IRQ-masking (a holder always runs to completion, so any context may spin) and holder-tracked (same-core reentrancy: the exit teardown inside a syscall proceeds under the outer hold). User tasks now spawn `secondary_ok` by default; `pin_task`/`exec -c` becomes a RESTRICTION over the default.

The live flake this claim's fix closes: the IRQ tick originally try-acquired the gate for its whole beat and skipped when contended — but a syscall on another core holds the gate for its WHOLE duration, so a syscall-storming core-1 task (the in-guest compiler ZC.BIN's file I/O) starved core-0's ticks; the ring never rotated to the idle reaper, and zombies from core-1 exits piled up (verify-live-zc 3/4: `reaped=0`, exit + proc reports printed, reap never). Fix: the tick takes `sched_lock` first and rotates the ring ungated (the preemption switch touches only per-core staging and ready<->running flips — the claim-2369 proven shape); only `on_tick`'s registry work and the kill conversions are gate-gated (skip when contended). `stage_selected`'s kill conversion became gate-aware (try, never spin under sched_lock; on contention the task runs one more quantum with `kill_pending` intact).

Verification: unit suite + build + BSS PASS; live gates under plain exec — verify-live-zc 4/4 twice (reaps now land 2 lines after every exit, core-0 and core-1), verify-live-smp1 3/3 (deterministic core-1 lifecycle), verify-live-concurrent 2/2, verify-cvc-echo 1/1, verify-live-vf 2/2.
