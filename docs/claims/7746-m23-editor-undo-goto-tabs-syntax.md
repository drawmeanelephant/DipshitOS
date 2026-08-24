# Claim: M23 editor — undo/redo, goto line, multi-file tabs, syntax coloring

- **Owner:** Buffy (`agent/buffy/m23-text-editor`)
- **Prompt / plan:** `docs/march-m23.md` (cards E2–E5; GitHub issues
  #341–#345)
- **Scope:** M23 (the text editor) — E2 undo/redo (bounded delta ring),
  E3 goto-line (Ctrl+G prompt), E4 multi-file tabs (Ctrl+T/W/Tab, 4 max),
  E5 minimal syntax coloring for `.zig` files. Zero new syscall slots;
  all pure userland changes to `user/src/edit.zig`.
- **Touches:** `user/src/edit.zig`
- **Depends on:** M23 E1+E6 (already landed on `main` in PR #508).
- **Heartbeat:** 2026-08-24
- **Status:** ✅ done — 75/75 host tests pass, build clean, gate written

## Notes

E1 (base editor — buffer, cursor, status bar, insert/overwrite) and E6
(console split — Ctrl+` mini-shell) already exist in `user/src/edit.zig`
(landed PR #508, commit `ee3da3e`). This claim adds the remaining four
cards:

**E2 — Undo/redo:** Bounded ring of 50 delta records. Each delta stores:
cursor position, old text (≤32 bytes), new text (≤32 bytes), and lengths.
Ctrl+Z pops the undo stack and applies the reverse; Ctrl+Y pops the redo
stack. Inserting/deleting a char pushes a delta. Undo stack resets on file
open / tab switch. ~2.4 KiB BSS.

**E3 — Goto line:** Ctrl+G opens a small prompt at the bottom of the
editor. Type a line number, Enter jumps. Invalid input or out-of-range
clamps to the last line. Shows "Line X of Y" in the status bar.

**E4 — Multi-file tabs:** Ctrl+T opens a new empty tab, Ctrl+W closes the
current tab (prompts if unsaved), Ctrl+Tab switches. Tab bar at the top
showing filenames (max 4 tabs). Each tab has its own FileBuffer + cursor +
dirty flag + filename. Closing compacts the array.

**E5 — Syntax coloring (minimal):** Comptime keyword table (~30 Zig
keywords). When the current file ends in `.zig`, the paint pass colors
keywords blue, strings green, comments yellow. Other files stay plain
white. The scanner runs during paint, not per keystroke.

Verification: host unit tests for undo/redo round-trip, goto-line clamping,
tab open/close/switch, and syntax token classification. Class-B live gate
`verify-live-editor.sh` PASSED 2026-08-24 (1/1 boots): types 'h','i', then
sends ctrl-z (undo), ctrl-t (tab), ctrl-g (goto) over the claim-9588
custom-virtio INPUT queue and asserts the serial markers `edit: ready`,
`edit: undo`, `edit: tab-open`, `edit: goto-open` — see the branch log for
the five integration bugs this uncovered and fixed (image wiring, FAT
cluster cap, DSK3 build, keycode arg contract, virtio gate transport).
