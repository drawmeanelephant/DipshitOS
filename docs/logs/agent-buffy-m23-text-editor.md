# Log — `agent/buffy/m23-text-editor`

## 2026-08-24 — claim 7746 filed

Filed claim 7746 for M23 E2–E5 (undo/redo, goto line, multi-file tabs,
syntax coloring). E1+E6 already exist in `user/src/edit.zig` from PR #508.
This branch adds the remaining four cards to the same file.

Starting implementation now.

## 2026-08-24 — E2-E5 implemented, claim 7746 ✅

All four remaining M23 cards implemented in `user/src/edit.zig`:

- **E2 undo/redo**: `UndoRing` (50 deltas, each with old/new text ≤32B).
  Ctrl+Z/Ctrl+Y. Push on insert/backspace/delete-forward/overwrite.
  6 unit tests.
- **E3 goto line**: `GotoPrompt` with 8-digit buffer. Ctrl+G opens,
  Enter jumps, Esc cancels. `goto_line` clamps to last line.
  4 unit tests.
- **E4 multi-file tabs**: `TabArray` (4 EditorTabs, each with own
  FileBuffer + filename + dirty flag). Ctrl+T/W/Tab. Tab bar at top.
  7 unit tests.
- **E5 syntax coloring**: comptime `zig_keywords` table (~40 words).
  `classify_token` + `draw_line_colored` paint per-token colors.
  Only for .zig files. 6 unit tests.

Total: 75/75 host tests pass (was 45). `zig build edit` produces
181KB EDIT.BIN (under 256KB exec_program_max). `zig fmt --check` clean.
Serial markers added for live gate: `edit: undo`, `edit: redo`,
`edit: goto-open`, `edit: goto-ok`, `edit: tab-open`, `edit: tab-close`.

Class-B gate `tools/verify-live-editor.sh` written (execs EDIT.BIN,
sends Ctrl+T/Z/G via input-chords, asserts serial markers).

M23 march tracker updated: all 6 cards now ✅.

2026-08-24 — Class-B live gate PASSED (1/1 boots). Debugging the gate
uncovered three real bugs, all fixed:

1. `image/make-image.sh` + `mkfat32.py`: EDIT.BIN was silently dropped from
   the ESP — `EDIT_ARGS` never built / passed to mkfat32 (no `edit_file`
   positional). resmon/devcons latent-but-reachable? (declared but never
   wired) — probed later. Fix: wired EDIT_ARGS end to end + self-verify
   grep. RESMON only in the spike build; they were already feeding the
   shim.
2. `kernel/src/fat.zig`: `max_chain_clusters = 256` limited reads to 128KiB,
   so exec of a 181KiB EDIT.BIN failed with the misleading `too_large`
   (the error text quotes the 256KiB staging buffer). Raised to 512
   (= 256KiB at spc=1), matching `exec_program_max`; writes stay bounded
   by write_content_max.
3. EDIT.BIN was a DSK1 flat image with 128KiB+ of writable BSS — the
   flat loader maps it read-only, so the app faulted at EL0 on boot.
   Fixed: `g_app` moved to BSS, built as DSK3 segmented via
   `linker-segmented.ld` + `--segments` (the GLOBALS.BIN pattern);
   make-image.sh + mkfat32.py accept DSK1/DSK3 for EDIT.
4. `user/src/edit.zig`: event keycode convention bug — the kernel sends
   `arg0 = keycode (HID usage)`, `arg1 = ASCII`, but all four key
   handlers read the keycode from `arg1`. Swapped; also fixed E6 console
   split usage (0x32→0x35 backtick) and Ctrl+Y (0x15→0x1c).
5. Gate transport: `--input-chords` via the VZ view needs a key window
   (issue #179 activation wall — never key in a scripted session). The
   gate now builds the runner with `-DSPIKE` and runs `--via-virtio`, so
   chords ride the claim-9588 custom-virtio INPUT queue headless-safe;
   `--display` is kept for the GPU (windows) with no view keyboard.

The gate types 'h','i' (so Ctrl+Z has a real edit to undo), then sends
ctrl-z (undo), ctrl-t (tab), ctrl-g (goto). Evidence: artifacts/live-editor-*
(serial logs, report, gate output, editor-screen-{5s,10s,15s} screenshots).
All assertions green: banner, edit-ready, tab-open, undo, goto-open.
