# Log — agent/buffy/m27-desktop-polish

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
- **Review Fixes (PR #591):**
  - Formatted `user/src/settings_panel.zig` with `zig fmt` to unblock CI.
  - Fully wired `SYSMON.BIN` into `build.zig`, `image/make-image.sh`, `image/mkfat32.py`, and `image/apps.txt` (bumped manifest apps to 12 in `verify-live-desktop.sh` and `verify-live-file-browser.sh`).
  - Fixed Wizard widget layout in `SETTINGS.BIN` (added `update_widget_layout` and direct drawing) so click hit-boxes and dropdown open-state match 1:1.
  - Hardened `fat.write_fb_bmp` cluster allocation with atomic rollback on shortfall, old cluster chain preservation, and 4-byte BMP row stride padding.
  - Fixed `cmd_screenshot` dynamic byte size computation and default filename.
  - Connected `focus_follows_mouse` to `settings.zig`, refactored `about_dialog_close()`, wired `WidgetState` to `Button`/`TextInput`, fixed `sysmon` hotkeys/honest labels, and updated `docs/dogfood-m27.md` and claim 8041 with exact Touches and audit distinctions.
  - Verified all unit test suites, coordination, BSS budgets, and image build green.

