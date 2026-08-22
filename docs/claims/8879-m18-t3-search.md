# Claim: M18 T3 — reverse-i-search (Ctrl+R)

- **Owner:** buffy (`agent/buffy/m18-t3-search`)
- **Prompt / plan:** `docs/march-m18.md`
- **Scope:** M18 card T3 — Ctrl+R reverse-i-search through session history + scrollback ring, Enter to accept match, Esc to cancel, host tests + class-B live gate
- **Depends on:** M18 T1 (scrollback ring), M18 T2 (selection)
- **Status:** ✅ done 2026-08-22

## Notes

Implements issue #406 T3: reverse-i-search triggered by Ctrl+R (0x12).

### Features

- **Enter search:** Ctrl+R saves current editor draft, enters search mode,
  shows `(reverse-i-search)` prompt on a new line.
- **Type to match:** each printable char appends to `search_query[0..64]`
  and triggers a search through the editor's session history ring (newest
  first), then the scrollback ring.
- **Live match display:** the matched line is displayed after the search
  prompt and loaded into the editor buffer.
- **Enter accepts:** calls `search_exit(true)` — leaves the matched line
  in the editor, returns to normal prompt mode.
- **Esc cancels:** calls `search_exit(false)` — restores the pre-search
  draft, returns to normal prompt.
- **Ctrl+C cancels:** same as Esc.
- **Backspace:** removes last query char, re-searches.
- **Arrows / Ctrl+L / non-printable:** ignored in search mode (no crash).

### Search algorithm

1. Scan editor history ring (index 0..hist_count-1) for substring match
2. Fall back to scrollback ring lines via `copy_lines()` for substring match
3. Return first match found (history wins over scrollback for recency)

### BSS budget

~328 bytes: `searching` (1), `search_query[64]` (64), `search_query_len`
(8), `search_draft[max_line=257]` (257), `search_draft_len` (8),
`search_draft_cursor` (8).

### Files changed

- **Modified:** `kernel/src/shell.zig` — 5 new Shell fields, search_enter,
  search_handle, search_match, search_redraw, search_exit, 6 new host tests
- **New:** `tools/verify-live-search.sh` — class-B VZ gate

### Verification

- `zig test kernel/src/shell.zig` — 525/525 tests pass (6 new T3 tests)
- `bash tools/verify-unit-tests.sh` — all modules pass
- `zig build test-console` — transcript byte-identical
- `zig build kernel` — kernel builds