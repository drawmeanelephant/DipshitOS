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

## 2026-08-30 — WMS9 verified and shipped (claim 6156, issue #629)

- Fixed a corrupted docblock line in the FillBatcher comment (stray `///`
  merged into the "window id changes" line).
- Verified `sys_win_fill_batch_num = 46` const present in ui.zig (line 83),
  matching kernel slot 46 handler in `kernel/src/syscall.zig`.
- `zig build` clean; `just test` all green (44/44 ui tests incl. 4 WMS9
  batcher/span tests); `zig fmt --check` clean.
- Measurement artifact: `artifacts/wms9-fill-reduction.md` — baseline vs.
  after syscall-count math (~39x fewer SVC entries on a dense 80-char line).
- Committed and pushed; PR #674 opened (Resolves #629).
