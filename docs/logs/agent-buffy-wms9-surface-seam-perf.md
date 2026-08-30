# Log — agent/buffy/wms9-surface-seam-perf

## 2026-08-30 — WMS9 claimed (issue #629)

- Claimed **WMS9 — Surface-seam perf** as `docs/claims/6156-wms9-surface-seam-perf.md`
  (status 🔄, heartbeat 2026-08-30). Worktree `../dipshitos-buffy`, branch off
  `origin/main` (5a87b2b).
- Plan: measure slot 46 `sys_win_fill_batch` first, extend its payload shape
  (no new slot), port `draw_char`/`draw_char_16`/`draw_rect` onto the batch
  path, keep output pixel-identical, host-test the span batcher, save
  before/after measurements under `artifacts/`.

## 2026-08-30 — WMS9 complete (claim 6156, issue #629)

- Added zero-alloc `FillBatcher` (static BSS, 32×24 B) + `win_fill_batched`
  + `flush_fills` in `ui.zig`; `win_present` auto-flushes before present.
- `draw_char` now emits one span per contiguous pixel run per row (was one
  1×1 fill per set pixel); `draw_char_16` emits one 2px-tall span per run;
  `draw_rect`/`draw_rect_outline` route through the batcher too.
- Measurement: `artifacts/wms9-fill-reduction.md` — ~39× fewer SVC entries
  on a representative dense 80-char text line; up to 8× fewer per glyph.
- Host tests: 4 new WMS9 tests green (32-rect auto-flush, window-id-change
  flush, 1px spans for 8×8, 2px spans for 8×16); full `just test` green;
  `zig build` + `zig fmt --check` clean. Pixel-identity preserved.
