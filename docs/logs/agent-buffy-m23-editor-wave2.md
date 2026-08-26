# Log — `agent/buffy/m23-editor-wave2`

## 2026-08-25 — claim 0130 filed for M23 Wave 2 editor depth

Filed claim 0130 for M23 text editor depth Wave 2 (E7 search/replace, E8 autoindent,
E9 bracket matching, E11 line numbers toggle, E22 delete line). Cards E1–E6 are
already merged on `main`.

Starting implementation in `user/src/edit.zig`.

## 2026-08-25 — E7, E8, E9, E11, E22 implemented & verified live, claim 0130 ✅

All five Wave 2 M23 text editor depth features implemented in `user/src/edit.zig`:

- **E7 Search & Replace (#346):** `FindPrompt` overlay with `open_find` (Ctrl+F)
  and `open_replace` (Ctrl+H). Case-insensitive search algorithms (`match_at_ci`,
  `count_matches_ci`, `find_next_ci`, `find_prev_ci`), single match replace with
  undo integration (`replace_current_match`), and replace-all (`replace_all_matches`).
  Paint pass renders match highlight rectangles across visible lines.
- **E8 Autoindent & Dedent (#347):** `FileBuffer.insert_newline_autoindent` copies
  leading indentation of current line onto the new line. `insert_char_with_dedent`
  automatically dedents 4 spaces when typing closing brace `}` on a whitespace-only
  line.
- **E9 Bracket Matching (#348):** `find_matching_bracket` forward/backward scan
  handling nested parentheses `()`, brackets `[]`, and braces `{}`. Paint pass
  renders a contrasting outline box over matching pair.
- **E11 Line Numbers Toggle (#350):** `AppState.show_line_numbers` toggled via
  Ctrl+L (`0x0f`), adjusting effective gutter width between 28px and 0px and
  expanding editor area.
- **E22 Delete Line (#361):** `FileBuffer.delete_current_line` triggered via
  Ctrl+Shift+D (`0x07`), cleanly slicing out the entire line and newline into
  the `UndoRing`.

### Verification

- Unit Tests: `zig test user/src/edit.zig` — **96/96 tests pass** (was 75; 21 new unit tests for Wave 2 features).
- Formatting: `zig fmt --check user/src/edit.zig` is clean.
- Build: `zig build` and `zig build image` succeed cleanly (`EDIT.BIN` 213,040 bytes embedded into `artifacts/disk.img`).
- Coordination: `tools/verify-coordination.sh` passes cleanly (`ok`).
- Class-B Hardware Gate: `tools/verify-live-editor.sh` **PASS 1/1 boots** on Apple Silicon VZ hardware:
  - 9/9 assertions green: `banner=1`, `edit-ready=1`, `undo=1`, `lines=1`, `find=1`, `repl=1`, `del=1`, `tab=1`, `goto=1`.

## 2026-08-26 — M23 Text Editor Completeness Wave 3 (Claim 4341)

Implemented all 14 remaining cards for Milestone 23 (issues #349, #351–#360, #362–#364):

- **E10 (#349) Word Wrap:** Real viewport word wrapping across column boundaries without altering underlying buffer.
- **E12 (#351) Multiple Cursors:** Multi-cursor simultaneous typing & deletion with stable coordinate shifting across all sibling cursors.
- **E13 (#352) Rectangular Selection:** `Alt+R` column selection mode, rectangular cursor bounding box, and block typing/fill.
- **E14 (#353) Command Palette:** `Ctrl+Shift+P` fuzzy search overlay with 23 action items.
- **E15 (#354) Recent Files:** `Ctrl+R` MRU picker for up to 10 files, opening cleanly into tabs.
- **E16 (#355) Unsaved Changes Handling:** Dirty flag tracking, close confirmation modal on `Ctrl+W` / palette `.close_tab`, abort on untitled save failures, `Ctrl+S` save.
- **E17 (#356) Crash Recovery:** Persistent `/data/EDIT_REC.TXT` recovery file writing and startup restore prompt (`[R] to restore`).
- **E18 (#357) Configurable Keybindings:** `KeyAction` enum and unified `execute_key_action` dispatcher.
- **E19 (#358) Editor Themes:** Dark, Light, and Amber palettes with `Ctrl+Shift+T` cycle.
- **E20 (#359) Indentation Controls:** Tab indent / Shift+Tab dedent with dirty flag accuracy.
- **E21 (#360) Bookmarks:** `Ctrl+B` toggle, gutter `*` indicator, `Ctrl+Shift+Down/Up` navigation.
- **E23 (#362) Jump to Definition:** `Ctrl+]` identifier resolution and definition jump.
- **E24 (#363) File Tree Sidebar:** `Ctrl+Shift+F` directory explorer with interactive arrow navigation and Enter to open files.
- **E25 (#364) Minibuffer & Status Bar:** Dynamic status bar with wrap, mode, hints, and transient feedback.

### Verification

- Unit tests: `zig test user/src/edit.zig` all pass.
- Live hardware gate: `tools/verify-live-editor.sh` passes on Apple Silicon VZ with all assertions.
- Coordination: `tools/verify-coordination.sh` ok.
