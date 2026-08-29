# Log — `agent/buffy/wms6-tooltip-drain`

## 2026-08-29 — WMS6 Gate C claimed (issue #626, the read-mostly hover chrome)

- Claimed **WMS6 Gate C — the tooltip surface drains into WND.BIN** as
  `docs/claims/6154-wms6-tooltip-drain.md` (status 🔄, heartbeat 2026-08-29). Branch
  `agent/buffy/wms6-tooltip-drain` cut from `main` (Gates A/B merged).
- Scope frozen in the claim: new slot-65 subcommand `TOOLTIP = 8` (a0 = 0 hide / 1 show,
  text via `ptr/len`, the 32-byte M27 bound) applied through the existing
  `tooltip_set`/`tooltip_clear` + a new immediate `tooltip_show_now`; WND.BIN decides on
  a kind-19 hover over the tray (the Gates A/B `fb_w - 80` slice) and issues
  `TOOLTIP show "Clock"` / hide, emitting `wnd: tooltip` markers; headless CI via a bare
  `--pointer-virtio "<x>,<y>"` move (claim 9367).
- Survey confirmed: the M27 G6 tooltip is a DORMANT stub — `tooltip_set` has zero
  callers, no monitor command drives it, and M27 G7 was an audit row only. So this gate
  ACTIVATES the surface under WM ownership (the honest regression proof: the shim still
  does nothing on hover in boot A); nothing to gate on the kernel side because the
  kernel never self-triggered a tooltip.
## 2026-08-29 — WMS6 Gate C complete; live gate PASS on VZ

- Implemented **WMS6 Gate C — the tooltip surface drains into WND.BIN** (claim 6154):
  - kernel: new slot-65 subcommand `TOOLTIP = 8` (a0 = 0 hide / 1 show, text via
    ptr/len with the 32-byte M27 bound, EFAULT/EINVAL honesty) in `wm_server.zig` +
    `handle_wmctl`; `driving_award` gained `tooltip_show(text)` (immediate show at
    its own cursor — the WM owns the dwell policy). New monitor command
    `dui tooltip-state` (pure report) is the gate's box-state probe.
  - WND.BIN: a kind-19 hover (move, no click) entering the tray (the Gates A/B
    `fb_w - 80` slice) decides "Clock" and issues `TOOLTIP show "Clock"` (text via
    ptr/len); leaving issues hide. Emits pinned `wnd: tooltip`/`wnd: tooltip-hide`.
  - monitor `wm` row prints `tooltip=` (applied cmd 8).
  - Docs: ADR 0007 (cmd 8 row + Gate-C amendment), `status.md`, march tracker.
- Tests: new `syscall: TOOLTIP (cmd 8, claim 6154) shows/hides the tooltip from the
  WM's text` + wnd marker pins; class-A unit suite green (590 and up), zig fmt +
  coordination ok.
- Live class-B gate `tools/verify-live-wnd6-tooltip-drain.sh` **PASS on VZ**, headless
  via a bare `--pointer-virtio "1240,700"` move (claim 9367, no Accessibility trust):
  boot A (no WM) a hover changes nothing (`dui tooltip-state: visible=no`, the
  dormant stub — zero regression); boot B (WND.BIN registered) the WM decided
  (`wnd: tooltip`), the kernel applied (`wm: tooltip=1` + `ptr_fan=1`) and the box
  renders the WM's text (`visible=yes text=Clock`). Registered in `tools/sweep-vz.sh`.
