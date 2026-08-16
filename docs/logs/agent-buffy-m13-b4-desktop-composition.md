# Log — `m13-b4-desktop-composition`: desktop composition (claim 4046)

## 2026-08-16 — branch opened

- Card B4 of Milestone 13 (issue #162): manifest-driven desktop composition.
- Plan: add FILE.BIN to the desktop's fallback catalog, raise the manifest
  cap to 16, and rework the file-browser gate into the DESKTOP → FILE.BIN
  composition proof.
- Branch based on `origin/main` (`c3cfc41`, B1 merged as PR #170).

## 2026-08-16 — branch work

- `user/src/desktop.zig`: ninth fallback entry (`FILE.BIN`), and
  `manifest_max_apps` 8 → 16 so the real nine-entry `APPS.TXT` parses
  without truncation. 14/14 tests (new catalog-cap test).
- `tools/verify-live-desktop.sh`: `desktop: manifest apps=8` → `apps=9`.
- `tools/verify-live-file-browser.sh` reworked into the B4 composition
  gate: boots DESKTOP.BIN only, eight Down arrows + two Returns walk the
  manifest menu and launch FILE.BIN via `sys_exec` (slot 28), then open
  README.TXT. Asserts the syscalls report (`sys_exec` calls=1, `dir_list`
  calls=1, `file_open`/`file_read` calls=2). **PASS 1/1 on VZ.**
- `verify-live-desktop.sh` re-ran: **PASS** (apps=9).
