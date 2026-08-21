# Claim: uaccess — fault-safe copy-in/copy-out

- **Owner:** Buffy (`agent/buffy/m3-uaccess`)
- **Prompt / plan:** milestone-three march card 3 ([`docs/march-m3.md`](../march-m3.md)),
  following the syscall ABI card (claim 3594 / PR #64). Card text: add
  bounded user-memory transfer primitives and enforce the reserved `EFAULT`
  (`-3`) contract without letting a bad pointer crash EL1.
- **Scope:** milestone-three uaccess: bounded `copy_in`/`copy_out` primitives
  over the kernel-known EL0 apertures (user text read-only, user stack
  read/write), the EFAULT contract (out-of-region, overflow, unmapped, and
  permission cases), a fault-recovery window that converts a real EL1 data
  abort during a copy into EFAULT instead of a crash, migration of
  `sys_write` onto uaccess, a `uaccess` monitor diagnostic (live recovery
  proof), an EL0-payload EFAULT exercise, ADR 0007 amendment, a new class-B
  live gate, and the updated `live-svc` counters. No per-task address
  spaces, PAN, process abstraction, ELF loading, or allocation.
- **Depends on:** PR #64 / claim 3594 (frozen syscall ABI, merged as
  `f4b3143` on `main`), claims 8215/9746 (EL0/SVC boundary + exception
  vectors), 5275/9187 (scheduler + real timer IRQs).
- **Status:** ✅ done

## Notes

The current `sys_write` validates pointers with plain bounded arithmetic
over the two claim-8215 apertures and returns `EINVAL` for bad pointers;
ADR 0007 reserves `-3`/`EFAULT` for this card. This claim delivers the
uaccess layer:

1. **Bounded transfer primitives** — `uaccess.copy_in` (user → kernel) and
   `uaccess.copy_out` (kernel → user), bounded by the caller's buffer and
   validated against the configured EL0 regions before any memory access.
2. **Fault-safe recovery** — the copy runs inside a masked "uaccess window";
   a synchronous data abort (EC 0x24/0x25) taken while the window is active
   is a bad user pointer, not a kernel bug: the handler latches the fault,
   advances ELR past the 4-byte faulting instruction, and resumes; the copy
   observes the latch and returns `EFAULT`. IRQs are masked for the window
   (already masked inside SVC handlers; explicitly masked in the monitor
   diagnostic) so no unrelated task can fault inside the window.
3. **EFAULT enforcement** — `sys_write` migrates onto `copy_in`; overflow,
   out-of-region, unmapped, and permission cases return `-3` (`EINVAL`
   stays for the write cap, `EBADF` for a bad fd).
4. **Live evidence** — the EL0 payload passes an unmapped bad pointer to
   `sys_write`, observes `-3` in x0, and writes a marker proving EL0
   survived; the new `uaccess` monitor command runs a *validated* copy (ok)
   and a *raw* copy from an unmapped address above the 4 GiB identity
   blanket (real data abort recovered) and reports `valid=1 fault=1
   recovered=1`.

Verification: class A first (unit tests for valid/boundary/overflow/
unmapped/permission/recovery, updated syscall tests, regenerated mock
transcript for the new `uaccess` command, full portable set), then the new
class-B gate `tools/verify-live-uaccess.sh` plus the updated
`verify-live-svc.sh` (write counter 1 → 3 for the payload's three writes)
and the required live regressions, with saved evidence under `artifacts/`.

**Result (2026-08-10):** done. Class A fully green (fmt, 164+ unit tests
with `uaccess` added to `verify-unit-tests.sh`, byte-identical mock
fixture with the new `uaccess` help line, build/image/inspect/swift/
context, coordination, test-coordination, mmu-debt). Class B: the new
`verify-live-uaccess.sh` passes 1/1 — EL0 observed `-3`/EFAULT for an
unmapped bad pointer and survived (`uaccess: efault ok n=8`), and the
`uaccess` monitor command recovered a **real EL1 data abort**
(`uaccess: valid=1 fault=1 recovered=1 copies=4 validation_faults=1`, no
`[EXC] parking`, post-command `rx-uaccess-ok` reply). `verify-live-svc`
passes 1/1 with the payload's three writes (`write=3`); regressions all
green: live-exceptions, live-userspace, live-timer, live-tasks,
live-transcript, and the serial-takeover `zig build run`. Evidence under
`artifacts/m3-uaccess-live.txt`, `artifacts/live-uaccess-*`,
`artifacts/live-svc-*`. One notable root cause on the way: the first live
run parked instead of recovering because the optimizer (ReleaseSmall +
LTO) sank the `window_active = true` store below the faulting user-memory
load (the flag has no reader inside the loop); the window state is now
accessed through volatile pointers with an explicit compiler barrier, and
the recovery works (documented in `kernel/src/uaccess.zig`).
