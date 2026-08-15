# Log — `TOP.BIN` (Graphical Task Manager & Process Monitor)

## Context

- **Goal:** Implement the standalone EL0 graphical task manager `user/src/top.zig`, poll `sys_procs` (slot 7), render live process tables, and package `TOP.BIN`.
- **Claim:** [`docs/claims/0680-a4-top-process-monitor.md`](../claims/0680-a4-top-process-monitor.md)

## Entries

### 2026-08-15: Completed Card A4 implementation (claim 0680)

- Added `get_procs` syscall wrapper (slot 7) and `ProcInfo` decoding to `user/src/lib/ui.zig`.
- Implemented `user/src/top.zig` (`TOP.BIN`):
  - Live process table rendering with columns for PID, Name, State, and Exit status.
  - Interactive row selection via mouse click and keyboard Arrow Up/Down.
  - Toolbar with `Refresh` and `Kill` buttons, plus real-time process statistics header (`Procs: N Run: M`).
- Integrated `TOP.BIN` into `build.zig` and `image/make-image.sh`.
- Verified with unit tests (`zig test user/src/top.zig`), disk image inspection (`zig build image`), and binary embedding.
- Flipped claim 0680 to ✅ done and updated `docs/march-m11.md`.
