# Claim: glyph raster convention — a named class-A gate with a mutation check (issue 125 hardening)

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** "Wire the glyph self-test and the new raster goldens into the CI workflow so a table edit or bit-order flip fails on every push, not just in the local class-A aggregate"
- **Scope:** the issue-125 raster goldens (claim 9263) and the offline mirror self-test already ran inside the broad `verify-unit-tests.sh` aggregate and a bare CI line, but there was no NAMED gate for the glyph-raster contract, and nothing proved the goldens actually FAIL when the convention reverses. Add `tools/verify-glyph-raster.sh` — a dedicated class-A gate — and wire it into `just verify-portable` + GitHub CI.
- **Depends on:** claim 9263 (full-table goldens: `font8x8` fingerprint + asymmetry census, `text.zig`/`driving_award.zig` full-95-glyph round-trips), claim 8742 (the LSB-first fix itself).
- **Status:** ✅ done 2026-08-15

## What the gate proves

The issue-125 lesson: a golden that derives its expectation from the code
under test cannot catch a regression (the old decoder sampled into bits
7→0 and matched the raw LSB-first byte — self-consistent with the mirrored
kernel). The full-table goldens read the RAW table bits inline, but they
only catch a flip if they are actually run AND actually fail when the
convention reverses. This gate makes both facts mechanical:

1. **Runs the three glyph-bearing modules explicitly** (`font8x8`,
   `text`, `driving_award`) — the broad aggregate also runs them, but a
   glyph-raster regression now fails under a NAMED, attributable gate.
2. **Runs the offline in-cell mirror self-test**
   (`decode-screen-glyphs.py --self-test`).
3. **Mutation check:** temporarily reverses `font8x8.row_pixel` to
   MSB-first and re-runs the module tests, REQUIRING every golden to fail
   (the file is restored afterwards). If the goldens do NOT fail against
   the reversed convention, the gate fails — a golden that cannot detect
   the bug it exists for is worse than no golden.

## Wiring

- `tools/verify-glyph-raster.sh` (new, class A, deterministic).
- `justfile` `verify-portable`: the bare `python3 … --self-test` line is
  replaced by the gate (the gate includes the self-test — no duplication).
- `.github/workflows/ci.yml`: the CI step now runs the gate (the class-A
  set is exactly `just verify-portable`).
- `docs/gate-inventory.md`: `glyph-raster` rows in the human table + the
  machine-readable records (`class=A ci=yes`).

## Verification

- `bash tools/verify-glyph-raster.sh` **PASS** locally: all three module
  suites green, offline self-test PASS, and the mutation leg proves all
  three goldens fail against a reversed `row_pixel` (then restores the
  file — `git status` clean afterwards).
- The mutation leg was validated both ways: with the correct convention
  the goldens pass; with the reversed convention they fail (the acceptance
  proof of the gate itself).
- Class A suite remains green (the gate replaces the self-test line in the
  same aggregate; fmt + unit-tests + transcript unchanged).
- CI (GitHub Actions) will run the gate on every push/PR to `main` — a
  table edit or bit-order flip in the font data or either renderer now
  fails the build, not just the local class-A run.
