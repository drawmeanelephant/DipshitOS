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
- **Status:** 🔄 in progress

## Notes

This is the smallest milestone-three card that proves execution at EL0 rather
than merely preparing structures for it. The intended evidence is a live VZ
transcript showing an EL0 task enter through `eret`, invoke a kernel service
through a real synchronous `svc` exception, continue across timer preemption,
and leave the existing EL1 shell responsive. The ABI will expose only the
minimum operation needed for a deterministic proof; broader processes,
syscalls, loading, and virtual-address isolation remain later work.
