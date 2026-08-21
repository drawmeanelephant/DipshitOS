# Claim: fix issue #125 — correct framebuffer glyph bit order

- **Owner:** Codex (`freebuff/can-you-figure-out-why-the-text-is-getting-flipped-8600521b-d8d1-4667-a3e8-d2fa10b4ff03`)
- **Prompt / plan:** GitHub issue [#125](https://github.com/drawmeanelephant/DipshitOS/issues/125) — render Daniel Hepper's `font8x8` rows with their documented LSB-first convention, repair the orientation oracle, and prove the terminal plus Driving Award clock text live on VZ.
- **Scope:** `kernel/src/font8x8.zig`, `kernel/src/text.zig`, `kernel/src/driving_award.zig`, `tools/decode-screen-glyphs.py`, the targeted glyph tests/gate, and pointer-level status/gate documentation after verification. No framebuffer transport, layout, syscall, or later-milestone work.
- **Depends on:** merged milestone-six graphics/window paths on `origin/main` `3013b174fda120b60db9de6b990335d04e8216ab`; issue #125 diagnosis.
- **Status:** ✅ done 2026-08-14 — both kernel paths share the LSB-left source-bit helper; independent asymmetric goldens cover the oracle; portable verification and the targeted VZ/ScreenCaptureKit terminal + clock gate passed.

## Notes

At claim opening, the imported font rows were LSB-first (bit 0 is the
first/leftmost pixel), but both kernel rasters tested bit 7 and shifted
left. The existing decoder and offline self-test repeated that convention,
so they called the mirrored raster "forward"; the only terminal golden
used horizontally symmetric `!`. The claim therefore covered independent
asymmetric goldens, the portable suite, and a live
`tools/verify-live-glyphs.sh` terminal + clock capture under `artifacts/`.

Completed with `font8x8.row_pixel` as the single kernel-side convention.
The terminal's asymmetric `C` golden proves its left edge directly, the
Driving Award renderer has its own asymmetric `C` path test, and the
decoder carries a separate hard-coded source-row/screen-row `C` golden.
The portable verification passed (exact `just verify-portable` recipe run
directly because `just` is unavailable on this host). The live VZ gate
then decoded the ScreenCaptureKit frame forward with 0/604 unknown
terminal glyphs versus 549/595 mirrored; the clock decoded exactly as
`clock` / `DRIVING AWARD`, versus 4/5 and 10/13 unknowns mirrored.
Evidence: `artifacts/issue-125-targeted-tests.txt`,
`artifacts/issue-125-verify-portable.txt`,
`artifacts/live-glyphs-gate.txt`, and `artifacts/gpu-screen-15s`.
