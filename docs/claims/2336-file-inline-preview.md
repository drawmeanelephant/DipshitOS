# Claim: FILE.BIN inline preview + path breadcrumbs (M15 C7)

- **Owner:** buffy (`agent/buffy/m15-c7-file-preview`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` C7 (issue #232) — pick up at C7 per user ack 2026-08-20 after C5/C6 done
- **Scope:** Arc 3 App Upgrades — pure `user/src/file_browser.zig` + `user/src/lib/ui.zig` (no new syscall/kind). C7: inline selected-file preview (no mode switch, first 15 lines, printable sniff → `(binary)`), clickable breadcrumb bar at top (`/data/ > subdir > file`), 60/40 split (reuse existing `list_area`/`details_area`, keep `view_mode` for full view but preview is inline), HScroll 16-row slice if needed (not full #222), session-only persistence, host tests for preview/binary/breadcrumb hit-test, `verify-bss-budget` headroom.
- **Depends on:** FILE.BIN ✅ M13 B3 claim 4742; `ui.zig` toolkit ✅ M11 A1; C5/C6 ✅ c0d576a (notepad wrap/find lockstep, no file conflict); no ABI.
- **Status:** ✅ done 2026-08-21 — `user/src/file_browser.zig` inline preview (selection auto-loads `preview_content[512]` first 15 lines, `is_binary_content` ≥80% printable sniff → `(binary)` placeholder for non-TXT/binary, `preview_is_binary` flag) + breadcrumb bar (`breadcrumb_rect 60,6,440,12` muted, `format_breadcrumbs`/`breadcrumb_hit_test`/`truncate_to_segment`, `current_path[64]` session-only, `enter_directory`/`navigate_to_segment`/`breadcrumb_click`, `build_path` helper, `refresh_preview` on select/click/keyboard, `draw_details` preview below metadata) + `HScroll` deferred (preview wraps at `preview_cols 30`, no extra widget). Host tests 25/25 PASS (6 new: binary sniff, breadcrumbs hit-test, build_path, current_path nav, preview auto-load, breadcrumb_click), `zig build` PASS `FILE.BIN 10882` (+24B), `verify-bss-budget` PASS `9788088/11534336` (1746248 B headroom), `zig fmt --check` PASS.

## Notes

C7 is the first FILE.BIN upgrade after M13 B3: selection auto-loads preview into right pane (no Open click), breadcrumb shows `current_path` split by `/` with hit-test per segment (click navigates). Binary files sniffed via printable threshold (≥80% printable + allow \t\n\r). Content rendered 15 lines max, wrapped at `view_cols`. `current_path` starts `/data`, entering dir appends, breadcrumb up navigates. `view_mode` retained for full file view (Enter). All buffers stack-allocated, zero heap, BSS growth <1 KiB.

Evidence: `artifacts/disk.img` built with new FILE.BIN (10882 B), host tests `file_browser.zig` 25/25 PASS including `AppState size: 2080 <4KiB`.
