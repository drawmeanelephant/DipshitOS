# Log — `agent/buffy/m15-c7-file-preview`

### 2026-08-21 — claim 2336

Claimed. C7 FILE.BIN inline preview + breadcrumbs — 60/40 split, left list, right first-15-lines preview, top breadcrumb y=4 muted, printable sniff binary placeholder, hit-test per segment, session-only, pure file_browser.zig + ui.zig, no ABI, after C5/C6 c0d576a.

### 2026-08-21 — claim 2336 done

Implemented. `file_browser.zig` inline preview (`refresh_preview` on select/click/Up/Down/Home/End, `preview_content[512]` first 15 lines at `preview_cols 30`, `is_binary_content` 80% sniff, `is_txt` gate → `(binary)`/`(directory)` placeholders, `draw_details` preview below Size/Type/Name) + breadcrumbs (`current_path[64]` `/data` init, `build_path`, `enter_directory`, `navigate_to_segment` via `truncate_to_segment`, `format_breadcrumbs`/`breadcrumb_hit_test`, `breadcrumb_rect`, `draw` breadcrumb in title bar accent/muted, `handle_mouse_events` breadcrumb priority + `breadcrumb_click`, `handle_keyboard_event` refresh). Fixed `FileList` test stale rect (128px/8 rows), AppState 2080B <4KiB. Host tests 25/25 PASS (6 new), `zig build` PASS, `verify-bss-budget` PASS 9788088/11534336, `zig fmt --check` PASS, `zig build image` PASS 128M.

