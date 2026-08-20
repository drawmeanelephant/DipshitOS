# Log — `agent/buffy/m15-c5c6-notepad`

### 2026-08-20 — claim 5227

Claimed. C5+C6 NOTEPAD wrap+find lockstep — soft-wrap at last space, gutter, Line X of Y, Ctrl+F bottom bar + Ctrl+H replace, substring highlight, case_sensitive const, dirty via @MEMORY_DIRTY. Pure notepad.zig + ui.zig, no new ABI, lockstep per user ack.


### 2026-08-20 — claim 5227 done

Implemented. `notepad.zig` `TextLayout` soft-wrap (last_space, hard fallback, `position_at`/`row_bounds`/`total_rows` with `last_space`, gutter line numbers, `Line X of Y` status) + `AppState` find/replace lockstep (`find_next`/`replace_current`/`replace_all` case_sensitive=false, `find_buf`/`replace_buf`, `handle_keyboard_event` Ctrl+F/H, `handle_mouse_events` Find/Replace buttons, `draw` substring highlight + find bar). Fixed `last_space` shadowing, `draw` status and alias `memcpy`. Host tests: soft-wrap hard fallback, gutter/status, find next/case-insensitive/replace, `DropDown` y=70 fix, `notepad` 26/26 PASS, `verify-bss-budget` PASS.
