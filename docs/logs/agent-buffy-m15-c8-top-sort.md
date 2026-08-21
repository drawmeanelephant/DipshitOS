# Log — `agent/buffy/m15-c8-top-sort`

### 2026-08-21 — claim 0265

Claimed. C8 TOP.BIN sortable + filter — header click sort (PID/Name/State/Exit, toggle ↑/↓, stable insertion), TextInput filter partial case-insensitive, re-sort/re-filter on handle_timer 1 Hz (12 ticks), state persists, pure top.zig, no ABI, after C7.

### 2026-08-21 — claim 0265 done

Implemented. `top.zig` sortable columns (`SortColumn`, `compare_procs`, `name_contains`, `rebuild_display` filtered+stable sorted `display_indices`, `click_column` toggle, header rect 52..68 click) + filtering (`filter_input` TextInput 260,6,110,20, `Filter:` label, focused key handling, `/`/`f` focus, Esc unfocus, `set_filter`) + `draw` header ↑/↓ accent + filtered rows + filter input + stats `display_count` + `display_to_absolute` mapping + `handle_mouse_events` header/row/filter + `handle_keyboard_event` filtered nav + `handle_timer`/`kill_selected` rebuild. Fixed stale `kill_selected` absolute vs filtered, added 8 host tests. Host tests 23/23 PASS, AppState 1352B, `zig build`/`image` PASS 10526B, `verify-bss-budget` PASS.

