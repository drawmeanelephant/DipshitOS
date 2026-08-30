# Log — agent/buffy/wms8-gate6-pointer-drag-delete

## 2026-08-30 — WMS8 Gate 6 claimed (issue #628)

- Claimed **WMS8 Gate 6 — delete the kernel's dormant pointer drag/snap
  geometry-decision layer** as `docs/claims/4576-wms8-gate6-pointer-drag-delete.md`
  (status 🔄, heartbeat 2026-08-30). Branch `agent/buffy/wms8-gate6-pointer-drag-delete`
  cut from `origin/main` (c75129b).
- Scope per the parity rule: WMS5 proved the WM owns title-bar drag->move +
  snap-on-drop via kind-19 WM_POINTER -> SET_WINDOW (the wnd5-geometry gate
  drives a WM-owned drag green). Gate 6 deletes the kernel's counterpart
  decision path (drag_id/drag_offset state, title-bar drag-init, drag-move +
  snap-on-release). KEEP: resize (no WM coverage), close/minimize buttons,
  modal, dock/tray/notif clicks, MOUSE delivery to apps, and the app-level
  DnD payload system (separate from title-bar drag).
## 2026-08-30 — WMS8 Gate 6 complete (claim 4576, issue #628)

- Claim **4576** flipped 🔄 → ✅. The kernel's dormant pointer title-bar
  drag+snap decision layer is deleted from `driving_award.zig` (net −215
  lines); resize/buttons/modal/dock-tray-notif/MOUSE-delivery/DnD kept.
- Gates **PASS on VZ**: new `verify-live-wnd8-ptr-drag-delete` (boot A
  no-WM: title-bar drag does nothing, rect `56,56,512,384`, no fault;
  boot B WM: `wnd: grab` + `drag=4` + `drop` + `ptr_fan=1`, registry row
  CHANGED) and the `verify-live-wnd5-geometry` parity gate re-ran PASS
  (WM drag moved NOTEPAD via SET_WINDOW).
- Host tests: `just test` all green (driving_award 212/212); fmt/
  coordination/BSS-gap clean.
- Docs: Gate 6 appended to `docs/status.md`, `docs/march-m32-wm-migration.md`
  (WMS8 row), and ADR `docs/decisions/0015-window-server-render-seam.md`.
- PR opened against #628 with `fixes #628` (the final gate of the WMS8
  sequence — the epic closes on merge).
