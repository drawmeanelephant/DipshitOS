# Claim: M18 T2 — scrollback text selection & clipboard copy/paste

- **Owner:** buffy (`agent/buffy/m18-t2-selection`)
- **Prompt / plan:** `docs/march-m18.md`
- **Scope:** M18 card T2 — scrollback selection with Up/Down arrows, Ctrl+C copy to clipboard, Ctrl+V paste at prompt, Esc cancel selection, host tests + class-B live gate
- **Depends on:** M18 T1 (scrollback ring)
- **Status:** ✅ done 2026-08-22

## Notes

Implements issue #405 T2: text selection from the scrollback and copy/paste 
through the M14 shared kernel clipboard (slots 38/39).

### Features

- **Selection mode:** entered automatically when PageUp scrolls into the 
  scrollback. `selecting` flag tracks state, `sel_start`/`sel_end` track 
  the line range (offsets from newest).
- **Up/Down arrows:** in selection mode, intercepted by the CSI tracker 
  (state 2, 'A'/'B' finals). Up extends selection upward, Down shrinks 
  toward live; when sel_start == sel_end, Down exits selection.
- **Ctrl+C in selection:** builds the selected text from scrollback lines 
  by calling `scrollback.copy_lines()`, joins with newlines, stores via 
  `clipboard.set()`, prints "copied", and returns to live mode.
- **Enter in selection:** same as Ctrl+C — copies and returns to live.
- **Lone Esc in selection:** cancelled via the CSI state machine (state 1, 
  byte ≠ '[') → calls `selection_cancel()`.
- **Ctrl+V at prompt:** not in selection mode → reads clipboard via 
  `clipboard.get()` and feeds each byte to the line editor.
- **Ctrl+V while selecting:** suppressed (guard: `!self.selecting`).

### ESC handling

The ESC byte (0x1B) must pass through the selection mode guard and reach 
the CSI tracker so Up/Down arrows work. The CSI state machine handles 
differentiation:
- ESC + '[' → CSI sequence (state 2, await final)
- ESC + anything else → lone ESC → cancel selection if selecting

### BSS budget

~208 bytes: `selecting` (1), `sel_start` (8), `sel_end` (8), temp buffers 
in selection_copy (stack).

### Files changed

- **Modified:** `kernel/src/shell.zig` — clipboard import, selection state 
  fields, CSI tracker modifications, poll() intercept for Ctrl+C/Enter/ 
  Ctrl+V, selection_copy_and_exit, selection_cancel, paste_clipboard, 
  6 new host tests
- **New:** `tools/verify-live-selection.sh` — class-B VZ gate

### Verification

- `zig test kernel/src/shell.zig` — 519/519 tests pass (6 new T2 tests)
- `bash tools/verify-unit-tests.sh` — all modules pass
- `zig build test-console` — transcript byte-identical
- `zig build kernel` — kernel builds