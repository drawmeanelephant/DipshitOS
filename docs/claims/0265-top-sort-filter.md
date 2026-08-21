# Claim: TOP.BIN sortable columns + process filtering (M15 C8)

- **Owner:** buffy (`agent/buffy/m15-c8-top-sort`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` C8 (issue #233) — after C7
- **Scope:** Arc 3 App Upgrades — pure `user/src/top.zig` (+ `user/src/lib/ui.zig` TextInput if needed). C8: column headers PID/Name/State/Exit clickable sorts (toggle ↑/↓), stable sort (PID numeric, Name lexicographic case-insensitive, State, Exit), TextInput filter at top (partial match case-insensitive), re-sort/re-filter on every `handle_timer` (1 Hz auto-refresh, `auto_refresh_ticks 12`), sort+filter combined, state persists across ticks, host tests for sort/filter/combined, `verify-bss-budget` headroom.
- **Depends on:** TOP.BIN ✅ M11 A4 claim 0680 + enhancements (history_len 48, auto_refresh); `sys_procs` slot 7 ✅ M14; `ui.TextInput` ✅ M11 A1; C7 ✅ 990ecd8 (no file conflict).
- **Status:** ✅ done 2026-08-21 — `user/src/top.zig` sortable columns + filtering (`SortColumn pid/name/state/exit`, `compare_procs`, `name_contains` case-insensitive, stable insertion sort on `display_indices`, `filter_input TextInput 260,6,110,20` with label `Filter:`, header hit-test 52..68 click_column toggle ↑/↓, `rebuild_display` filtered+sorted, `handle_mouse_events` header+filter+row (display), `handle_keyboard_event` filter-focused priority + filtered Up/Down, `handle_timer`/`kill_selected` rebuild, `draw` header indicator accent + filtered rows). Host tests 23/23 PASS (8 new: compare, contains, sortable, filter, sort+filter, auto-refresh preserve, header click, row click), `TOP AppState 1352 <4KiB`, `zig build` PASS `TOP.BIN 10526` (+2355B), `verify-bss-budget` PASS `9788088/11534336` headroom `1746248`, `zig fmt --check` PASS.

## Notes

C8 is the last pure TOP upgrade after M11 A4: header row becomes interactive, filter input filters by name substring case-insensitive, sorting is stable (insertion sort on indices). Columns: PID (u64 numeric), NAME (case-insensitive strcmp), STATE (created 1 < running 2 < exited 3), EXIT (u64). Filter + sort compose: filter first, then stable sort. `handle_timer` preserves `sort_column`/`ascending`/`filter`. Filter widget is a `TextInput` at toolbar right (260,6,110,20) with label "Filter:"; when focused, key events go to it, else table nav. All zero heap, BSS growth <1 KiB.

Evidence: `artifacts/disk.img` built with new TOP.BIN (10526 B), host tests `top.zig` 23/23 PASS including `AppState size 1352`.
