# Milestone twenty-five march — file manager depth (living tracker)

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts. This file holds M25's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

FILE.BIN (M13 B3, M17 C7) is a file browser with inline preview and
breadcrumbs. It can open, create, delete, rename, and truncate files.
But it has no bulk operations, no file properties, no directory creation,
and no disk usage information. M25 turns the file browser into a file
*manager*.

**Zero new syscall slots.** All changes use existing file and window syscalls.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| F1 | **Bulk operations.** Ctrl+click to select multiple files. Ctrl+A selects all. Selected files have a highlight. Batch delete: Del key deletes all selected files (confirmation dialog). Batch move: Ctrl+M moves selected files to a target directory (prompted). Progress indicator using the ProgressBar widget. | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `file_browser.zig` selection state: `selection_bitmap` (32 bytes = 256 files), `is_selected`, `toggle_select`, `select_all`, `clear_selection`, `selected_count`, batch delete/move |
| F2 | **File properties.** Right-click → "Properties" or `Ctrl+I` / `P` shows a panel with: file size (bytes), type (text/binary/directory), full path, cluster info. Displayed in the preview/details pane. | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `file_browser.zig` metadata read + properties inspector toggle in preview area (`toggle_properties`). FAT32 timestamps documented as N/A. |
| F3 | **Create directory.** Ctrl+Shift+N prompts for a directory name and creates it. Uses existing `sys_file_create` / `sys_file_open` (slot 25). The new directory appears immediately in the listing. | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `file_browser.zig` `create_dir_active`, `create_dir_input`, `confirm_create_dir` overlay. |
| F4 | **Disk usage.** Per-directory total size summary. FILE.BIN shows directory size in the properties panel and breadcrumb bar. | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `total_dir_bytes()` scan summing directory entries. |
| F5 | **Recent files.** Virtual ring showing the last 10 opened/created files. Quick jump navigation. | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `recent_ring` (10 × 32 bytes) updated on open/create. |
| F6 | **Trash & restore.** Trashing deletes file with staging in trash ring; `u`/`U` restores last trashed file. | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `trash_names`, `trash_selected`, `restore_trash`. |
| F7 | **Batch rename.** Pattern / prefix batch rename for all multi-selected files. | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `batch_rename_prefix`. |
| F8 | **Split panes.** Dual-pane mode (`Ctrl+W` to toggle, `Tab` to switch active pane). | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `split_pane`, `active_pane`, `toggle_split_pane`, `switch_active_pane`. |
| F9 | **Favorites / bookmarks.** Bookmarks bar / list (`Ctrl+D` to bookmark current folder, `jump_bookmark` to navigate). | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `bookmarks` ring (8 × 32 bytes), `add_bookmark`, `jump_bookmark`. |
| F10 | **File search.** Real-time substring filter (`Ctrl+F`). | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | M20-U8 filter bar. |
| F11 | **Sorting options.** Clickable column headers (Name, Size, Type) with ascending/descending toggle. | ✅ | `user/src/file_browser.zig` unit tests | Closed on GitHub (#391). |
| F12 | **Hidden files toggle.** `Ctrl+H` toggle with dotfile filtering. | ✅ | `user/src/file_browser.zig` unit tests | Landed on `main` (#392). |
| F13 | **File associations.** Open dispatch based on file extension (.TXT, .BIN, .MD, .C). | ✅ | `user/src/file_browser.zig` unit tests | Associated viewer / executor dispatch. |
| F14 | **Terminal here.** `Ctrl+T` shortcut to spawn terminal in current directory. | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `terminal_here` action. |
| F15 | **Editor here.** `Ctrl+E` shortcut to launch editor on selected file. | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `editor_here` action. |
| F16 | **Path copy.** `Ctrl+Shift+C` copies current path to clipboard. | ✅ | `user/src/file_browser.zig` unit tests | Landed on `main` (#396). |
| F17 | **Overwrite & conflict resolution.** Collision check before create/rename. | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `check_collision` check. |
| F18 | **Transactional delete UX.** Multi-delete with status feedback and confirmation. | ✅ | `user/src/file_browser.zig` unit tests (claim 4379) | `delete_action` batch delete. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **Lane D-Files** | `user/src/file_browser.zig` for F1–F18 (file manager depth). | M17 C7 (file browser base). |

## Notes

1. **ABI budget:** Zero new syscall slots.
2. **BSS budget:** Selection bitmap 32 bytes. Recent ring 320 bytes. Bookmarks 256 bytes. Trash staging 256 bytes. Total M25 BSS delta: ~864 bytes. Fits well within stack/BSS budget.
3. **Verification:** All 70 class-A unit tests in `user/src/file_browser.zig` pass cleanly (`zig test user/src/file_browser.zig`). Full test suite (`bash tools/verify-unit-tests.sh`) and guest build (`zig build`) pass.
4. **File properties limitation:** FAT32 doesn't store modification timestamps in the short-name directory entry. The properties panel shows "N/A" for timestamps.
5. **Scope exclusions:** No archive/compression (tar, zip). No file permissions model.

