# Claim: milestone nine, card E2 — keyboard event routing

- **Owner:** buffy (`agent/buffy/m9-events`)
- **Prompt / plan:** `docs/march-m9.md`
- **Scope:** Milestone 9 card E2: routing decoded keystrokes and modifier chords from USB xHCI / input FIFO into the focused user window process's event queue as KEY_DOWN / KEY_UP events, while terminal shell retains focus routing when window 0 is focused.
- **Depends on:** E1 (claim 7670)
- **Status:** ✅ done (2026-08-15)

## Notes

Implements keyboard event routing to user processes:
- `driving_award.focused_owner()` helper to identify focused user window PID.
- Modifier bitmask conversion (`hid_modifiers_to_flags`).
- Key-DOWN and Key-UP event generation on rollover delta.
- Preserves Alt+Tab focus cycling and terminal shell routing when window 0 is focused.
- Class A unit tests covering keyboard event translation, modifier masks, and process event queue dispatch.

## Verified

- Class A unit tests in `kernel/src/input.zig` / `kernel/src/driving_award.zig`.
