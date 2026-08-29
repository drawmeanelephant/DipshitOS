# Log — `agent/buffy/wms6-altab-drain`

## 2026-08-29 — WMS6 Gate A claimed (issue #626, first read-mostly slice)

- Claimed **WMS6 Gate A — Alt+Tab policy drains into WND.BIN** as
  `docs/claims/4510-wms6-altab-drain.md` (status 🔄, heartbeat 2026-08-29). Branch
  `agent/buffy/wms6-altab-drain` cut from `main` (WMS1–5 merged).
- Scope frozen in the claim: new slot-65 subcommand `ALT_TAB = 5` (activate/cycle/commit/dismiss
  with the kernel clamping + blitting the overlay), the kernel Alt+Tab input decision gated behind
  `!wm_owns_input` via an explicit `self_cycle_count` proof, and WND.BIN deciding the switch target
  from its kind-20 mirror registry via the shared `wnd_core` next-window rule.
- Survey confirmed: kind 21 `WM_KEY` fans key-down edges with `MOD_ALT` in `flags` (no pointer
  trust needed — fully CI-runnable via the WMS5 injected-chord pattern); `alt_tab_pending` is set
  only behind `!wm_owns_input`, so the no-WM path is byte-identical. The MI/WI shim rows keep
  testing the unregistered path; the registered-variant gate proves the WM decided the switch.
## 2026-08-29 — WMS6 Gate A complete; live gate PASS on VZ

- Implemented **WMS6 Gate A — Alt+Tab policy drains into WND.BIN** (claim 4510):
  - kernel: new slot-65 subcommand `ALT_TAB = 5` (a0 window id, a1 action
    1 activate / 2 cycle / 3 commit / 4 dismiss) in `wm_server.zig` +
    `handle_wmctl`; `driving_award` gained `alt_tab_overlay_focus(id)` (builds
    the snapshot from the M21 W3/W4 rules + highlights the WM's chosen id) and
    `alt_tab_wm_commit(id)` (focus + raise + dismiss by id); the WM's Alt+Tab
    input path gates behind `!wm_owns_input` (kernel never self-cycles).
  - WND.BIN: `handle_wm_key` Alt+Tab (MOD_ALT + usage 0x2B) → pure
    `next_alt_tab_target()` (next mirror after focused, current workspace)
    → `ALT_TAB commit`, emitting pinned `wnd: alt-tab id=N`.
  - host: runner gained the `alt-tab` HID chord (LAlt = HID mod bit 2 + Tab
    usage 0x2B) for both the headless custom-virtio channel and the display
    path; the guest already maps mod bit 2 → ADR 0009 MOD_ALT.
  - monitor `wm` row prints `alt_tab=N` (the applied-decision counter).
  - Docs: ADR 0007 (cmd 5 row + Gate-A amendment), `status.md`, march tracker.
- Tests: new host tests `syscall: ALT_TAB (cmd 5, claim 4510)...` +
  `wnd: the WMS6 Alt+Tab target rule (drift guard)`; full class-A unit suite
  green (last aggregated binary 576/576); `zig fmt` + coordination ok.
- Live class-B gate `tools/verify-live-wnd6-altab-drain.sh` **PASS on VZ**:
  boot A (no WM) a real Alt+Tab still self-cycles (`dui: alt-tab active
  count=2`, zero regression); boot B (WND.BIN registered) the WM decided
  (`wnd: alt-tab id=2`), the kernel applied (`wm: alt_tab=1`) and did not
  self-decide (`dui: alt-tab` count 0), seam live (`key_fan=1`) + WM pacing.
  Registered in `tools/sweep-vz.sh`.
