# Log — `agent/buffy/wms8-gate5-geometry-keyboard-delete`

## 2026-08-30 — WMS8 Gate 5 claimed (issue #628)

- Claimed **9879** — the kernel's geometry-policy KEYBOARD-DECISION layer is
  deleted per WMS5 Gate 2's drain + WMS8's delete rule. Branch
  `agent/buffy/wms8-gate5-geometry-keyboard-delete` cut from `origin/main`
  (93f6078).
- Scope confirmed before coding: the `dui` monitor commands (the W5 matrix +
  M21 heritage gates) drive the applied primitives DIRECTLY (not through the
  keyboard layer), so deleting the keyboard consumers does not regress the
  matrix. The WM's `handle_wm_key` serves tile/master/minimize/maximize/
  fullscreen/always-on-top/workspace-switch/workspace-cycle; it does NOT serve
  lower-back (Ctrl+Shift+B) or move (Alt+arrows) — those keyboard consumers
  are kept. Alt+Tab stays (separate WMS6 focus surface, and its applied
  primitives serve the ALTTAB cmd).
- **#628 stays open** — this is a deletion PR that links, not closes, it.
## 2026-08-30 — WMS8 Gate 5 complete (claim 9879, issue #628)

- Claim **9879** (WMS8 Gate 5 — the geometry-policy keyboard-decision layer is
  deleted) closed ✅. Branch `agent/buffy/wms8-gate5-geometry-keyboard-delete`.
- Deleted in `input.zig`: the geometry pending-flag vars + chord-decode
  branches (workspace switch/cycle, tile toggle, master swap, minimize,
  maximize, fullscreen, always-on-top) + their `take_*` accessors — all
  gated behind `!wm_owns_input`, so provably dormant with a WM seated per
  WMS5 Gate 2's drain. Deleted the matching shell idle consumer blocks.
- KEPT the applied primitives (the `dui` monitor commands + SET_STATE drive
  them; the matrix re-runs green through them), lower-back + move keyboard
  consumers (no WM coverage yet), and Alt+Tab (WMS6 focus surface).
- New gate `verify-live-wnd8-geom-kbd-delete.sh` **PASS on VZ, both boots**
  (registered in `tools/sweep-vz.sh`); canonical `verify-live-wnd5-gate2-
  policy.sh` (the W5 matrix) re-ran **PASS**. Boot A the dormant shim does
  nothing on a real Ctrl+T; boot B the matrix re-runs green AND the WM
  decided tile (`wnd: tile`, `key_fan=1`) and the kernel applied SET_WINDOW
  rect 24,0,837,700 with no `dui: tile=`.
- Host tests green (input 215 incl. the updated chord test, driving_award
  215, syscall 472, monitor 577; the shell `mock-fed` FileNotFound failure is
  pre-existing on clean main). fmt/coordination clean; BSS budget re-ran
  green. Docs: march WMS8 row, status.md, ADR 0015.
- **#628 stays open** — remaining deletion gates ahead.
