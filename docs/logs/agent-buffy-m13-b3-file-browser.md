# Log — `m13-b3-file-browser`: FILE.BIN, the graphical DATA-partition file browser (claim 4742)

## 2026-08-16 — branch opened

- Card B3 of Milestone 13 (issue #153): `FILE.BIN` graphical file browser.
- Plan: browse `/data/` in a scrollable list, open `.TXT` read-only, on the
  ui.zig toolkit with zero heap; delete/rename deferred to B1 (slots 34–37).
- Branch based on `origin/main` (`eeef25f`, M13 B2 docs merged via PR #166).

## 2026-08-16 — branch work

- `user/src/lib/ui.zig`: typed `dir_list(path, &entries)` wrapper over the
  raw slot-27 call (DIR.BIN still hand-rolls it; the wrapper is the
  file-browser seam).
- `user/src/file_browser.zig`: FILE.BIN with `FileList` (scroll/selection/
  click), details pane, and a read-only wrapping text view; `AppState` is
  ~1.4 KiB (fits the 16 KiB EL0 stack, W^X-safe). Markers: `file: ready`,
  `file: listing N entries`, `file: open NAME`, `file: view NAME`,
  `file: close`. Class-A tests green (14/14 incl. ui/font8x8).
- Wired the 21st ESP program through `build.zig`, `image/make-image.sh`
  (24th positional), `image/mkfat32.py` (`file_file`; the FILE.BIN cluster
  vars are `filebin_*` to avoid colliding with the EFI boot file's
  `file_clusters`), and `image/apps.txt`.
- `tools/verify-live-file-browser.sh`: capstone gate — exec FILE.BIN,
  inject Enter after `file: ready`, assert the list/open/view markers and
  `sys_dir_list`/`sys_file_open`/`sys_file_read` `calls=1`.
