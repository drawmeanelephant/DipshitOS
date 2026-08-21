# Claim: Milestone 13 Card B3 — FILE.BIN graphical file browser

- **Owner:** buffy (`agent/buffy/m13-b3-file-browser`)
- **Prompt / plan:** `docs/march-m13.md`
- **Scope:** Milestone 13, Card B3 (Issue #153: `FILE.BIN` graphical file browser)
- **Depends on:** Milestone 12 (merged via PR #160); B2 manifest (claim 8877, PR #165)
- **Status:** ✅ done 2026-08-16 — FILE.BIN live: file: ready, listing 2 entries, open/view README.TXT; tools/verify-live-file-browser.sh PASS 1/1 on VZ

## Notes

The DATA partition (milestone-four card 2) holds `README.TXT` and `DATA.TXT`,
but nothing can browse it from EL0 — `DIR.BIN` prints a raw listing and
`TYPE.BIN` reads a single hardcoded path. This card ships `FILE.BIN`, the
capstone file browser:

- `user/src/file_browser.zig` — a zero-heap GUI app on the ui.zig toolkit
  (window ≤ 256×192, `AppState` stack-allocated, W^X-safe).
- Browse `/data/` via `sys_dir_list` (slot 27) into a scrollable list
  (`FileList` model: selection + viewport + click mapping, host-tested).
- Details pane shows the selected entry's size and type (FILE/DIR).
- Enter / the Open button opens a `.TXT` entry read-only through
  `sys_file_open`/`read`/`close` (slots 23/24/26) into a wrapping text view;
  Esc / Back returns to the list.
- `ui.zig` gains a typed `dir_list(path, &entries)` wrapper (the raw slot-27
  call DIR.BIN makes by hand).
- Delete/rename are **out of scope here** — they arrive with card B1
  (ADR 0007 slots 34–37, issue #161), which this browser will grow into.
- Class-A host tests: entry-name/`.TXT` detection, content wrap counting,
  `FileList` scroll/click/selection, path building, view-mode routing, and an
  `AppState`-fits-stack bound.
- `tools/verify-live-file-browser.sh` — the capstone live gate: exec
  FILE.BIN, inject Enter after `file: ready`, assert `file: listing 2
  entries`, `file: open README.TXT`, `file: view README.TXT`, and
  `sys_dir_list`/`sys_file_open`/`sys_file_read` `calls=1` in the syscalls
  report.
- Build/embed wiring: `build.zig` (twenty-first user program),
  `image/make-image.sh` (24th positional), `image/mkfat32.py` (`file_file`),
  and `image/apps.txt` gains a `FILE.BIN | File Browser | b` line.
