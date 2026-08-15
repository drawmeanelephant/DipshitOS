# Log — issue 125 follow-on: refresh the public site screenshot

**Branch:** `agent/buffy/glyph-mirror-fix`
**Claim:** 1540

- **2026-08-15** — *buffy*: root-caused issue #125 independently (font8x8 is
  raw upstream LSB-first data; both renderers tested `0x80`/shifted left,
  mirroring asymmetric glyphs; the decoder was self-consistent with the
  bug). Before this branch merged, claim 8742 (PR #129) landed the same fix
  on `main` with the cleaner shared `font8x8.row_pixel` helper — so the
  kernel/decoder/goldens work here was dropped as redundant after rebasing
  onto `main`.
- The one remaining mirrored artifact on `main` was the PUBLIC site
  screenshot (`site/index.assets/screenshot.png`, captured pre-fix).
  Regenerated it from `artifacts/gpu-screen-15s` — the corrected VZ capture
  that `verify-live-glyphs.sh` decodes forward (0/604 terminal unknowns,
  clock reads `clock`/`DRIVING AWARD`).
- Verified: `verify-live-glyphs.sh` PASS 1/1 on the fixed kernel; class A
  coordination green.
