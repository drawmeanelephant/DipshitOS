# Log — agent/buffy/m33-sb5-wm-compose-n

## 2026-08-31 — claim 8247 opened (SB5: WM compose-N + one final present)

Phase-3 compose card on `agent/buffy/m33-sb5-wm-compose-n` off `origin/main`
(SB4 merged, PR #713). Design:

- The registered WM maps the scanout (`gpu_fb`) writable via a new
  `sys_mmap` addr-tag (bit 62, `M33_SURF_SCAN_TAG`) - WM seat only, full
  frame only, kernel-owned pages (never ref/unref'd to the WM; teardown
  unmaps leaves without unref).
- Chrome moves to the tick: `driving_award.paint_scene()` (the paint half of
  composite) runs in `wm_server.on_tick` BEFORE the COMPOSITE_TICK event, so
  the kernel layer is under the WM's compose-N stores; `REQUEST_PRESENT`
  becomes flush-only (the G1 transfer+flush in `request_present`) - the
  kernel can never overdraw the WM's stores (z-order preserved).
- Migrated (surface-backed) windows are skipped by paint_scene while the WM
  owns the user layer (set on scanout bind).
- Gate: zero `sys_win_fill` SVCs for migrated apps - observed via the
  existing per-slot call counter (`syscalls` monitor: slot 13 calls=0) plus
  the live gate's plain-store-only owner app.
