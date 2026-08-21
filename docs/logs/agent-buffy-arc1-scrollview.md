# Log — `agent/buffy/arc1-scrollview`

### 2026-08-21 — claim 0819

Claimed. ScrollView widget for ui.zig (GH #218, Arc1): pure ui.zig ScrollView with proportional thumb (max(16, visible*visible/content)), thumb drag, track click page, PAGE_UP/DOWN, optional MOUSE_SCROLL 13, host tests for thumb/offset/drag, + FILE.BIN list integration.

### 2026-08-21 — claim 0819 in progress

Implemented. `user/src/lib/ui.zig` ScrollView (init, content_h, offset, dragging, thumb_h/thumb_y/thumb_rect, handle_event MOUSE_DOWN/MOVE/UP/KEY_DOWN/MOUSE_SCROLL, draw track+thumb) + 4 host tests PASS (proportional thumb/clamp, PAGE/track, thumb drag scaling, 50+ lines demo) + `user/src/file_browser.zig` FILE.BIN proof (scroll_view field, sync_scroll_view/list_from, draw thumb, mouse drag/track, keyboard PAGE via ScrollView, _start loop MOUSE_SCROLL). `zig test user/src/lib/ui.zig` 12/12, `zig test user/src/file_browser.zig` 29/29, `zig build file` PASS 12082B, `verify-bss-budget` PASS 9788088/11534336.

