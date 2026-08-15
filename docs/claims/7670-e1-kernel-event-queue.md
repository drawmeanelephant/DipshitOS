# Claim: milestone nine, card E1 — kernel per-process event queue

- **Owner:** buffy (`agent/buffy/m9-events`)
- **Prompt / plan:** `docs/march-m9.md`
- **Scope:** Milestone 9 card E1: `kernel/src/events.zig` implementing bounded in-memory event FIFO (16 events per process slot, pure BSS, no heap allocation), push/pop/peek mechanics, drop-oldest overflow tracking, sequence numbering, process lifecycle reset, and class A unit tests.
- **Depends on:** E0 (claim 7463)
- **Status:** ✅ done (2026-08-15)

## Notes

Implements the kernel storage layer for Milestone 9 application events:
- 16-byte `Event` wire struct matching ADR 0009.
- 16 events per process slot (`events_per_process = 16`), fixed BSS memory.
- Monotonic per-process sequence numbers (`seq`).
- Drop-oldest overflow handling with monotonic drop counter.
- Process lifecycle reset hooks (`init`, `reset`).
- Class A unit tests covering FIFO wrap, bounds, drop counting, and process isolation.

## Verified

- Class A unit tests in `kernel/src/events.zig`.
