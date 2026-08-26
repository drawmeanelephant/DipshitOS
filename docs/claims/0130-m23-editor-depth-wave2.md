# Claim: M23 editor depth Wave 2 — search/replace, autoindent, bracket match, line numbers, delete line

- **Owner:** Buffy (`agent/buffy/m23-editor-wave2`)
- **Prompt / plan:** `docs/march-m23.md` (cards E7, E8, E9, E11, E22; GitHub issues #346, #347, #348, #350, #361)
- **Scope:** M23 editor depth wave 2:
  - E7 (#346): Search & Replace (Ctrl+F / Ctrl+H with forward search, match count, wrap, replace single/all, undo integration)
  - E8 (#347): Autoindent (preserve leading whitespace on Enter, dedent on `}`)
  - E9 (#348): Bracket matching (highlight matching `()`, `[]`, `{}` pairs)
  - E11 (#350): Line numbers toggle (Ctrl+L toggles gutter on/off)
  - E22 (#361): Delete line (Ctrl+Shift+D deletes current line, recorded in undo ring)
- **Touches:** user/src/edit.zig,docs/march-m23.md
- **Depends on:** E1–E6 (merged on `main`).
- **Status:** ✅ done — 96/96 host tests pass, build clean, live gate `tools/verify-live-editor.sh` PASS on VZ (9/9 assertions)

## Notes

All five features are implemented in pure userland (`user/src/edit.zig`) with zero new syscalls and bounded BSS footprint. Verification includes 96/96 host unit tests covering search/replace, indent/dedent, bracket matching, line number toggling, and line deletion with undo/redo round-tripping. Class-B live hardware gate `tools/verify-live-editor.sh` PASSED (1/1 boots) on real Apple Silicon VZ asserting serial markers `edit: ready`, `edit: undo`, `edit: toggle-lines`, `edit: find-open`, `edit: replace-open`, `edit: delete-line`, `edit: tab-open`, and `edit: goto-open`.
