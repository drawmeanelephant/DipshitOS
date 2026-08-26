# Claim: M25 Lane A — F1 bulk selection, F2 properties panel

- **Owner:** ox-alpha (`agent/ox-alpha/m25-filemanager-depth`)
- **Prompt / plan:** `docs/march-m25.md` (cards F1, F2; GitHub issues
  #381/#382)
- **Scope:** M25 (file manager depth), Lane A — multi-select state
  machine and batch delete/move in `user/src/file_browser.zig`, plus the
  file-properties readout in the preview pane. Zero new syscall slots;
  uses existing file syscalls per card.
- **Touches:** user/src/file_browser.zig, user/src/fstest.zig, kernel/src/scheduler.zig, host/vm-runner/Sources/VMRunner/main.swift, tools/verify-live-filemanager-bulk.sh, tools/verify-live-filemanager-props.sh
- **Depends on:** M13 mutating FS (delete/rename landed); M17 Dialog +
  ProgressBar widgets (landed); claim 4379's merged selection groundwork
  (PR #561).
- **Heartbeat:** 2026-08-25
- **Status:** ✅ agent/ox-alpha/m25-filemanager-depth — F1+F2 live-gated
  (bulk + props gates PASS on VZ); see log for the stepwise-progress and
  context-menu notes.

## Notes

F1: `selection_bitmap [32]u8` (256 files), Ctrl+click toggle,
Ctrl+A select-all with visible highlight, Del = batch delete behind a
confirmation dialog, Ctrl+M = batch move to prompted target. Progress
via the M17 ProgressBar widget during batch ops.

F2: right-click → Properties renders size/type/path (+ cluster when
readable from the FAT entry) in the preview pane; timestamps shown as
"N/A" per the documented FAT32 short-name limitation.

Verification: host-side unit tests driving `handle_keyboard_event` /
`handle_mouse_events` against synthetic listings (pattern established by
the F11/F12/F16 tests already in the file), portable gates
(fmt/build/test/bss-budget/coordination). Class-B live gates named in
march notes (`verify-live-filemanager-bulk.sh`, `-props.sh`) run if VZ
is available on this host, otherwise reported honestly as not-run.

## Evidence

- (to be filled with artifacts paths / test output)
