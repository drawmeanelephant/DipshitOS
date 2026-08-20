# Claim: NOTEPAD wrap + find/replace lockstep (M15 C5+C6)

- **Owner:** buffy (`agent/buffy/m15-c5c6-notepad`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` C5+C6 (issues #230/#231) — lockstep per user ack 2026-08-20
- **Scope:** Arc 3 App Upgrades — pure `user/src/notepad.zig` + `user/src/lib/ui.zig` (no new syscall/kind). C5: soft-wrap at last space, left gutter line numbers, Up/Down/PageUp/PageDown, status `Line X of Y`, CR/LF preservation. C6: `Ctrl+F` bottom bar, `Enter` next match, `Ctrl+H` replace, Replace-All, substring highlight (not whole wrapped line), `case_sensitive` const (deferred v1 schema #247), dirty via `@MEMORY_DIRTY` for #242. No heap, BSS `find_buf[32]` + `replace_buf[32]` + `find_state`, host tests for wrap/find/highlight, `verify-bss-budget` headroom.
- **Depends on:** C4 dock (✅ 20bb8b5) — same milestone, sequential `ui.zig` owner after C4; `ui.zig` toolkit ✅ M11 A1; NOTEPAD BSS ✅ M11 A3 claim 3234.
- **Status:** ✅ done 2026-08-20 — `user/src/notepad.zig` soft-wrap (`TextLayout` last_space, gutter, `Line X of Y`) + `find_next`/`replace`/`replace_all` (case_sensitive=false) + `AppState` find bar (`find_active`/`find_buf`/`replace_buf`) + `draw` highlight + `handle_keyboard_event` Ctrl+F/H, host tests `soft-wrap`/`find` PASS, `verify-bss-budget` PASS `9788088/11534336`

## Notes

C5+C6 lockstep keeps the find/wrap highlight contract honest: a match spanning soft-wrapped lines highlights the matched substring, not the whole display row. The wrap is render-time soft-wrap (buffer stays linear, `'\n'` is hard break, over-col soft break at last space within `cols`, fallback to hard `cols` when no space). The gutter shows display-row numbers (1-based) at `x= text_area.x+2`, the status shows `Line X of Y` where X is `position_at(cursor).row+1` and Y is `total_rows`. `Ctrl+F` (HID 0x09) toggles the find bar at `y= text_area.y+text_area.h-20`, `Ctrl+H` (0x0b) adds replace field, `Enter` jumps to next match (wrap), `Replace`/`Replace All` mutate buffer and set dirty. All host-testable: `TextLayout` soft-wrap, `find_next`/`replace` with `case_sensitive=false` const, highlight bounds.

