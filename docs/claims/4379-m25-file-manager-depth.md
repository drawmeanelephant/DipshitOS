# Claim: M25 File Manager Depth (GitHub Milestone 13)

- **Owner:** buffy (`agent/buffy/m25-file-manager-depth`)
- **Prompt / plan:** `docs/march-m25.md`
- **Scope:** M25 (file manager depth) cards F1–F18 (GitHub issues #381–#398 in milestone 13) in `user/src/file_browser.zig`
- **Touches:** user/src/file_browser.zig, docs/march-m25.md, docs/claims/4379-m25-file-manager-depth.md, docs/logs/agent-buffy-m25-file-manager-depth.md
- **Depends on:** —
- **Heartbeat:** 2026-08-25
- **Status:** ✅ agent/buffy/m25-file-manager-depth

## Notes

Implements Milestone 25 / GitHub Milestone 13 (cards F1–F18):
- F1: Multi-selection bitmap (`selection_bitmap [32]u8`), Ctrl+click, Ctrl+A select all, batch delete/move
- F2: File properties panel (`Ctrl+I` / `P` inspector toggle with size, type, path, cluster info)
- F3: Directory creation (`Ctrl+Shift+N`)
- F4: Disk usage (`du`) summary in breadcrumb and details pane
- F5: Recent files ring (last 10 opened/created files)
- F6: Trash & restore mechanism (`.TRASH/` staging)
- F7: Batch rename pattern
- F8: Split panes view (`Ctrl+W` / `Tab` pane toggling)
- F9: Bookmarks / favorites (`Ctrl+D` bookmarking)
- F10: Recursive file search
- F11: Column sorting (Name/Size/Type)
- F12: Hidden files toggle (Ctrl+H)
- F13: File associations (.TXT, .BIN, .MD, .C)
- F14: Terminal here (Ctrl+T)
- F15: Editor here (Ctrl+E)
- F16: Path copy (Ctrl+Shift+C)
- F17: Overwrite / conflict resolution
- F18: Transactional delete confirmation UX

Verified via pure host-side class-A unit tests covering all data structures, selection bitmaps, properties formatting, split pane navigation, and keyboard routes.
