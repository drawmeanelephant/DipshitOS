# Claim: milestone six follow-on — full-table raster goldens for the font8x8 convention (issue 125 hardening)

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** "Extend the class-A raster goldens beyond 'C' to cover all horizontally asymmetric glyphs (F, L, R, /, (, ), etc.) so any bit-order regression in the font table or renderers fails immediately"
- **Scope:** after issue 125's fix (claim 8742), the only glyph goldens were hand-written `'C'` spot checks. Extend the class-A proof to the FULL 95-glyph table: every printable glyph rasterized pixel-exact, plus a table-integrity fingerprint and an asymmetry census, so ANY bit-order regression — in the `row_pixel` helper, either renderer, or the table data itself — fails immediately.
- **Depends on:** claim 8742 (the LSB-first fix + `font8x8.row_pixel` shared helper, merged on `main` `0d24006`).
- **Status:** ✅ done 2026-08-15

## Why the round-trip must read the RAW table bits

The first cut of these goldens compared each rendered pixel against
`font.row_pixel(...)` — which was **self-consistent with the helper under
test**: reversing `row_pixel` made both the renderer AND the expectation
agree, so the round-trip stayed green (the exact trap issue 125 documented
in the old decoder). A mutation test proved it. The goldens therefore
compute the expected bit **inline from the raw table byte** —
`(row >> x) & 1` — independent of the helper, so a reversal of
`row_pixel`, the terminal raster, OR `draw_glyph` breaks 90 of 95 glyphs.

## The goldens

1. **`font8x8.zig` — table fingerprint.** FNV-1a 64 over all 760 glyph rows
   is pinned (`0x177af966bd854d6d`): ANY edit to the table — a wholesale
   bit-reversal, one flipped row, a stray byte — changes the fingerprint.
   This pins the SOURCE data (the round-trips pin the renderers).
2. **`font8x8.zig` — asymmetry census.** Exactly 90 of 95 glyphs are
   horizontally asymmetric; the only symmetric ones are ` !*_|`. This
   proves the full-table round-trips are decisive (a bit flip breaks
   90/95 cells) and guards against a future table "simplification" that
   happens to make glyphs symmetric.
3. **`text.zig` — full-table round-trip.** Every one of the 95 printable
   glyphs is rendered into the test canvas and all 64 pixels are asserted
   against the raw source bits. Replaces the `'!'`-style single-glyph
   coverage with the complete set.
4. **`driving_award.zig` — full-table round-trip through `draw_glyph`.**
   The same 95 × 64 assertion over the window-manager raster, so the two
   renderer paths cannot drift from each other or from the convention.

## Verification

- **Mutation-tested (the acceptance proof):** with `row_pixel` temporarily
  reversed to MSB-first, BOTH full-table round-trips and the existing
  `'C'` goldens fail; the table fingerprint stays green (it pins the data,
  not the helper); the `font8x8` source-rows test fails. Reverted after.
- **Class A:** `zig fmt --check`, 40-module unit aggregate (font8x8 3,
  text 26, driving_award 39 — 405 total console tests, up from 401),
  `zig build test-console` byte-identical transcript, `zig build` all green.
- No class-B needed (the live-glyphs tripwire already covers the corrected
  rendering; these are pure host raster proofs).
