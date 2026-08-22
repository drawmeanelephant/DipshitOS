# Milestone twenty-three march — the text editor (living tracker)

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts. This file holds M23's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

NOTEPAD exists (M11 A3, M17 C5/C6) — it's a basic text viewer with word
wrap, find/replace, and cursor blink. But it's not a *text editor*. No
undo, no goto-line, no multi-file support, no syntax awareness. A developer
writing code on DipshitOS needs an editor, not a notepad. M23 builds one.

**Zero new syscall slots.** EDIT.BIN is a pure userland app that uses the
existing toolkit, event system, and file syscalls.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| E1 | **EDIT.BIN — the text editor.** Full-screen editor with line numbers in the left gutter, cursor movement (arrows, Home/End, PgUp/PgDn), insert/overwrite mode toggle (Insert key), and a status bar (line:col, file name, modified flag). Opens from FILE.BIN via "Open in editor" context menu or `exec EDIT.BIN filename.BIN`. | ⬜ | — | New userland app `user/src/edit.zig`. Uses `ui.zig` toolkit. BSS: file buffer (32 KiB max), line index array (4 KiB), cursor state, status bar state. Renders as a full-window app with the editor area taking the full window minus the 16px status bar. |
| E2 | **Undo/redo.** Bounded undo stack (last 50 operations). Ctrl+Z undo, Ctrl+Y redo. Each operation is a BSS delta record: position + old text + new text (bounded: max 32 bytes per delta). Undo stack resets on file open. | ⬜ | — | `edit.zig` BSS undo ring (50 × 48 bytes = 2,400 bytes). Each delta stores: cursor position (4 bytes), old text length (2), new text length (2), old text (≤32 bytes), new text (≤32 bytes). Operations: insert char, delete char, insert line, delete line. |
| E3 | **Goto line.** Ctrl+G opens a small input prompt at the bottom. Enter jumps to that line number. Shows "Line X of Y" in the status bar. Invalid line number clamps to last line. | ⬜ | — | `edit.zig` goto state. Uses `ui.zig` TextInput widget for the prompt. |
| E4 | **Multi-file tabs.** Ctrl+T opens a new empty file tab. Ctrl+W closes the current tab (prompts if unsaved). Ctrl+Tab switches to the next tab. Tab bar at the top showing filenames (max 4 tabs). Each tab has its own buffer and cursor state. | ⬜ | — | `edit.zig` tab BSS (4 × (32 KiB buffer + 4 KiB line index + cursor + dirty flag + filename) = ~150 KiB). This is the largest BSS consumer — review against budget. Tabs are stored as a fixed array; closing a tab compacts the array. |
| E5 | **Syntax coloring (minimal).** Zig keywords highlighted in a different color (blue for keywords, green for strings, yellow for comments). `.zig` files get basic syntax awareness: keyword scanner looks up comptime keyword table. Other files are plain white text. | ⬜ | — | `edit.zig` keyword scanner + `text.zig` color attribute. Comptime keyword table (~30 Zig keywords). The scanner runs during paint, not on every keystroke. Color is applied as a paint attribute during the glyph rendering pass. |
| E6 | **Console integration.** Ctrl+` splits the editor vertically — bottom 40% shows the shell. Run commands without leaving the editor. The shell output appears in the bottom pane. Ctrl+` again closes the split. | ⬜ | — | `edit.zig` + shell pipe to a child window. The bottom pane is a regular `Kind.window` that receives keyboard input when focused. The split is managed by `edit.zig`'s layout state. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Editor core** | `user/src/edit.zig` for E1 (base editor), E2 (undo/redo), E3 (goto), E4 (multi-file tabs). Sequential: E1 → E2 → E3 → E4. | M20 done (font sizes for gutter). |
| **B — Editor polish** | `user/src/edit.zig` for E5 (syntax coloring) + E6 (console split). | E1 (base editor must exist). |

## Notes

1. **ABI budget:** Zero new syscall slots. EDIT.BIN uses existing file
   syscalls (open/read/write/close), event syscalls (poll/wait), and
   window syscalls (open/fill/present).
2. **BSS budget:** Base editor ~36 KiB. Undo ring ~2.4 KiB. Multi-file tabs
   ~150 KiB (4 × 36 KiB buffers). This is significant — the total kernel
   + userland BSS for EDIT.BIN is ~188 KiB. Review against the process
   BSS limit. If 4 tabs are too expensive, reduce to 2 tabs (E4 budget
   drops to ~72 KiB).
3. **Gate shape:** E1: `verify-live-editor-basic.sh` — open, type, save, close.
   E2: `verify-live-editor-undo.sh` — undo/redo round-trip. E3:
   `verify-live-editor-goto.sh` — goto line jumps correctly. E4:
   `verify-live-editor-tabs.sh` — multi-file tab open/close/switch. E5:
   `verify-live-editor-syntax.sh` — Zig keywords colored. E6:
   `verify-live-editor-console.sh` — shell split opens and runs commands.
4. **File format:** EDIT.BIN works on raw binary files (the flat image format)
   and treats them as newline-delimited text. No encoding conversion —
   the file is read byte-by-byte, newlines (0x0A) are line terminators.
   No CR/LF normalization.
5. **Scope exclusions:** No syntax tree / LSP. No regex search. No
   vertical split. No collaborative editing. No macro recording. This
   is a *small* editor for a *small* OS — it should feel like ed, not
   Emacs.
