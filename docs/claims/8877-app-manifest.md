# Claim: Milestone 13 Card B2 — application identity manifest (APPS.TXT)

- **Owner:** buffy (`agent/buffy/m13-b2-manifest`)
- **Prompt / plan:** `docs/march-m13.md`
- **Scope:** Milestone 13, Card B2 (Issue #152: application identity manifest — APPS.TXT, launcher reads it)
- **Depends on:** Milestone 12 (TCP seam, DNS, capstone apps) — merged via PR #160
- **Status:** 🔄 in progress

## Notes

DESKTOP.BIN hardcodes its `installed_apps` array. This card gives the
launcher a manifest to read instead:

- `image/apps.txt` — the canonical manifest source (`NAME.BIN | Display
  Name | icon-char` per line, `#` comments and blank lines allowed).
- `image/mkfat32.py` gains a `--apps-txt <file>` flag embedding the text
  as `/APPS.TXT` at the ESP volume root (a plain text file, not a DSK1
  program — the positional chain is untouched).
- `image/make-image.sh` + `build.zig` wire the file through.
- `DESKTOP.BIN` (`user/src/desktop.zig`) reads `/esp/APPS.TXT` at startup
  via the M10 file seam (`ui.file_open`/`file_read`/`file_close`), parses
  it into its catalog, and falls back to the hardcoded array only when the
  manifest is missing/unreadable (honest degradation). Prints a
  `desktop: manifest apps=N` marker for the live gate.
- Class-A host tests for the parser (well-formed lines, comments/blank
  lines, malformed fields, entry-count bounds).
- The live desktop gate (`verify-live-desktop.sh`) asserts the manifest
  marker + count and that the launcher list reflects APPS.TXT.
- ADR 0011 amendment documenting the manifest format.

Adding a new `.BIN` after this card = one APPS.TXT line, no recompile.
