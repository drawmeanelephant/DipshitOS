# Claim: M23 editor completeness — all remaining 14 issues for GitHub Milestone 11

- **Owner:** Buffy (`agent/buffy/m23-editor-wave2`)
- **Prompt / plan:** `docs/march-m23.md` (GitHub Milestone 11 issues #349, #351, #352, #353, #354, #355, #356, #357, #358, #359, #360, #362, #363, #364)
- **Scope:** M23 text editor full milestone completeness:
  - E10 (#349): Word wrap in editor
  - E12 (#351): Multiple cursors (basic, up to 8 cursors)
  - E13 (#352): Rectangular selection (column select, copy, paste, typing)
  - E14 (#353): Command palette (Ctrl+Shift+P fuzzy match)
  - E15 (#354): Recent files list (Ctrl+R, 10 recents)
  - E16 (#355): Unsaved changes handling (dirty flag, close guard, Ctrl+S)
  - E17 (#356): Crash recovery (buffer recovery state, restore prompt)
  - E18 (#357): Configurable keybindings (action dispatch table)
  - E19 (#358): Editor themes (Dark, Light, Amber)
  - E20 (#359): Indentation controls (Tab/Shift+Tab, block indent/dedent)
  - E21 (#360): Bookmarks (Ctrl+B, navigation)
  - E23 (#362): Jump to definition (Ctrl+])
  - E24 (#363): File tree sidebar (Ctrl+Shift+F)
  - E25 (#364): Minibuffer & status bar (info messages, layout)
- **Touches:** user/src/edit.zig,docs/march-m23.md,tools/verify-live-editor.sh
- **Depends on:** E1–E9, E11, E22 (merged on `main`).
- **Heartbeat:** 2026-08-26
- **Status:** ✅ done

## Notes

Implements all 14 remaining text editor features in `user/src/edit.zig` with zero new syscalls and bounded BSS footprint. Includes comprehensive host unit tests covering all features and class-B live hardware verification via `tools/verify-live-editor.sh` on Apple Silicon VZ.
