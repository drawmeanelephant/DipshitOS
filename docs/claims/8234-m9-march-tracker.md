# Claim: Milestone nine march — interactive EL0 application events (living tracker)

- **Owner:** buffy (`agent/buffy/m9-tracker`)
- **Prompt / plan:** `docs/roadmap.md` milestone nine
- **Scope:** `docs/march-m9.md`, `docs/claims/8234-m9-march-tracker.md`, `docs/logs/agent-buffy-m9-tracker.md`
- **Depends on:** `docs/claims/2649-u8-persistent-settings.md`
- **Status:** ✅ done

## Notes

Defines the living tracker and collision-free agent split for **Milestone Nine (Interactive EL0 Application Events)**:
1. **Cards E0–E6**: ADR 0009 event contract, kernel per-process event ring (`kernel/src/events.zig`), keyboard routing, pointer/click routing with local window coordinate translation, window lifecycle events (focus/blur/close), non-blocking poll & blocking wait syscalls (`sys_poll_event`, `sys_wait_event`), and first interactive EL0 user application (`KEYTEST.BIN` / `DRAW.BIN`).
2. **Authoritative Spec**: Connects input subsystems (USB xHCI HID keyboard and pointer) to userspace applications through Driving Award window focus routing.
