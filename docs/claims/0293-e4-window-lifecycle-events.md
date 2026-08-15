# Claim: milestone nine, card E4 — window lifecycle events

- **Owner:** buffy (`agent/buffy/m9-events`)
- **Prompt / plan:** `docs/march-m9.md`
- **Scope:** Milestone 9 card E4: synthetic WIN_FOCUS, WIN_BLUR, and WIN_CLOSE event generation and delivery to user process descriptors on focus transitions and window closures in `kernel/src/driving_award.zig`.
- **Depends on:** E1 (claim 7670)
- **Status:** ✅ done (2026-08-15)

## Notes

Implements window lifecycle event generation:
- `WIN_FOCUS`: delivered to owning process when user window gains focus (arg0 = window id, arg1 = previous focused id).
- `WIN_BLUR`: delivered to owning process when user window loses focus (arg0 = window id, arg1 = new focused id).
- `WIN_CLOSE`: delivered to owning process when window is closed (arg0 = window id).
- Class A unit tests covering focus transition sequence and close notification.

## Verified

- Class A unit tests in `kernel/src/driving_award.zig`.
