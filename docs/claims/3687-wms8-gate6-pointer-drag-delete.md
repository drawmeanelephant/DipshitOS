# Claim 3687: WMS8 Gate 6 — delete the kernel's dormant pointer drag/snap geometry-decision layer

- **Owner:** buffy (`agent/buffy/wms8-gate6-pointer-drag-delete`)
- **Prompt / plan:** issue #628 (WMS8, sixth of a multi-gate deletion sequence)
- **Scope:** the kernel's POINTER-DRAG geometry-decision layer that WMS5
  already drained to the WM. WMS5's input-seam handover proved the WM owns
  pointer GEOMETRY: while a WM is registered `pointer_tick` fans the raw
  pointer stream (kind-19 WM_POINTER) out to the WM and returns null — the
  kernel consumes NO drag/resize/snap/focus-at. The WM hit-tests and issues
  SET_WINDOW rects; the kernel clamps + blits. Per WMS8's delete rule (a block
  is deleted only when its parity gate has been green with the WM registered —
  the WMS5 geometry gate re-runs a WM-driven title-bar drag green), this gate
  DELETES the now-dormant kernel pointer-DRAG decision path:
    - driving_award.zig: the `drag_id`/`drag_offset_x`/`drag_offset_y` state,
      the title-bar drag-initiation in `pointer_tick`'s left-button DOWN EDGE
      (`user_move` + the `drag_active` window-DnD machinery), the drag-move +
      snap-on-release block, and the now-dormant applied snap primitives
      (`snap_window`/`snap_restore`/`snap_is_snapped`/`snap_current_zone` +
      the `snap_zone`/`snap_zone_bounds` tracking).
  KEPT (still live / WM doesn't cover them): **resize** (the kernel shim's
  resize handle + clamp — the WM has no resize path yet; deleting it would
  regress shim mode), close/minimize buttons, the modal blocking path, the
  dock/tray/notification-center click decisions (WMS6 drains, still shim-side
  until their own gates), pointer-event DELIVERY to apps (MOUSE_DOWN/UP/MOVE
  via hit window owner — the WM only gets the raw fan, apps still need the
  local-coordinate events), and the separate app-level drag-and-drop payload
  system (the `drag_active` DnD is NOT the title-bar drag — it stays).
  Shim end-state consequence (intended, per the issue's "no compositing
  policy" end-state): with NO WM, dragging a title bar does nothing instead of
  moving the window; snap-on-drop does nothing.
- **Touches:** `kernel/src/driving_award.zig`,
  `tools/verify-live-wnd8-ptr-drag-delete.sh` (new gate),
  `tools/sweep-vz.sh`, `docs/decisions/0015-window-server-render-seam.md`,
  `docs/march-m32-wm-migration.md`, `docs/status.md`, claim + log
- **Depends on:** WMS5 Gate 2 + the geometry gate (claims 4278/9849), WMS8
  Gates 1–5 (claims 4790/9980/7736/6155/7639/9879) — the prior gate pattern.
- **Heartbeat:** 2026-08-30
- **Status:** ✅ `agent/buffy/wms8-gate6-pointer-drag-delete`

**Result:** DONE 2026-08-30. The kernel's dormant pointer title-bar drag+snap
decision layer is deleted from `driving_award.zig` (net −215 lines):
`drag_id`/`drag_offset_*`, the title-bar drag-init branch, the drag-move +
snap-on-release block, `snap_zone`/`snap_last_*`/`snap_snapped`, the applied
`snap_window`/`snap_restore`/`snap_is_snapped`/`snap_current_zone`
primitives, the snap-preview render, the cursor move-glyph. KEPT: resize,
close/minimize buttons, modal, dock/tray/notif clicks, MOUSE delivery to
apps, app-level DnD. New gate `tools/verify-live-wnd8-ptr-drag-delete.sh`
**PASS on VZ** (boot A no-WM: drag does nothing, rect `56,56,512,384`, no
fault; boot B WM: `wnd: grab` + `drag=4` + `drop` + `ptr_fan=1`, registry
row CHANGED); `verify-live-wnd5-geometry` parity re-ran **PASS**. Host
tests: driving_award 212/212, full `just test` green; fmt/coordination/
BSS-gap clean. Docs: status.md + march-m32 Gate 6 entry + ADR 0015
amendment. PR resolves #628.