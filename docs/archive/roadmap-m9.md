# Roadmap archive — Milestone nine: interactive EL0 application event system

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).
>
> Also archived here: the **architectural bridge** note (claim 4951) that
> introduced the post-M8 candidate ladders (milestones nine–sixteen) in
> `docs/roadmap.md`.

---

## Candidate milestone ladders (post-milestone-eight)

> **Architectural bridge (claim 4951):** The transition from "capable kernel"
> to "weird little computer" requires four structured, sequential milestones
> that translate the maintainer's wishlist into gated card ladders. Each card
> is grounded in the project's invariants (freestanding Zig, no libc, no POSIX,
> bounded BSS/table resource allocations, and deterministic Class A/B gates).

---

### Milestone nine — interactive EL0 application event system

> Give EL0 applications eyes and ears: turn static window presentation into
> interactive, event-driven user programs.

- **E1 — Per-process kernel event queues.** Bounded pure-BSS event FIFO
  per process (e.g. 16 events: key down/up with modifiers, pointer motion
  relative to window bounds, mouse button down/up, focus gained/lost, and
  close-requested). Driving Award routes keyboard and pointer events to the
  *focused* window's process queue.
- **E2 — Event syscall ABI (ADR 0007 slots 21 & 22).**
  - `sys_event_poll(buf, max) -> count`: non-blocking drain of pending events
    through the uaccess window.
  - `sys_event_wait(buf, max, timeout_ticks) -> count`: parks the caller on the
    scheduler sleep/event seam until an event arrives or timeout expires.
- **E3 — Minimal EL0 application runtime (`user/src/lib/app.zig`).**
  Freestanding Zig event loop helper (`App.run(handlers)`), window setup,
  2D blit helpers, and basic glyph rendering. Zero heap allocation.
- **E4 — First interactive consumer app (`CLICKME.BIN` / `PAINT.BIN`).**
  **[Capstone Gate]** A userland application where clicking buttons changes colors,
  typing updates text inside the window, and clicking close requests a clean exit.
  Live gate: `verify-live-app-events.sh`.
