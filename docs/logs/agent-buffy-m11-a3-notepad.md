# Log — `NOTEPAD.BIN` (Graphical Text Editor)

## Context

- **Goal:** Implement the standalone EL0 graphical text editor `user/src/notepad.zig`, integrate persistent load/save with `/data/notes.txt`, and package `NOTEPAD.BIN`.
- **Claim:** [`docs/claims/3234-a3-notepad-editor.md`](../claims/3234-a3-notepad-editor.md)

## Entries

### 2026-08-15: Completed Card A3 implementation (claim 3234)

- Implemented `user/src/notepad.zig` (`NOTEPAD.BIN`):
  - Multi-line text buffer with cursor navigation (Arrow Left/Right), typing, newline insertion, and backspace.
  - Toolbar with `Load`, `Save`, and `Clear` buttons, plus dynamic status messaging.
  - Persistent `/data/notes.txt` file I/O via Milestone 10 storage syscalls (`sys_file_open`, `sys_file_read`, `sys_file_write`, `sys_file_close`).
- Integrated `NOTEPAD.BIN` into `build.zig` and `image/make-image.sh`.
- Verified with unit tests (`zig test user/src/notepad.zig`), disk image inspection (`zig build image`), and binary embedding.
- Flipped claim 3234 to ✅ done and updated `docs/march-m11.md`.
