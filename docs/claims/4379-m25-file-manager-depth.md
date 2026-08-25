# Claim: M25 File Manager Depth (GitHub Milestone 13)

- **Owner:** buffy (`agent/buffy/m25-file-manager-depth`)
- **Prompt / plan:** `docs/march-m25.md`
- **Scope:** M25 (file manager depth) cards F1–F18 (GitHub issues #381–#398 in milestone 13) in `user/src/file_browser.zig`
- **Touches:** user/src/file_browser.zig, docs/march-m25.md, docs/claims/4379-m25-file-manager-depth.md, docs/logs/agent-buffy-m25-file-manager-depth.md
- **Depends on:** —
- **Heartbeat:** 2026-08-25
- **Status:** ⛔ agent/buffy/m25-file-manager-depth

## Notes

Review feedback on PR #561:
1. Fixed data-loss bug in `user/src/file_browser.zig`: standardized `selection_bitmap` strictly on display row indices across `handle_mouse_events`, `draw_list`, and batch loops (`perform_delete`, `perform_move`, `perform_batch_rename`). Added test with reverse-sorted synthetic listings verifying no index misalignment.
2. Restored `docs/march-m25.md` to preserve the planned class-B live VZ gates (`verify-live-filemanager-*.sh`) and honest card tracker.
3. Yielded Lane A (F1, F2) and Lane B (F3, F4, F5) back to `ox-alpha` (claims 0434 and 2539) which are actively implementing the kernel FAT32 directory creation and `du` builtin.
4. Draft PR #561 holds the UI widget and index bug fix work for reference by `ox-alpha`.

