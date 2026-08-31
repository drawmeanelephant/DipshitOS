# Log — agent/buffy/m33-sb5-wm-compose-n

## 2026-08-31 — claim 7397 opened (SB5: WM compose-N + one final present)

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

## 2026-08-31 - claim 7397 done (SB5: WM compose-N + one final present)

Implemented + verified. The WM binds the scanout writable via the new
`M33_SURF_SCAN_TAG` sys_mmap addr-tag (WM seat / full-frame / writable /
idempotent; kernel-owned gpu_fb pages never ref'd/unref'd; teardown on WM exit
and full-frame munmap). Chrome moved to the tick (`paint_scene` runs in
`wm_server.on_tick` before the COMPOSITE_TICK event); REQUEST_PRESENT is the
final flush-only present; paint_scene skips migrated windows while the WM owns
the user layer — scanout z-order is kernel-under-WM at flush time.

Host tests: scanout bind contract, paint-skip, WM-seat refusal — all green;
full host suite green; fmt/coordination ok; BSS PASS.

Live gate PASS (headless VZ): `verify-live-sb5-wm-compose-n.sh` — SB5WM
registered + bound the scanout, SB5OWN rendered with plain stores ONLY, the WM
composed the surface into the scanout and read the byte back (`sb5: wm
readback=0x5B`), issued the final present, and the `syscalls` report showed
`13 sys_win_fill calls=0` — a registered-WM desktop composited entirely from
shared surfaces with ZERO fill SVCs. Zero faults.

Coordination note: `docs/status.md` is declared by the ACTIVE claim 2852
(`agent/buffy/docs-pass`) — per the one-editor-per-file rule its M33 status
line update is deferred to a later docs pass (the tracker + ADRs carry the
SB5 record).
