# Claim: M16 C2 — guard pages + per-segment permissions, hostile EL0 reaped

- **Owner:** buffy (`agent/buffy/m16-c2-guards`)
- **Prompt / plan:** `docs/march-m16.md` (card C2, issue #191)
- **Scope:** Milestone sixteen card C2 (wishlist 14). Guard pages below the
  user stack and above the new data segment; per-segment permission
  enforcement beyond the W^X text page (the C1 data aperture is already
  writable-but-not-executable); and the hostile-EL0-refused live proof in the
  S4 pattern — a program stepping off its stack into a guard faults, is
  REAPED by the kernel (instead of parking the machine), and never corrupts a
  neighbor.
- **Depends on:** C1 (claim 3805 — the data segment gives the address space a
  real RW+NX region to guard).
- **Status:** ✅ done — `tools/verify-live-m16-guards.sh` PASS 1/1 on VZ (claim 8403)

## Notes

Today an EL0 synchronous fault outside the uaccess window (a data abort on an
unmapped/guard address, an instruction abort, or a permission fault) falls
through to `exc_dispatch`'s report-and-park path: the stub parks in WFE and
the whole machine hangs. C2 converts that into process termination: a sync
fault from EL0 (SPSR.M == 0, not an SVC, not a recoverable uaccess fault)
calls `scheduler.exit_current(reserved_fault_status)` through a registered
fault dispatcher, so the faulting process is reaped (status 139) and the ring
stages the next task — the shell survives.

Guard pages are the natural consequence of the user root mapping ONLY the
text/data/stack apertures: the page below the stack bottom and the page above
the data segment are unmapped, so a store stepping off either faults. C2 makes
those guards explicit (documented + reported) and proves them live with a
hostile program that faults and is reaped beside a benign neighbor.

Verification: fmt, unit tests, transcript, build/image/inspect, swift build,
coordination, and a new class-B gate `tools/verify-live-m16-guards.sh`.
