# Claim: System tray / notification area (replaces clock window)

- **Owner:** Muse Spark (`agent/buffy/arc2-tray`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` + GH #226 — Arc2 Window Management deferred past M17 (compositor-only)
- **Scope:** Arc2 — `kernel/src/driving_award.zig` taskbar tray (Kind.taskbar id 255, 20px @ y=700, right 80px: HH:MM from tick + theme D/L/A + clipboard filled/empty rect) + migration/removal of Kind.clock id 1 (no duplicate clock). No new syscall/event. Owns driving_award tray + theme/clipboard indicator.
- **Depends on:** M17 done, M14 clipboard (512B) + taskbar + driving_award.theme_id live. No ABI, purely compositor.
- **Status:** ✅ done 2026-08-21 — `kernel/src/driving_award.zig` tray (Kind.taskbar id 255 20px @ y=700 right 80px: HH:MM via `format_hhmm` from tick, theme D/L/A `theme_letter` in `tray_theme_accent`, clipboard filled/empty rect via `tray_clipboard_filled`) + `Kind.clock` id 1 migration (no duplicate window, `arm` 4 windows, `drain`/`composite` tick without timer); `kernel/src/syscall.zig` z/count tests updated (4 base, z=4); host tests 140/140 PASS, `verify-bss-budget` PASS 9788088/11534336, `verify-coordination` PASS — branch `agent/buffy/arc2-tray` (commit 4521ff1)

## Notes

Implements #226 per groomed issue: right 80px of taskbar shows HH:MM (tick-derived), theme letter D/L/A in accent color, clipboard filled/empty rect. Clock window Kind.clock deprecated (do not add second clock). Owns driving_award tray rendering. Zero heap, host tests for tray rect + clock format, no BSS growth beyond tray state.

## Evidence

- `zig test kernel/src/driving_award.zig` 140/140 PASS (tray helpers: `tray_rect` 1200,700,80,20, `format_hhmm` 00:00/23:59 wrap, `theme_letter` D/L/A, `tray_clipboard_filled` empty/filled, `drain` tick, `composite` renders HH:MM white + theme accent + clipboard filled/outline in right 80px, `Kind.clock` enum remains but no window)
- `bash tools/verify-unit-tests.sh` PASS (previously 2 failures in `syscall.zig` z/count fixed: 349/349, 492/492, etc.)
- `bash tools/verify-bss-budget.sh` PASS 9788088/11534336
- `zig build` PASS, `zig fmt --check` PASS, `bash tools/verify-coordination.sh` PASS
