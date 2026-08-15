# Claim: `CALC.BIN` (Interactive Graphical Calculator)

- **Owner:** buffy (`agent/buffy/m11-a2-calc`)
- **Prompt / plan:** `docs/march-m11.md` card A2
- **Scope:** `user/src/calc.zig`, `build.zig`, `image/make-image.sh`, `docs/claims/8401-a2-calc-calculator.md`, `docs/logs/agent-buffy-m11-a2-calc.md`
- **Depends on:** `docs/claims/8155-a1-micro-widget-toolkit.md`
- **Status:** ✅ done

## Notes

Implements **Card A2 (`CALC.BIN` - Interactive Graphical Calculator)**:
1. `user/src/calc.zig`: Standalone EL0 GUI calculator using `ui.zig` micro-widgets.
   - 64-bit integer calculation engine with divide-by-zero protection.
   - Clickable button grid (`0–9`, `+`, `-`, `*`, `/`, `=`, `C`, `+/-`).
   - Direct keyboard input mapping for numeric typing and operator selection.
   - Formatted right-aligned LCD-style display screen.
2. Build pipeline integration: Flat binary extraction and embedding onto FAT32 ESP via `build.zig` and `image/make-image.sh`.
3. Class A math and state machine unit tests.
