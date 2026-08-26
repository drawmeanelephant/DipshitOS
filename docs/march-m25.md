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
| F1 | **Bulk operations.** Ctrl+click to select multiple files. Ctrl+A selects all. Selected files have a highlight. Batch delete: Del key deletes all selected files (confirmation dialog). Batch move: Ctrl+M moves selected files to a target directory (prompted). Progress indicator using the ProgressBar widget. | ✅ | `tools/verify-live-filemanager-bulk.sh` (claim 0434) | Selection bitmap (row-indexed; claim 4379's merged groundwork + the index fix), Ctrl+A/Del-dialog/Return walk live on VZ with one serial marker per batch unit (`file: del i/n NAME`) and slot-34 `calls=2` in the syscalls report. ProgressBar advances across frames via stepwise batch units (single-threaded loop: one unit per pass, no synchronous overdraw). |
| F2 | **File properties.** Right-click → "Properties" shows a panel with: file size (bytes), type (text/binary/directory), last modified timestamp (if available), full path. Displayed in the preview pane. | ✅ | `tools/verify-live-filemanager-props.sh` (claim 0434) | Ctrl+I / 'p' toggles the inspector live (`file: props on/off`); right-click context menu (ui.ContextMenu) drives the same actions, pinned by host unit tests — synthesized RIGHT clicks hit the claim-4769 activation wall, so the menu's live proof stays keyboard-mediated. Timestamps "N/A" per FAT32 short-name limitation. |
| F3 | **Create directory.** Ctrl+Shift+N prompts for a directory name and creates it. Uses existing `sys_file_create` (slot 25). The new directory appears immediately in the listing. Invalid characters rejected with an error message. | ✅ | `tools/verify-live-filemanager-mkdir.sh` (claim 2539) | Correction to the card text: there was NO directory-create seam (issue #383's premise was wrong) — kernel-side FAT32 `create_dir` landed (cluster alloc + zeroed cluster + `.` / `..` dot entries + ATTR_DIRECTORY parent slot) by extending slot 23's flag contract with `MODE_DIR`; EL0 seam is `ui.file_mkdir`. Live gate drives FSTEST.BIN headlessly: mkdir ok → dir lists empty → second mkdir refuses -9. Dot-entry bytes pinned by fat.zig host tests. The card's literal Ctrl+Shift+N chord walk is deferred: M21 W3's global Ctrl+N minimize intercept fires on the Shift combo too (focus steal); the one-line input.zig shift-guard is held by ACTIVE claim 8777. |
| F4 | **Disk usage.** `du` command from the shell shows per-directory size (recursive). FILE.BIN shows directory size in the breadcrumb bar (e.g., "DATA (128 KB)"). Non-blocking: scans the FAT allocation table for the target directory. | 🔶 | `user/src/file_browser.zig` listing marker `du=` + breadcrumb total (live in every F1–F5 gate run); `fat.dir_size_recursive` walker (host-tested) | FILE.BIN half done: bounded recursive byte sum (depth ≤ 3, window ≤ `max_entries` children/level) computed per listing, shown in the breadcrumb bar and reported in every `file: listing N entries du=B` marker. The shell `du` REGISTRY HALF is deferred while ACTIVE claim 8777 holds `kernel/src/monitor.zig`: the walker exists in fat.zig, so the command is a thin registry row + handler when that file frees. |
| F5 | **Recent files.** "Recent" virtual directory showing the last 10 opened/created files. Shown as the first entry in the root listing. Click to navigate to that file. BSS ring of filenames. | ✅ | `tools/verify-live-filemanager-recent.sh` (claim 2539) | Ring persists to `/data/RECENT.SAV` (plain 8.3 — leading-dot names are not representable in FAT short names) via slots 23/25 on every open; loaded at startup. Virtual RECENT entry injected + PINNED at row 0 of the root listing; opens a read-only pseudo-listing of stored full paths (destructive verbs consumed as no-ops there). Dedup moves re-opened paths to front. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Selection & bulk** | `user/src/file_browser.zig` for F1 (bulk ops), F2 (properties). | M17 C7 (file browser base). |
| **B — Directory & metadata** | `user/src/file_browser.zig` for F3 (create dir), F4 (disk usage), F5 (recent). `kernel/src/shell.zig` for `du` builtin. | F1 (selection state must exist for bulk operations on new directories). |

## Notes

1. **ABI budget:** Zero new syscall slots. F3 extends slot 23's
   (`sys_file_open`) flag contract with `MODE_DIR` (0x10) instead of
   minting a slot; the EL0 convenience seam is `ui.file_mkdir`.
2. **Stack reality (observed, claim 0434/2539):** FILE.BIN's AppState is
   ~7.3 KiB of the EL0 task stack; the batch + deferred-listing chains
   overflowed the old 16 KiB budget (live guard-page status=139). EL0
   `task_stack_size` doubled to 32 KiB (scheduler.zig) — BSS cost ~80 KiB,
   inside the verify-bss-budget headroom. App-side discipline unchanged:
   post-op re-listings are deferred to event-loop depth
   (`pending_refresh`), never stacked under input handlers.
3. **Gate shape:** F1: `verify-live-filemanager-bulk.sh` — multi-select +
   delete. F2: `verify-live-filemanager-props.sh` — properties panel.
   F3: `verify-live-filemanager-mkdir.sh` — directory creation (headless
   FSTEST walk; see the card's W3-collision note for the chord walk).
   F4: `verify-live-filemanager-du.sh` — lands with the shell `du`
   registry half (deferred on claim 8777). F5:
   `verify-live-filemanager-recent.sh` — persist + virtual entry.
   All gates assert serial MARKERS plus volume ground truth via the
   monitor (`mount data` + `ls`), never total entry counts — background
   writers (M21 W11 persistence) legitimately touch the DATA volume.
4. **File properties limitation:** FAT32 doesn't store modification timestamps
   in the short-name directory entry. The properties panel shows "N/A" for
   timestamps. If extended attributes (VFAT long names) are added later,
   timestamps can be extracted from there.
5. **Scope exclusions:** No archive/compression (tar, zip). No file
   permissions model. No file content search (use Ctrl+F in EDIT.BIN).
   No file size sorting (deferred to a future polish pass).
6. **F6–F18** exist only as GitHub issues (#386–#398); claim 4379's
   merged PR #561 carries reference implementations for several of them
   (trash, bookmarks, split panes, dialogs, associations resolver) that
   follow-up claims can build on or replace.

