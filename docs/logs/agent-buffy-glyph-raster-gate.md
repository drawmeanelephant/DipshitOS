# Log — glyph raster convention gate (claim 9100)

**Branch:** `agent/buffy/glyph-raster-gate`

- **2026-08-15** — *buffy*: after claim 9263's full-table goldens landed,
  the glyph raster convention still had no NAMED gate and no automated
  proof that the goldens actually FAIL on a flip. Added
  `tools/verify-glyph-raster.sh` (class A): runs font8x8/text/driving_award
  explicitly, the offline in-cell mirror self-test, and a mutation check
  that temporarily reverses `font8x8.row_pixel` to MSB-first and requires
  every golden to fail (restored afterwards). Wired into `just
  verify-portable` (replacing the bare self-test line) and CI, and
  registered `glyph-raster` in the gate inventory (human + machine rows).
- Verified locally: gate PASS end to end; mutation leg proven both ways
  (goldens pass with the correct convention, fail with the reversed one);
  worktree clean after the mutation restore.
