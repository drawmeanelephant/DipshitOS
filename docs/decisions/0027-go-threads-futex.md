# ADR 0027: GOOS=virelai threads and futex (phase 0b kernel model)

- Status: PROPOSED (design card for phase 0b — no thread kernel code until reviewed)
- Date: 2026-09-12
- Issue: #1194 (round claim; successor of #1163 / ADR 0026)
- Related: ADR 0007 (syscall ABI), ADR 0026 (Go runtime port, D5 lists the
  five single-M deltas this ADR retires)

## Context

Phase 0a (ADR 0026) runs Go single-threaded behind five `proc.go` fork
deltas: sysmon off, template thread skipped, spare-M handoffs dropped,
`dolock/dounlockOSThread` bookkeeping-only, `stopm` yields instead of
parking. Bring-up proved these are not optional polish — `gcenable`
wedged the single M the moment the main goroutine parked on a channel
while bgsweep/bgscavenge sat in its P's runq. Usable Go (GOMAXPROCS > 1,
sysmon, timers, netpoll pacing) needs the runtime's M:N machinery on real
kernel threads.

The scheduler already has everything the mapping needs: per-process
address spaces (`process.AddrSpace`, one TTBR0 root), a bounded task pool
(`max_tasks = 11`, per-core ready rings, preemption via the timer PPI),
and the claim-0826 rule that every live EL0 task owns its own EL1
exception stack. What does not exist yet: two tasks sharing ONE process,
a thread-exit path, and any wait/wake primitive on user memory.

## Decision

D1 — **M ↔ task mapping: one process, many tasks, one TTBR0 root.**
A Go M maps 1:1 onto a kernel task bound to the SAME process descriptor
(`process.bind`). The address space (root, mmap regions, file table,
principal, mailbox/events) belongs to the process and is shared; the per
task state that is already per-task stays per-task (EL1 kstack, register
frame, uaccess TCB regions — armed per task at SVC entry, which is exactly
what Go's M-local state wants). `max_tasks = 11` bounds Ms per boot; a Go
program's Ms count against the global pool like every other task.

D2 — **Process lifecycle stays process-scoped (no POSIX).** Thread exit
(slot 73 op) tears down the task and frees its EL1 kstack; the process
dies when its LAST task exits (`exit_group` semantics — `sys_exit` stays
"exit the process", a new `sys_thread_exit` or an op flag exits the
thread only). No zombies, no join: the existing `sys_wait(pid)` keeps
waiting on process exit only; a Go program joins threads via channels,
which is the runtime's own model anyway. Reap/recycle keeps freeing
process-owned pages exactly once (the phase-0a I1 alias guard already
fixed the only double-free shape).

D3 — **slot 73 `sys_thread_create(entry, stack_hi, arg, tls) -> tid`.**
Arguments: `entry` (EL0 PC, must land in the process's executable
aperture — validated like `exec`'s entry check), `stack_hi` (the TOP of a
CALLER-PROVIDED EL0 stack; Go passes `mp.g0.stack.hi`), `arg` (x0 for the
child: the `m` pointer), `tls` (reserved 0 in phase 0b — pure-Go arm64
keeps g in R28, no TLS programming). The kernel: allocates a task, binds
it to the caller's process, arms the initial frame at `stack_hi` with
`x0 = arg, pc = entry` (the same frame machinery `register_exec_user`
uses), marks it running on the caller's core ring (no pin unless the
caller pins — SMP placement follows the unpinned exec rule, claim 9498).
Returns the new kernel tid (Go stores it in `m.procid`). Principal,
uid/caps inherit from the process (no new privilege surface; the slot is
NOT capability-gated — it can only create work inside the caller's own
address space).

D4 — **slot 74 `sys_futex(op, uaddr, val, timeout_ns)` — one bounded
wait/wake op on a user word.** Op 0 = wait (sleep the task while
`*uaddr == val`, kernel-verified under the mmu read of the user word —
no copy, a direct read of the 4-byte user word via the existing uaccess
window), op 1 = wake n (default 1). Backing: a bounded BSS wait-table
keyed `(pid, uaddr)` in the scheduler — the same shape as the pipe/event
seams (ADR 0009's queue machinery, no new subsystem). Timeout rides the
existing per-task timer (`sleep` seam): a timed wait returns `-ETIMEDOUT`
(a distinct negative from a real wake). Thread death while waiting: the
exit path removes the task from the wait table and (for wake-on-exit
correctness) performs one `wake(1)` on any futex the dying task was
waiting on — Go's `exitThread` contract expects the woken peer to
re-check the user word, which the wake enables. Contention scale is
bounded by `max_tasks`; the table is `max_tasks` entries, flat-scan (no
hash table at 11 slots).

D5 — **Go side: the five deltas die.** `patch_proc.py` is deleted:
`haveSysmon` restores to `GOARCH != "wasm"`, `canCreateM` goes away,
`newosproc` = slot 73 (`clone`-shaped: child runs `mstart` on
`mp.g0.stack.hi` with `mp` in x0), `dolock/dounlockOSThread` restore the
upstream bodies, `stopm` restores `mPark`. `lock_sema.go`'s
spinning-semaphore notes stay (the futex slot backs `semasleep/
semawakeup` instead of the yield-spin — a one-file swap, `lock_virelai.go`
keeping the futex file shape). Async preemption stays OFF
(`preemptMSupported = false` — signals are phase 0c; STW remains
cooperative, the known tight-loop caveat).

D6 — **Gate: `go-goroutines` (class B).** Fixture prints a
serial-ordered completion proof: N goroutines (N > GOMAXPROCS) increment
an atomic counter and send on a buffered channel; main drains N
completions and prints `go-goroutines done n=<N> counter=<K>` with
K == N. Serial asserts: the done line, plus the strace signature of
slot 73 (`sys_thread_create` called ≥ 2 times). **Proof scope, honestly
stated:** phase 0b keeps `numCPUStartup = 1`, so the extra Ms the gate
exercises are the slot-73-created ones (sysmon + the template thread) —
this proves real M creation via slot 73, goroutines scheduled across
Ms, and channel blocking/wake through futex; it does NOT prove parallel
worker Ms on separate cores. That proof needs GOMAXPROCS > 1 (the
envp/GOMAXPROCS half) — OR the gate implementation may set
`numCPUStartup = 2` for the gate boot, decided at implementation
review; the gate asserts whichever scope was chosen.

## Consequences

- Retires every `proc.go` delta — the fork's scheduler surface returns to
  stock; only GOOS files remain.
- Unblocks 0c (fault delivery) and phase 2 (netpoll needs wakeable Ms;
  sysmon needs a thread — both assume this ADR).
- The task pool (11) bounds GOMAXPROCS: a Go program's Ms + every other
  process's task share the pool; `GOMAXPROCS` env cannot be set (no env
  until argv/envp env half lands) so the runtime defaults to
  `numCPUStartup` — phase 0b sets it to 1 in `osinit` still, with sysmon
  + template thread as the only extra Ms (2-3 tasks per Go process);
  multi-P comes with the envp half or a `GOMAXPROCS` default bump in
  `osinit`, decided at implementation review.
- Slots 73/74 land as ADR 0007 amendments (append-only; 72 is taken by
  #1166's getrandom, implemented_count 73 → 75).
