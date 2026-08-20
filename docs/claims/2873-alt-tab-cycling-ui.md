# Claim: Alt+Tab cycling UI overlay (M15 C2)

- **Owner:** buffy (`agent/buffy/m15-c2-alt-tab`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` C2 (issue #225)
- **Scope:** Arc 2 Window Management — pure visual layer over M8 U4 decode (claim 4993). Hold-Alt+Tab shows centered overlay of window previews, Tab/Shift+Tab cycles highlight, release-Alt raises+focuses selected. No new syscalls, no new event kinds (reuses `cycle_focus` + existing Alt+Tab HID decode). Pure `driving_award.zig` + `input.zig` + `shell.zig` idle-loop glue, plus host tests. Respects `dock=true` future and `D7` layering (overlay is topmost below notifications).
- **Depends on:** M15 C1 DropDown (✅ PR250) — inherits layering model; M8 U4 Alt+Tab decode (✅ claim 4993) — visual only.
- **Status:** ✅ done 2026-08-20 — `driving_award.zig:168` overlay BSS (32 B) + `input.zig:86` Alt+Shift latch + `shell.zig:191` hold-Alt commit, host tests PASS 125/125 `driving_award`, class-A `verify-bss-budget` PASS `9787576/11534336`, `zig fmt` + `zig build` + `test-console` PASS

## Notes

C2 is the first compositor-depth card after the widget foundation. The HID chord (Alt 0x04/0x40 + Tab 0x2b) already lands hidden — `input.zig:86` latches `alt_tab_pending`, `shell.zig:191` drains it to `driving_award.cycle_focus()` with a serial `dui: cycle focused=` line. C2 replaces that instant-cycle with a hold-Alt overlay:

- **State:** `overlay_active` + `overlay_selected` + snapshotted `overlay_ids[8]`/`overlay_count` in `driving_award.zig` BSS (no heap, no allocation).
- **Activation:** first Alt+Tab while Alt held → snapshot current user windows (skip wallpaper/taskbar, respect visibility), pick `selected = (focused_index+1) % user_count`, set `active=true`, mark dirty. If `user_count ≤1` → no overlay (no-op).
- **Cycle:** subsequent Alt+Tab edges while active → `selected = (selected ±1) % count` (Shift inverts). Host-tested pure `cycle_next`.
- **Commit:** Alt release (`input.alt_held()==false`) while active → `focus(id)+raise(id)` on selected, deactivate, dirty. Right-click or Escape also dismisses without commit.
- **Rendering:** `draw_chrome()` paints overlay after user chrome: dimmed backdrop + centered 360×(48+count*24) rect, per-window row with title bar preview + pid, highlight border on `selected`. Layer `D7` — below notification, above user windows. Scale-aware: uses `fb_width/fb_height` constants.
- **Verification:** host tests for snapshot/cycle/commit/dismiss, `just verify-bss-budget` (overlay BSS ≈ 32 B), and a class-B `verify-live-alt-tab.sh` that drives `dui cycle` as serial fallback plus a `--input-chords` Alt+Tab sequence for the live overlay path (screenshots decoded like `verify-live-win-hig.sh`).
- **Collisions:** per `docs/m17-desktop-completeness.md:45` discipline — right-click dismisses overlay without cycling (overlay owns input until Alt released), per-workspace visibility deferred to #241 (current workspace == all windows).

