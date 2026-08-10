# ADR 0007: EL0 syscall ABI and runtime dispatch table

Status: **accepted** · Date: 2026-08-10 · Milestone: three (claim 3594)

## Context

Claim 8215 / PR #60 proved the smallest real EL0 boundary: a statically
linked EL0t task executes from a page-isolated user-text aperture, uses a
separate EL0 stack, enters EL1 with `svc #0`, and returns through the shared
exception-vector frame while the tick scheduler preserves `SP_EL0`. That card
deliberately exposed only one proof operation.

This card freezes the numbered contract before uaccess, per-task address
spaces, task lifecycle expansion, or executable loading build on accidental
register choices. The merged and VZ-proven claim-8215 convention is x8 as the
operation selector and x0 as argument/result. Docs-only commit `6b1b8cd`
later described both number and result as x0; that transcription cannot encode
`ping(value) -> value` and contradicts `userspace.zig`, claim 8215, its branch
log, and its live evidence. This ADR records the implemented boundary.

The kernel is a relocation-free flat image linked at zero and loaded at a
runtime-selected base. ADR 0005 therefore forbids const data tables containing
function or slice pointers: their link-time absolute addresses are wrong after
the load.

## Decisions

### D1. Register and exception convention

- x8 contains the syscall number.
- x0–x5 contain up to six arguments; x0 receives the return value.
- The instruction is `svc #0`. ESR_EL1's SVC immediate remains zero and is
  reserved; it does not carry a syscall number.
- The result is written to x0 in the saved claim-9746 vector frame before
  exception return restores the registers.
- SVC dispatch is EL0-only. `is_svc64_from_el0` accepts AArch64 SVC from EL0t;
  an SVC from EL1t or EL1h stays on the exception report-and-park path because
  kernel code calls functions directly.
- Claim 8215 continues to own vector entry, EL0 routing, `SP_EL0`, and return
  plumbing. The syscall module registers through its existing
  `set_svc_dispatcher` seam.

### D2. Fixed number space and table

The namespace is 0–63. The dispatch table has exactly 64 slots and is built at
runtime in module-level BSS. It is never a const function-pointer table.

| # | Name | Signature | Behavior |
|---|------|-----------|----------|
| 0 | `sys_ping` | `ping(value) -> value` | Preserves claim 8215's two-call EL0 return proof. |
| 1 | `sys_write` | `write(fd, buf, len) -> i64` | Writes at most 256 bytes to console fd 1 through the registered writer. |
| 2 | `sys_yield` | `yield() -> i64` | Cooperatively stages the next runnable task and returns 0 when the caller runs again. |
| 3 | `sys_exit` | `exit(status) -> noreturn` | Removes the caller from the runnable ring, stages its successor, and defers a shell report. |
| 4–63 | reserved | — | Returns `-ENOSYS`; later additions occupy one frozen row without renumbering. |

Every in-range slot has a monotonic call counter. `syscalls` reports the four
implemented rows and counters deterministically.

### D3. Return errors

Negative signed values are returned as their two's-complement x0 bit pattern:

| Value | Name | Meaning |
|-------|------|---------|
| 0 | success | The operation succeeded. |
| -1 | `EINVAL` | Argument arithmetic or the bounded write cap is invalid. |
| -2 | `EBADF` | The write fd is not 1. |
| -3 | `EFAULT` | Reserved for the follow-on uaccess card; not returned yet. |
| -4 | `ENOSYS` | The syscall number is unknown or reserved. |

`sys_write` currently checks the fd, 256-byte cap, addition overflow, the MMU
builder's guaranteed low 4 GiB identity blanket, and containment within one of
the two kernel-known EL0 apertures (user text or user stack) before
dereferencing. Privileged RAM and Device mappings inside the blanket are
therefore not readable through this syscall. This is bounded arithmetic over
already-known identity mappings, not fault-safe user-pointer access. The later
uaccess card owns mapping/permission checks, fault recovery, and EFAULT.

### D4. Scheduling effects stay within the fixed task model

Yield and exit reuse the claim-5275 fixed scheduler pool. Yield saves the SVC
frame and stages the next runnable task. Exit marks the EL0 caller terminated,
removes it from round-robin selection, stages another existing task, and never
returns to the terminated frame. The exception seam returns the scheduler's
selected frame just as its IRQ path already does. No dynamic task creation,
process object, allocation, or expanded loader is introduced.

The demo EL0 payload waits on a one-word witness in its existing user-BSS
aperture before calling `sys_yield`. Only the timer-switch wrapper updates that
witness; cooperative switches cannot. This preserves claim 8215's prerequisite
observation—a real timer IRQ preempts EL0 and returns to the shell—before the
new cooperative path runs.

SVC handlers execute in synchronous exception context, not IRQ context, so the
write writer may emit a short bounded line. Timer/scheduler IRQ paths remain
console-free; exit reporting is deferred to the shell idle loop.

## What this is not

- It is not POSIX, libc, `errno`, or a compatibility ABI.
- It is not uaccess, PAN, fault recovery, or safe arbitrary user-pointer
  access.
- It is not per-task address spaces, processes, dynamic task creation, or a
  user lifecycle subsystem.
- It is not an ELF loader or ESP executable path.
- It does not change the kernel takeover path, MMU ownership, or hardware
  contract.

Those later milestone-three cards build on this frozen numbering and register
contract rather than widening this card.

## Consequences

- Adding a syscall is one runtime table row, one bounded handler, and tests;
  existing numbers and errors do not move.
- The claim-8215 ping transcript remains a regression proof while the new live
  SVC gate proves dispatch-table write/yield/exit behavior and shell recovery.
- Host tests cover table shape, marshalling, errors, counters, writer output,
  scheduling hooks, and deterministic reporting; VZ evidence remains required
  for the real EL0 exception round trip.
