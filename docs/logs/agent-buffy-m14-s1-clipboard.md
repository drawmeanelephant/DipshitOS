# Log — `agent/buffy/m14-s1-clipboard`: shared clipboard (claim 2611)

## 2026-08-19 — branch opened

- Claimed (claim 2611): Milestone 14 card S1 — `sys_clipboard_set`/
  `sys_clipboard_get` (ADR 0007 slots 38/39), one bounded BSS clipboard
  buffer, NOTEPAD copy/cut/paste, `CLIPTEST.BIN` + the class-B gate
  `tools/verify-live-clipboard.sh`. `implemented_count` 38 → 40.
- Branch based on `main` (carries the uncommitted hope-chest map work:
  claim 1028 + `docs/hope-chest.md` + pointer edits).

## 2026-08-19 — done

- Landed `kernel/src/clipboard.zig` (one bounded BSS buffer, zero heap),
  syscall slots 38/39 with uaccess-validated handlers, `implemented_count`
  38 → 40, and the monitor clipboard fixture for the interactive shell.
- NOTEPAD copy/cut/paste (Ctrl+C/X/V) via new `ui.zig` wrappers; `CLIPTEST.BIN`
  added as the twenty-third ESP program and the class-B gate
  `tools/verify-live-clipboard.sh`. Fixed a real contract bug the live run
  caught: the EFAULT-get probe must run while the clipboard is non-empty
  (empty-clipboard correctly short-circuits before the pointer access).
- Class-A green (fmt, 455 console + 22 unit tests, byte-identical transcript,
  build/image/inspect, swift build, coordination). Live gate on VZ PASS with
  set/get/truncate/nonconsuming/cap/clear/EFAULT/lifecycle markers.
