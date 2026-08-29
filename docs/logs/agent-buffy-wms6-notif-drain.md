# Log — `agent/buffy/wms6-notif-drain`

## 2026-08-29 — WMS6 Gate B claimed (issue #626, the click-driven chrome surface)

- Claimed **WMS6 Gate B — notification-center policy drains into WND.BIN** as
  `docs/claims/7557-wms6-notif-drain.md` (status 🔄, heartbeat 2026-08-29). Branch
  `agent/buffy/wms6-notif-drain` cut from `main` (Gate A / PR #646 merged).
- Scope frozen in the claim: new slot-65 subcommands `NOTIF_CENTER = 6` (open/close/clear)
  and `NOTIF_DISMISS = 7`; the kernel tray-click toggle + panel dismiss/clear gated behind
  `!wm_owns_input` (no WM → byte-identical shim); WND.BIN hit-tests the kind-19 click on the
  tray (same `fb_w - 80` slice as `tray_rect`) and issues `NOTIF_CENTER`, emitting
  `wnd: notif-open/close` markers. Headless CI-runnable via `--pointer-virtio` (claim 9367) —
  no Accessibility trust needed.
- Survey confirmed: kind 19 `WM_POINTER` already carries the HID button byte (the WM's
  WMS5 drag logic decodes left-edge from it), so the click seam needs no new event kind; the
  kernel tray is `fb_w - 80` (x in 1200..1280) at the taskbar row — the injected click point
  hits both surfaces in boot A (shim) and boot B (WM).
## 2026-08-29 — WMS6 Gate B complete; live gate PASS on VZ

- Implemented **WMS6 Gate B — notification center drains into WND.BIN** (claim 7557):
  - kernel: new slot-65 subcommands `NOTIF_CENTER = 6` (a0 = 0 close / 1 open /
    2 clear-all) + `NOTIF_DISMISS = 7` (a0 = row index) in `wm_server.zig` +
    `handle_wmctl`; `driving_award` gained `notif_center_set_open(open)`; the
    kernel tray-click toggle + panel dismiss/clear gate behind `!wm_owns_input`
    (no WM → byte-identical shim). New monitor command `dui notif-center-state`
    (pure report, doesn't toggle) is the gate's panel-state probe.
  - WND.BIN: a kind-19 left-button DOWN EDGE hit-tests the tray (the shim's
    `fb_w - 80` slice), toggles its own `notif_open`, issues `NOTIF_CENTER`
    open/close, emitting pinned `wnd: notif-open`/`notif-close` markers.
  - monitor `wm` row prints `notif=` + `notif_dismiss=` (applied cmd 6/7).
  - Docs: ADR 0007 (cmd 6/7 rows + Gate-B amendment), `status.md`, march tracker.
- Tests: new `syscall: NOTIF_CENTER / NOTIF_DISMISS (cmd 6/7, claim 7557)...`
  + wnd marker pins; class-A unit suite green (467 and up), zig fmt + coordination ok.
- Live class-B gate `tools/verify-live-wnd6-notif-drain.sh` **PASS on VZ**, headless
  via `--pointer-virtio "1240,710,c"` (claim 9367, no Accessibility trust): boot A
  (no WM) a real tray click still opens the panel (`dui notif-center-state:
  open=yes`, zero regression); boot B (WND.BIN registered) the WM decided
  (`wnd: notif-open`), the kernel applied (`wm: notif=1` + `ptr_fan=3`) and did
  not self-toggle, panel open. Registered in `tools/sweep-vz.sh`.
