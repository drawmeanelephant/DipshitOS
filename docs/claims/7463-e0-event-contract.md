# Claim: milestone nine, card E0 — event contract & ADR 0009

- **Owner:** buffy (`agent/buffy/m9-events`)
- **Prompt / plan:** `docs/march-m9.md`
- **Scope:** Milestone 9 card E0: normative 16-byte event wire format, event kind constants, modifier bitmasks, and ADR 0007 syscall slots (sys_poll_event = slot 21, sys_wait_event = slot 22). Docs only — no code.
- **Depends on:** M8
- **Status:** ✅ done (2026-08-15)

## Notes

Milestone nine turns DipshitOS from "a kernel with graphical demos" into an
interactive application platform. This card freezes the event wire layout,
event type enumeration, flag bitmasks, and syscall numbers before kernel
and userspace implementations land.

**ADR 0009** defines:
- D1. 16-byte packed event wire format (`kind`, `flags`, `seq`, `arg0`, `arg1`).
- D2. Event kinds (`KEY_DOWN`, `KEY_UP`, `MOUSE_DOWN`, `MOUSE_UP`, `MOUSE_MOVE`, `WIN_FOCUS`, `WIN_BLUR`, `WIN_CLOSE`).
- D3. Modifier & button bitmasks (`MOD_SHIFT`, `MOD_CTRL`, `MOD_ALT`, `MOD_CMD`, `BTN_LEFT`, `BTN_RIGHT`, `BTN_MIDDLE`).
- D4. Syscall ABI amendments for `sys_poll_event` (slot 21) and `sys_wait_event` (slot 22).

## Verified

- Gate: ADR 0009 accepted in `docs/decisions/0009-application-events.md`.
