# agent/buffy/m27-desktop-polish branch log

## 2026-08-26 — M27 (Milestone 15) Desktop polish & completeness sweep (G1–G30, issues #444–#473)

- Claimed full M27 sweep (claim 8041) on branch `agent/buffy/m27-desktop-polish`.
- Plan: implement and verify all 30 cards across 5 structured phases (Tooling, UI Library, Compositor, Apps & Lifecycle, Audits & Dogfood).
- **Phase 1 (G27, G28, G29):**
  - Added `write_fb_bmp` in `kernel/src/fat.zig` for 24-bpp BMP zero-heap streaming to disk.
  - Implemented `screenshot [<file>]` in `kernel/src/monitor.zig`.
  - Added `help --all` full 68-command catalog dump and `shortcuts` hotkey reference command.
  - Updated `tests/transcript-console.txt` and `kernel/src/shell.zig`.
- **Phase 2 (G9, G10, G14, G22, G23):**
  - Added `WidgetState` (.normal, .hover, .pressed, .disabled, .focused) & styling helpers in `user/src/lib/ui.zig`.
  - Upgraded `ContextMenu` to support `MenuItemSpec`, separators, right-aligned shortcuts, and Up/Down/Enter/Escape navigation.
  - Implemented `show_dialog` modal helper, `draw_empty_state`, and `format_error` errno mapper.
- **Phase 3 (G1, G3, G4, G5, G7, G12, G13):**
  - Verified splash, about dialog with `previous_focus` window restoration, nearest-neighbor Alt-Tab previews in `driving_award.zig`.
  - Added sound feedback on notification toasts (440 Hz / 880 Hz).
  - Added distinct cursor styling for resize and move drags, and `focus_follows_mouse` handling.
- **Phase 4 (G2, G6, G15, G16, G17, G18, G19, G20, G21):**
  - Implemented `SYSMON.BIN` (`user/src/sysmon.zig`) System Monitor Dashboard with 1 Hz auto-refresh and tabs.
  - Implemented 3-step First-Boot Setup Wizard and Defaults Reset in `SETTINGS.BIN` (`user/src/settings_panel.zig`).
  - Verified `settings reset` in monitor shell and settings file persistence.
- **Phase 5 (G8, G11, G24, G25, G26, G30):**
  - Conducted contrast audit, memory leak audit, boundary sanity checks, and timer cancellation verification.
  - Documented complete M27 dogfood and verification records in `docs/dogfood-m27.md`.
  - Ran `zig build test-console`, `tools/verify-unit-tests.sh`, `tools/verify-bss-budget.sh`, and `tools/verify-coordination.sh` — all 100% green.
