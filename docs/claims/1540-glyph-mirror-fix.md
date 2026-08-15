# Claim: issue 125 follow-on — refresh the public site screenshot (corrected glyph capture)

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** GitHub issue #125 — "Framebuffer glyphs are mirrored because font8x8 rows are rasterized MSB-first"
- **Scope:** the public docs screenshot (`site/index.assets/screenshot.png`) still showed the pre-fix boot with mirrored glyphs. Refresh it from a corrected VZ capture and reconcile the docs. The kernel fix itself landed via claim 8742 (PR #129, the shared `font8x8.row_pixel` LSB-first helper) — this claim does NOT duplicate it.
- **Depends on:** claim 8742 (the kernel + decoder + goldens fix, merged on `main` `0d24006`) and the live-glyphs tripwire.
- **Status:** ✅ done 2026-08-15

## What happened

Issue #125 was fixed on `main` by claim 8742 (PR #129): `font8x8.row_pixel`
is the single LSB-first convention, both renderers use it, asymmetric `'C'`
goldens cover the terminal AND window-manager rasters, and the decoder +
offline self-test now sample LSB-first. Independent parallel work on this
branch reached the same root cause (both renderers tested `0x80`/shifted
left against the raw LSB-first table) — the two fixes are compatible.

What claim 8742 did NOT touch: `site/index.assets/screenshot.png`, the
public site's live-boot screenshot, which was captured before the fix and
still showed reversed glyphs. This claim regenerates it from
`artifacts/gpu-screen-15s` — the corrected VZ capture the live-glyphs
tripwire decodes forward (terminal 0/604 unknowns vs 549/595 mirrored;
clock reads `clock` / `DRIVING AWARD`).

## Verification

- `bash tools/verify-live-glyphs.sh` **PASS 1/1** on the fixed kernel:
  fwd_unknowns=0/604, mirrored 549/595, session reads banner + prompt,
  clock overlay decodes `clock` / `DRIVING AWARD` forward.
- The refreshed screenshot is byte-identical to that corrected capture
  (`artifacts/gpu-screen-15s`, 2560×1440 SCK composited window).
- Class A green on the touched docs (coordination indexes in sync,
  `test-coordination` 15/15).

## Evidence

- `artifacts/live-glyphs-gate.txt`, `artifacts/live-glyphs-report.txt`, `artifacts/live-glyphs-run.txt`
- `artifacts/gpu-screen-5s` / `-10s` / `-15s`
- `site/index.assets/screenshot.png` (regenerated from `gpu-screen-15s`)
