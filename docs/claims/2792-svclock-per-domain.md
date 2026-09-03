# Claim: replace the coarse userspace-service gate with per-service-domain locks

- **Owner:** buffy (`agent/buffy/serial-lock-smp-user`)
- **Prompt / plan:** Replace the coarse userspace-service gate (claim 9498) with per-subsystem locks (file/window/network/events) so syscalls on different cores only contend when they touch the same subsystem.
- **Scope:** the claim-9498 follow-on — one `SvcLock` per service domain + canonical acquisition order; per-core uaccess/CSPRNG state the concurrency exposes.
- **Touches:** kernel/src/svclock.zig, kernel/src/usergate.zig, kernel/src/syscall.zig, kernel/src/monitor.zig, kernel/src/scheduler.zig, kernel/src/exceptions.zig, kernel/src/input.zig, kernel/src/shell.zig, kernel/src/uaccess.zig, kernel/src/csprng.zig, kernel/src/process.zig, tools/verify-unit-tests.sh
- **Depends on:** claim 9498 (4f7eba0)
- **Heartbeat:** 2026-09-03
- **Status:** ✅ done

## Notes

The claim-9498 gate restored a single-core semantic over ALL shared
user-visible service state, so syscalls in unrelated domains serialized
against each other (the in-guest compiler's file I/O starved window/net/
event syscalls). This claim replaces it with five IRQ-masking,
holder-tracked locks — one per service domain, in the canonical order
`file < net < win < ev < kernel` — so a domain syscall takes exactly its
own domain's lock and contends only with same-domain work. The exit/fault
teardown takes all five; exec takes file+kernel; the IRQ tick's protected
work try-takes ev+kernel only, and rotation stays ungated under
`sched_lock` (the claim-9498 ring-progress fix is preserved). The
concurrency exposed two shared write sets that got per-core treatment
(uaccess regions/window/latch, the CSPRNG keystream) and a publish-order
fix in process.bind.

A root-cause find: the multi-lock helper's domain iteration must be
unrolled per lock — a runtime switch over the domain enum makes Zig emit
a `.rodata` pointer table of the lock globals' IMAGE-RELATIVE vaddrs,
which fault under kernel ASLR (observed ldaxr data abort at boot).

Verified: full unit suite (svclock added to the runner), build, BSS, and
live gates on the working-tree kernel — smp1, concurrent, zc 4/4, vf 4/4,
cvc-echo, sb4 damage tracking.
