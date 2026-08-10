# Claim: EL0 task and SVC boundary

- **Owner:** Codex (`codex/el0-svc-task`)
- **Prompt / plan:** implement the next milestone-three task card without
  overlapping the concurrent PRs #55/#56 documentation reconciliation.
- **Scope:** one real EL0 task scheduled alongside the existing EL1 shell,
  exception-return entry at EL0t, an intentionally tiny SVC ABI, focused host
  tests, and a strict live VZ gate. No process abstraction, address-space
  isolation, userspace loader, libc/POSIX, filesystem changes, or edits to
  `docs/status.md`, `docs/hardware-contract.md`, or `docs/roadmap.md`.
- **Depends on:** claim 5275 (tick-driven kernel-task scheduler), claim 9746
  (EL1 exception vectors), claim 9187 (real periodic timer PPI delivery).
- **Status:** ✅ done

## Notes

This is the smallest milestone-three card that proves execution at EL0 rather
than merely preparing structures for it. The intended evidence is a live VZ
transcript showing an EL0 task enter through `eret`, invoke a kernel service
through a real synchronous `svc` exception, continue across timer preemption,
and leave the existing EL1 shell responsive. The ABI will expose only the
minimum operation needed for a deterministic proof; broader processes,
syscalls, loading, and virtual-address isolation remain later work.

Completed with two deliberately narrow EL0 apertures in the shared identity
map: a page-isolated `.usertext` range mapped EL0 read-only/executable and
PXN, and a page-isolated `.userbss` stack mapped EL0 read/write and XN. All
neighboring kernel Normal RAM and every Device mapping remain EL1-only. This
is not process or address-space isolation: the task is statically linked and
continues to share TTBR0 with the kernel.

The scheduler now round-robins the EL1h shell, EL1h worker, and EL0t payload
while preserving each task's SP_EL0. The exception-return ABI carries both the
selected register frame and SP_EL0; the lower-EL synchronous seam accepts only
AArch64 SVC from EL0t. The tiny ABI uses x8 as the operation selector and x0
as argument/result. While making that boundary honest, this card also fixed
the architectural SPSR mode decode (observed M=0x5 is EL1h) and the saved
vector-frame x0/x30 offsets.

Directly observed on Apple silicon VZ: the strict userspace gate passed 3/3
boots with the exact evidence line
`userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0`; the second
sequenced SVC proves return to EL0 after the first, and the deferred shell-side
line proves timer preemption returned to a responsive EL1h context. Focused
live regressions for tasks, timer IRQ delivery, and exception reporting each
passed 1/1. The full portable gate set, all host module tests, the
byte-identical transcript gate, the freestanding build/image/inspection, and
coordination/MMU-debt gates also pass. Evidence is saved under
`artifacts/live-userspace-*`, `artifacts/live-tasks-*`,
`artifacts/live-timer-*`, `artifacts/live-exceptions-*`,
`artifacts/el0-sections-8215.txt`, and
`artifacts/verify-portable-8215.txt`.
