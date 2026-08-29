# Log — `agent/buffy/wms6-dock-drain`

## 2026-08-29 — WMS6 Gate D claimed (issue #626, the dock)

- Claimed **WMS6 Gate D — the dock drains into WND.BIN** as
  `docs/claims/9197-wms6-dock-drain.md` (status 🔄, heartbeat 2026-08-29). Branch
  `agent/buffy/wms6-dock-drain` cut from `main` (Gates A/B/C merged).
- Scope frozen in the claim: new slot-65 subcommand `DOCK = 9` (a0 = icon index, applied
  through a clamped `dock_icon_click` that is the shim's exact restore/focus/open chain);
  the kernel dock-click handler gates behind `!wm_owns_input`; WND.BIN hit-tests the
  kind-19 click on the dock icon grid (the shim's `(2, 8+idx*32)` 20×20 boxes) and issues
  `DOCK <idx>`, emitting `wnd: dock idx=N`; hover labels ride the Gate-C TOOLTIP seam
  ("Calc"/"Notes"/"Terminal"/"Browser"/"Settings"). Headless CI via `--pointer-virtio`
  (a hover + click on icon 0, claim 9367).
- Survey confirmed: the dock bar blits at (0,0,24,dock_h), icons at (2, 8+idx*32) 20×20,
  click chain = restore-first-minimized → focus/raise user → open; the `dui` report's
  `focused=`/`visible=` columns are the restore observables for both boots.
## 2026-08-29 — WMS6 Gate D complete; live gate PASS on VZ

- Implemented **WMS6 Gate D — the dock drains into WND.BIN** (claim 9197):
  - kernel: new slot-65 subcommand `DOCK = 9` (a0 = icon index 0..4) in
    `wm_server.zig` + `handle_wmctl`; `driving_award` gained `dock_icon_click`
    (the shim's EXACT restore-first-minimized -> focus/raise -> open chain); the
    kernel dock-click handler gates behind `!wm_owns_input` (no WM ->
    byte-identical shim). The kernel's blanket tooltip-clear-on-move also gates
    behind `!wm_owns_input` so it cannot fight the WM's hide decisions.
  - WND.BIN: a kind-19 left-button DOWN EDGE hit-tests the dock icon grid (the
    shim's `(2, 8+idx*32)` 20×20 boxes) and issues `DOCK <idx>`, emitting
    `wnd: dock idx=N`; hover over an icon issues the Gate-C TOOLTIP label
    ("Calc"/"Notes"/"Terminal"/"Browser"/"Settings") and leaving hides it.
  - monitor `wm` row prints `dock=` (applied cmd 9).
  - Docs: ADR 0007 (cmd 9 row + Gate-D amendment), `status.md`, march tracker.
- Tests: new `syscall: DOCK (cmd 9, claim 9197) restores/focuses through the
  WM's icon decision` + `wnd: the WMS6 dock icon hit-test matches the shim's
  grid` + marker/label pins; class-A unit suite green, zig fmt + coordination ok.
- Live class-B gate `tools/verify-live-wnd6-dock-drain.sh` **PASS on VZ**, headless
  via `--pointer-virtio "12,24;12,18,c"` (hover + click on icon 0, claim 9367):
  boot A (no WM) a dock click still restores the minimized NOTEPAD
  (`focused=2`, zero regression); boot B (WND.BIN registered) the WM decided
  (`wnd: dock idx=0`), the kernel applied (`wm: dock=1`), NOTEPAD restored +
  focused, and the hover label rode the Gate-C seam (`visible=yes text=Calc`).
  Re-ran the Gate-C tooltip gate after the move-clear gating: still PASS.
  Registered in `tools/sweep-vz.sh`.
