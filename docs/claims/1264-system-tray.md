# Claim: System tray / notification area (replaces clock window)

- **Owner:** Muse Spark (`agent/buffy/arc2-tray`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` + GH #226 — Arc2 Window Management deferred past M17 (compositor-only)
- **Scope:** Arc2 — `kernel/src/driving_award.zig` taskbar tray (Kind.taskbar id 255, 20px @ y=700, right 80px: HH:MM from tick + theme D/L/A + clipboard filled/empty rect) + migration/removal of Kind.clock id 1 (no duplicate clock). No new syscall/event. Owns driving_award tray + theme/clipboard indicator.
- **Depends on:** M17 done, M14 clipboard (512B) + taskbar + driving_award.theme_id live. No ABI, purely compositor.
- **Status:** 🔄 `agent/buffy/arc2-tray`

## Notes

Implements #226 per groomed issue: right 80px of taskbar shows HH:MM (tick-derived), theme letter D/L/A in accent color, clipboard filled/empty rect. Clock window Kind.clock deprecated (do not add second clock). Owns driving_award tray rendering. Zero heap, host tests for tray rect + clock format, no BSS growth beyond tray state.
