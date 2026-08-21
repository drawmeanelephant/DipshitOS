# Log — `agent/buffy/arc2-context-menu`

- 2026-08-21 — claim 1757 — context menus (#228) claimed — branch `agent/buffy/arc2-context-menu` — kinds 11 `MOUSE_RIGHT_DOWN` + 13 `MOUSE_RIGHT_UP` per ADR 0013 D2 (kind 12 is MOUSE_SCROLL for #236) — owns ui.zig ContextMenu + events 11/13
- 2026-08-21 — claim 1757 — landed on `main` — `events.zig` 11/13 + `ui.zig` ContextMenu (3 host tests) + `driving_award` right-button split (left/right, WIN_RESIZE/DRAG gated left-only) — `zig test` ui 32/32 driving_award 132/132, `verify-bss-budget` PASS 9788088/11534336, `zig fmt` PASS — no VZ — merges via direct commit to main (agent branch confusion resolved)
