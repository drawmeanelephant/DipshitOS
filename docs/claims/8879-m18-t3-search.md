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

### Live-gate evidence (2026-08-22; updated by the arrow-chord follow-up)

`bash tools/verify-live-search.sh` — **class-B PASS 1/1** on real VZ:
`artifacts/live-search-gate.txt`, `live-search-report.txt`,
`live-search-serial-01.log` (banner=1 fill-ready=1 search=1 match=1
done=1 runner-flag=1). The walk now sends ONLY the Ctrl+R entry over
serial (a modifier chord — the activation wall) and types the QUERY and
the Enter-accept through the synthesized keyboard (`--input-chords`,
claim 5093): the search bar re-prints on every chord, so the log's
`(reverse-i-search)`special`: echo special-search-target-777` line proves
the keyboard-typed query found the right history line. The keyboard
Return decodes to LF, which search mode now accepts like CR (the line
editor already treated CR and LF alike — live-gate fix: a synthesized
Return was ignored in search mode). The accepted line + appended marker
submit and run as one echo, whose output carries the done marker.

### Verification

- `zig test kernel/src/shell.zig` — 549/549 tests pass (T3 tests incl. LF-accepts-like-CR)
- `bash tools/verify-unit-tests.sh` — all modules pass
- `zig build test-console` — transcript byte-identical
- `zig build kernel` — kernel builds