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
| E1 | **EDIT.BIN — the text editor.** Full-screen editor with line numbers in the left gutter, cursor movement (arrows, Home/End, PgUp/PgDn), insert/overwrite mode toggle (Insert key), and a status bar (line:col, file name, modified flag). Opens from FILE.BIN via "Open in editor" context menu or `exec EDIT.BIN filename.BIN`. | ✅ | PR #508 (commit `ee3da3e`) — `edit: ready` on VZ | New userland app `user/src/edit.zig`. Uses `ui.zig` toolkit. BSS: file buffer (32 KiB max), line index array (4 KiB), cursor state, status bar state. Renders as a full-window app with the editor area taking the full window minus the 16px status bar. |
| E2 | **Undo/redo.** Bounded undo stack (last 50 operations). Ctrl+Z undo, Ctrl+Y redo. Each operation is a BSS delta record: position + old text + new text (bounded: max 32 bytes per delta). Undo stack resets on file open. | ✅ | claim 7746: 75/75 host tests pass; `zig build edit` 181KB; live gate `tools/verify-live-editor.sh` PASS 1/1 on VZ (`edit: undo` serial marker confirmed) | `edit.zig` BSS `UndoRing` (50 deltas × 76 bytes). Delta stores: pos, old_text[32], new_text[32], old_len, new_len. Push on insert_char/backspace/delete_forward/overwrite_char. New edits clear redo stack. 6 undo unit tests. |
| E3 | **Goto line.** Ctrl+G opens a small input prompt at the bottom. Enter jumps to that line number. Shows "Line X of Y" in the status bar. Invalid line number clamps to last line. | ✅ | claim 7746: 75/75 host tests pass; live gate `tools/verify-live-editor.sh` PASS 1/1 on VZ (`edit: goto-open` serial marker confirmed) | `GotoPrompt` state (8-byte digit buffer, active flag). Ctrl+G opens, Enter parses + jumps, Esc cancels. Digits only; `goto_line` clamps to last line. 4 goto unit tests. |
| E4 | **Multi-file tabs.** Ctrl+T opens a new empty file tab. Ctrl+W closes the current tab (prompts if unsaved). Ctrl+Tab switches to the next tab. Tab bar at the top showing filenames (max 4 tabs). Each tab has its own buffer and cursor state. | ✅ | claim 7746: 75/75 host tests pass; live gate `tools/verify-live-editor.sh` PASS 1/1 on VZ (`edit: tab-open` serial marker confirmed) | `TabArray` (4 × EditorTab, each with own FileBuffer + filename + dirty flag). Ctrl+T/W/Tab. Tab bar drawn at top. 7 tab unit tests. Image 181KB (under 256KB exec limit). |
| E5 | **Syntax coloring (minimal).** Zig keywords highlighted in a different color (blue for keywords, green for strings, yellow for comments). `.zig` files get basic syntax awareness: keyword scanner looks up comptime keyword table. Other files are plain white text. | ✅ | claim 7746: 75/75 host tests pass; `classify_token` unit tests for keyword/string/comment/plain; live gate `tools/verify-live-editor.sh` PASS 1/1 on VZ (editor runs with .zig tab, syntax coloring active) | Comptime `zig_keywords` table (~40 keywords). `classify_token` scans a token boundary, `draw_line_colored` paints per-token colors during the render pass. Only active when the tab's filename ends `.zig`. 6 syntax unit tests. |
| E6 | **Console integration.** Ctrl+` splits the editor vertically — bottom 40% shows the shell. Run commands without leaving the editor. The shell output appears in the bottom pane. Ctrl+` again closes the split. | ✅ | PR #508 (commit `ee3da3e`) — `MiniShell` with echo/help/clear/put/line builtins | `edit.zig` `MiniShell` struct. Ctrl+` (keycode 0x32) toggles a bottom 40% pane. Builtins: echo, help, clear, put, save, load, pwd, line, exec, cat, ls. Output scrolls with PageUp/Down. |
| E7 | **Search & replace.** Ctrl+F find bar, Ctrl+H find & replace. Case-insensitive forward/backward scan, match counter, wrap-around, and replace single / replace all integrated with undo ring. | ✅ | claim 0130: 96/96 host tests pass; live gate `tools/verify-live-editor.sh` PASS on VZ (`edit: find-open`, `edit: replace-open` serial markers confirmed) | `FindPrompt` overlay. Ctrl+F opens search, Ctrl+H opens replace. Enter finds next / replaces, Tab toggles field, Ctrl+A replaces all. Paint pass highlights all occurrences. |
| E8 | **Autoindent & dedent.** Enter preserves leading whitespace on the new line; typing `}` on whitespace-only line dedents by one tab level. | ✅ | claim 0130: 96/96 host tests pass; unit tests for spaces, tabs, and brace dedent | `FileBuffer.insert_newline_autoindent` and `insert_char_with_dedent`. Preserves indentation seamlessly without dynamic allocation. |
| E9 | **Bracket matching.** Visual highlight for matching `()`, `[]`, `{}` pair when cursor is on or adjacent to a bracket character. | ✅ | claim 0130: 96/96 host tests pass; unit tests for nested parentheses, brackets, and braces | `find_matching_bracket` forward/backward scan with nesting depth tracking. Paint pass draws accent outline around matching bracket character. |
| E11 | **Line numbers toggle.** Ctrl+L toggles line number gutter on/off, expanding editor text area to full width when hidden. | ✅ | claim 0130: 96/96 host tests pass; live gate `tools/verify-live-editor.sh` PASS on VZ (`edit: toggle-lines` serial marker confirmed) | `AppState.show_line_numbers`. Ctrl+L toggles gutter width between 28px and 0px. |
| E22 | **Delete line.** Ctrl+Shift+D deletes the entire current line including newline, placing the deletion into the undo stack. | ✅ | claim 0130: 96/96 host tests pass; live gate `tools/verify-live-editor.sh` PASS on VZ (`edit: delete-line` serial marker confirmed) | `FileBuffer.delete_current_line`. Slices out current line, clamps cursor, records delta in `UndoRing`. |

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
