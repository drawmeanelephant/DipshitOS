# Log — agent/buffy/wms9-surface-seam-perf

## 2026-08-30 — WMS9 claimed (issue #629)

- Claimed **WMS9 — Surface-seam perf** as `docs/claims/6156-wms9-surface-seam-perf.md`
  (status 🔄, heartbeat 2026-08-30). Worktree `../dipshitos-buffy`, branch off
  `origin/main` (5a87b2b).
- Plan: measure slot 46 `sys_win_fill_batch` first, extend its payload shape
  (no new slot), port `draw_char`/`draw_char_16`/`draw_rect` onto the batch
  path, keep output pixel-identical, host-test the span batcher, save
  before/after measurements under `artifacts/`.
