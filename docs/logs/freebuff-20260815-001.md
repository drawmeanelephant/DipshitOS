# Log — freebuff/can-you-figure-out-why-the-text-is-getting-flipped (issue #125 glyph orientation)

- **2026-08-14 (claim 8742 opened):** fast-forwarded the clean worktree
  from `0fcd96b` to current `origin/main` `3013b17`; confirmed GitHub issue
  #125 remains open/unassigned and found no overlapping claim. Claimed the
  LSB-first glyph correction across the terminal, Driving Award clock,
  decoder/self-test, asymmetric goldens, and the targeted live VZ glyph
  gate. No renderer code was edited before this claim/log entry.

- **2026-08-14 (claim 8742 complete):** centralized Daniel Hepper font-row
  sampling as LSB-left in `font8x8.row_pixel` and moved both the Road Pops
  terminal and Driving Award clock rasterizers onto it. Repaired the
  decoder's source-to-screen normalization and added independent,
  asymmetric `C` goldens so the oracle cannot simply repeat the renderer's
  bit-order mistake. Targeted Zig tests, the decoder self-test, and the
  direct `verify-portable` recipe passed (`just` itself is unavailable on
  this host). The targeted VZ/ScreenCaptureKit gate passed with terminal
  forward 0/604 unknown glyphs versus 549/595 mirrored and exact clock
  `clock` / `DRIVING AWARD` versus 4/5 and 10/13 mirrored unknowns; the
  captured image was also inspected directly and both text paths read
  normally. Evidence is under `artifacts/issue-125-*`,
  `artifacts/live-glyphs-*`, and `artifacts/gpu-screen-15s`.
