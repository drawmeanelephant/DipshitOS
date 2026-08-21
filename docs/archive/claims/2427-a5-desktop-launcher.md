# Claim: `DESKTOP.BIN` (Desktop Launcher & Environment) & Capstone Gate

- **Owner:** buffy (`agent/buffy/m11-a5-desktop`)
- **Prompt / plan:** `docs/march-m11.md` card A5
- **Scope:** `user/src/desktop.zig`, `build.zig`, `image/make-image.sh`, `tools/verify-live-desktop.sh`, `artifacts/live-desktop-gate.txt`, `docs/claims/2427-a5-desktop-launcher.md`, `docs/logs/agent-buffy-m11-a5-desktop.md`
- **Depends on:** `docs/claims/8155-a1-micro-widget-toolkit.md`, `docs/claims/8401-a2-calc-calculator.md`, `docs/claims/3234-a3-notepad-editor.md`, `docs/claims/0680-a4-top-process-monitor.md`
- **Status:** ✅ done

## Notes

Implements **Card A5 (`DESKTOP.BIN` - Desktop Launcher & Environment)** and Milestone 11 Capstone Gate:
1. `user/src/desktop.zig`: Standalone EL0 GUI Desktop Environment and Application Launcher with status diagnostics, system clock/procs indicator, and quick launch / app selection menu.
2. Build pipeline integration: Flat binary extraction and embedding onto FAT32 ESP via `build.zig` and `image/make-image.sh`.
3. Capstone hardware verification gate: `tools/verify-live-desktop.sh` validating live boot, desktop environment launch, window creation, menu interaction, and application responsiveness on Apple silicon Virtualization.framework.
