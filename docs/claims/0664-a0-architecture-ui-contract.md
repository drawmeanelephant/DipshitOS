# Claim: Architecture & UI contract (ADR 0011)

- **Owner:** buffy (`agent/buffy/m11-a0-adr`)
- **Prompt / plan:** `docs/march-m11.md` card A0
- **Scope:** `docs/decisions/0011-desktop-platform-and-gui-apps.md`, `docs/claims/0664-a0-architecture-ui-contract.md`, `docs/logs/agent-buffy-m11-a0-adr.md`
- **Depends on:** `docs/claims/0861-m11-march-tracker.md`
- **Status:** ✅ done

## Notes

Delivers **ADR 0011 (Desktop Platform & Userland GUI Application Architecture)**:
1. **D1 Window Coordinates**: Window-local coordinates (`0..w-1`, `0..h-1`), origin top-left, scanout translation via ADR 0009.
2. **D2 Event Loop Dispatch**: Event draining, dirty-flag batching, frame presentation discipline.
3. **D3 Zero-Allocation Micro-Widgets**: Component state models for `Button`, `Label`, `TextInput`, and `ListView`.
4. **D4 Typography & Palette**: 8×8 bitmap text rasterizer and standard HIG dark-theme palette tokens.
5. **D5 Desktop Lifecycle**: Desktop launcher environment, status bar, and process monitoring.
