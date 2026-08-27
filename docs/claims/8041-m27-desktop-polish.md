# Claim: M27 Desktop polish & completeness sweep — G1-G30 (issues #444-#473)

- **Owner:** Buffy (`agent/buffy/m27-desktop-polish`)
- **Prompt / plan:** `docs/march-m27.md`
- **Scope:** Milestone 15 (M27) — G1-G30 complete sweep (#444–#473): screenshots, help/shortcuts, UI helpers (menu_build, show_dialog, widget states, empty/error formatting), compositor polish (splash, about, previews, tooltips, sound, cursors, focus), apps (sysmon, first-boot wizard, danger confirmation, crash recovery), settings reset/defaults, audits (clipboard, perf, leaks, keyboard nav), and dogfood session.
- **Depends on:** M21, M23, M24, M25, M26 merged ✅
- **Touches:** `kernel/src/monitor.zig`, `kernel/src/driving_award.zig`, `kernel/src/settings.zig`, `kernel/src/main.zig`, `kernel/src/shell.zig`, `kernel/src/tombstone.zig`, `kernel/src/exceptions.zig`, `user/src/lib/ui.zig`, `user/src/settings_panel.zig`, `user/src/sysmon.zig`, `user/src/file_browser.zig`, `user/src/edit.zig`, `user/src/notepad.zig`, `user/src/calc.zig`, `build.zig`, `image/apps.txt`, `docs/dogfood-m27.md`
- **Heartbeat:** 2026-08-26
- **Status:** ✅ done 2026-08-26 — M27 Desktop Polish & Completeness Sweep G1-G30 (#444-#473) complete: screenshot streaming BMP writer, help --all catalog, shortcuts matrix, WidgetState, ContextMenu separators/keys/shortcuts, standard Dialog helpers, empty state presenter, format_error, cursor feedback, focus restore, SYSMON.BIN dashboard, first-boot setup wizard in SETTINGS.BIN, dogfood audit report in docs/dogfood-m27.md, all unit tests pass.

## Notes

Milestone 15 on GitHub covers 30 polish issues (#444–#473). Zero new syscall slots.
All work strictly preserves the kernel BSS budget (<11.0 MiB) and zero-heap userland.
