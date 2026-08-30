# Claim 6156: WMS9 — Surface-seam perf: batched spans / raw-region push for text

- **Owner:** buffy (`agent/buffy/wms9-surface-seam-perf`)
- **Prompt / plan:** issue #629 (WMS9 of 10, phase 4 payoff) —
  `docs/march-m32-wm-migration.md` WMS9 row
- **Scope:** Kill the standing text-perf debt: the toolkit stops issuing one
  1×1 `sys_win_fill` per glyph pixel (64+ fills per 8×8 character in
  `user/src/lib/ui.zig draw_char` and `libui_so.zig`) and switches to batched
  spans / raw-region push on the surface seam. First measure slot 46
  `sys_win_fill_batch` (issue #205) as-is, extend its payload shape rather
  than adding a slot (ABI budget stays at 66). Pixel-identical output is the
  bar: LIBFONT.SO glyph metrics unchanged, all M20 text gates stay green.
  Host tests: span batcher correctness (clipping, wrap, color runs) against
  the mock canvas pattern.
- **Touches:** `user/src/lib/ui.zig`, `user/src/libui_so.zig`,
  `kernel/src/syscall.zig` (slot-46 payload growth if needed),
  `kernel/src/driving_award.zig` (batch handler only), measurement artifact,
  claim + log
- **Depends on:** WMS7 (toolkit re-pointed; seam shape final), WMS8 Gate 6
  (claim 3687)
- **Heartbeat:** 2026-08-30
- **Status:** ✅ done 2026-08-30 (`agent/buffy/wms9-surface-seam-perf`, PRs #674 + #678)

## Result

- `user/src/lib/ui.zig`: zero-alloc `FillBatcher` (static BSS, 32×24 B) +
  `win_fill_batched` + `flush_fills`; `win_present` auto-flushes before
  present. `draw_char` emits one span per contiguous pixel run per row (was
  one 1×1 `sys_win_fill` per set pixel); `draw_char_16` emits one 2px-tall
  span per run; `draw_rect`/`draw_rect_outline` route through the batcher.
- `user/src/libui_so.zig` (stash follow-up, this close-out): dynamically
  linked apps get the same collapse — `ui_draw_char_8x8` → `ui.draw_char`,
  `ui_draw_string` → `ui.draw_text`, `ui_draw_button` borders/background
  through `win_fill_batched`, new `ui_win_fill_batched`/`ui_flush_fills`
  exports, `ui_draw_rect` routed through the batcher.
- Measurement: `artifacts/wms9-fill-reduction.md` — ~39× fewer SVC entries
  on a representative dense 80-char text line; up to 8× fewer per glyph.
- Host tests: 4 new WMS9 tests green (32-rect auto-flush, window-id-change
  flush, 1px spans for 8×8, 2px spans for 8×16); 44/44 ui tests green;
  full `just test` green; `zig build` + `zig fmt --check` clean.
  Pixel-identical output preserved (M20 text gates unaffected).
