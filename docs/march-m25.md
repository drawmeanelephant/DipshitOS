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
| F1 | **Bulk operations.** Ctrl+click to select multiple files. Ctrl+A selects all. Selected files have a highlight. Batch delete: Del key deletes all selected files (confirmation dialog). Batch move: Ctrl+M moves selected files to a target directory (prompted). Progress indicator using the ProgressBar widget. | ⬜ | — | `file_browser.zig` selection state. New BSS: `selection_bitmap` (32 bytes, supports up to 256 files), `bulk_operation` flag. Uses M17 ProgressBar widget for progress. Confirmation dialog uses M17 Dialog widget. |
| F2 | **File properties.** Right-click → "Properties" shows a panel with: file size (bytes), type (text/binary/directory), last modified timestamp (if available), full path. Displayed in the preview pane. | ⬜ | — | `file_browser.zig` metadata read + preview widget. Extends the M17 C7 preview pane. Uses existing FAT metadata (file size, cluster chain). Timestamp is not available on FAT32 without extended attributes — show "N/A" and document this. |
| F3 | **Create directory.** Ctrl+Shift+N prompts for a directory name and creates it. Uses existing `sys_file_create` (slot 25). The new directory appears immediately in the listing. Invalid characters rejected with an error message. | ⬜ | — | `file_browser.zig` + existing FAT create syscall. Prompts via a `ui.zig` TextInput overlay. The directory is created and the listing refreshes. |
| F4 | **Disk usage.** `du` command from the shell shows per-directory size (recursive). FILE.BIN shows directory size in the breadcrumb bar (e.g., "DATA (128 KB)"). Non-blocking: scans the FAT allocation table for the target directory. | ⬜ | — | `file_browser.zig` recursive size scan. `shell.zig` `du` builtin. The scan walks the FAT chain for each file in the directory. For deep directories, the scan is bounded at 3 levels. |
| F5 | **Recent files.** "Recent" virtual directory showing the last 10 opened/created files. Shown as the first entry in the root listing. Click to navigate to that file. BSS ring of filenames. | ⬜ | — | `file_browser.zig` recent ring (10 × 32 bytes = 320 bytes). Updated on file open/create. Persisted to FAT (survives reboot). The "Recent" entry is virtual — it doesn't exist on disk. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Selection & bulk** | `user/src/file_browser.zig` for F1 (bulk ops), F2 (properties). | M17 C7 (file browser base). |
| **B — Directory & metadata** | `user/src/file_browser.zig` for F3 (create dir), F4 (disk usage), F5 (recent). `kernel/src/shell.zig` for `du` builtin. | F1 (selection state must exist for bulk operations on new directories). |

## Notes

1. **ABI budget:** Zero new syscall slots.
2. **BSS budget:** Selection bitmap 32 bytes. Bulk operation state ~16 bytes.
   Recent ring 320 bytes. Total M25 BSS delta: ~368 bytes. Negligible.
3. **Gate shape:** F1: `verify-live-filemanager-bulk.sh` — multi-select + delete.
   F2: `verify-live-filemanager-props.sh` — properties panel shows size/type.
   F3: `verify-live-filemanager-mkdir.sh` — directory creation. F4:
   `verify-live-filemanager-du.sh` — disk usage output. F5:
   `verify-live-filemanager-recent.sh` — recent files list persists.
4. **File properties limitation:** FAT32 doesn't store modification timestamps
   in the short-name directory entry. The properties panel shows "N/A" for
   timestamps. If extended attributes (VFAT long names) are added later,
   timestamps can be extracted from there.
5. **Scope exclusions:** No archive/compression (tar, zip). No file
   permissions model. No file content search (use Ctrl+F in EDIT.BIN).
   No file size sorting (deferred to a future polish pass).

