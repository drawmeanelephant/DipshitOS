# Claim 6156: WMS9 — Surface-seam perf: batched spans / raw-region push for text

- **Owner:** buffy (`agent/buffy/wms9-surface-seam-perf`)
- **Prompt / plan:** issue #629 (WMS9 of 10, phase 4 payoff)
- **Scope:** Replace per-pixel `sys_win_fill` (slot 13) in `draw_char`/`draw_char_16`/`draw_rect` with batched spans via slot 46 `sys_win_fill_batch` (payload extended, no new slot). Pixel-identical output; LIBFONT.SO metrics unchanged; M20 text gates stay green.
- **Touches:** `user/src/lib/ui.zig`, `user/src/libui_so.zig`, `kernel/src/syscall.zig`, `kernel/src/driving_award.zig` (batch handler only), measurement artifact, claim + log
- **Depends on:** WMS7 (toolkit re-pointed), WMS8 Gate 6 (claim 3687)
- **Heartbeat:** 2026-08-30
- **Status:** ✅ `agent/buffy/wms9-surface-seam-perf`

**Result:** DONE 2026-08-30. `draw_char`/`draw_char_16`/`draw_rect`/
`draw_rect_outline` re-routed through the new zero-alloc `FillBatcher`
(static BSS, 32×24 B slots) flushing via slot 46 `sys_win_fill_batch` —
no new slot, ABI budget stays at 66. `draw_char` emits one span per
contiguous pixel run per row (vs 1×1 fills per pixel); `draw_char_16`
emits one 2px-tall span per run (keeps the 2× vertical stretch).
`win_present` auto-flushes. Measurement: `artifacts/wms9-fill-reduction.md`
(~39× fewer SVCs on a dense 80-char text line). Host tests: 4 new WMS9
batcher tests green (32-rect auto-flush, window-id-change flush, 1px-tall
spans for 8×8, 2px-tall spans for 8×16), full `just test` green,
`zig build` clean, `zig fmt --check` clean. Pixel-identity preserved:
same glyph table/coordinates, LIBFONT.SO untouched.
