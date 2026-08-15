# Claim: milestone nine, card E3 — pointer & click event routing

- **Owner:** buffy (`agent/buffy/m9-events`)
- **Prompt / plan:** `docs/march-m9.md`
- **Scope:** Milestone 9 card E3: converting absolute pointer motion and button clicks within a user window to window-local coordinates (x - win.x, y - win.y) and queuing them as MOUSE_DOWN, MOUSE_UP, and MOUSE_MOVE events to the focused / hit-tested window's owning process.
- **Depends on:** E1 (claim 7670), U5
- **Status:** ✅ done (2026-08-15)

## Notes

Implements pointer and click event routing:
- Window-local coordinate translation and boundary clamping.
- `mouse_buttons_to_flags` helper mapping button bits to ADR 0009 masks.
- `MOUSE_MOVE`, `MOUSE_DOWN`, and `MOUSE_UP` event generation during `pointer_tick`.
- Class A unit tests covering coordinate translation, hit-testing dispatch, and button edge tracking.

## Verified

- Class A unit tests in `kernel/src/driving_award.zig`.
