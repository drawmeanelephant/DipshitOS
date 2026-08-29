# Log — `agent/buffy/wms6-tray-drain`

## 2026-08-29 — WMS6 Gate E claimed (issue #626, the final chrome gate)

- Claimed **WMS6 Gate E — the tray widgets drain into WND.BIN** as
  `docs/claims/3744-wms6-tray-drain.md` (status 🔄, heartbeat 2026-08-29). Branch
  `agent/buffy/wms6-tray-drain` cut from `main` (Gates A–D merged). When this merges,
  **#626 closes as completed** (the card's final gate).
- Scope frozen in the claim: new slot-65 subcommand `TRAY = 10` (a0 = 0 set clock text
  via ptr/len ≤ 5 bytes; a0 = 1 set clipboard indicator from a1), applied through
  `tray_set_clock`/`tray_set_clip`; the tray renderer draws from a `tray_clock_src` /
  clipboard-override the WM declares (else the shim's `format_hhmm`/`tray_clipboard_filled`);
  WND.BIN formats HH:MM from its own COMPOSITE_TICK count (kind 18, 1 Hz — the same
  timebase as the shim), probes `sys_clipboard_get` (slot 39) for the indicator, and
  submits TRAY each tick, emitting `wnd: tray`; a new pure `dui tray-state` report is the
  gate's probe. Theme letter stays kernel-derived (documented — a theme visualization).
- Survey confirmed: `drain()` is only called when `!wm_server.registered()` (shell.zig
  3431), so under a WM the tray FREEZES today — the exact gap this gate fixes; the
  renderer's src-based selection isolates the two paths with no shim regression. The tray
  renders clock (HH:MM from tray_tick), theme letter, clipboard indicator (Arc2 W3).
## 2026-08-29 — Gate E implemented; live gate PASS on VZ (WMS6 CLOSES)

- **Encoding refinement (corrects the claim-entry scope above):** the draft split TRAY
  into two ptr/len actions (clock / clipboard). Implementation freezes a single
  flags-based encoding instead: `a0` = flags (bit 0 clock, bit 1 theme, bit 2
  clipboard), `a1` = the 5-byte `HH:MM` clock text packed LE, `a2` = theme letter (low
  byte, clamped `D`/`L`/`A`) | clipboard filled (bit 8). Each field is OPTIONAL (a
  missing bit leaves that widget on the shim fallback), and the theme letter IS drained
  too (the WM is the theme owner; it declares parity `'D'`). ADR 0007 row + amendment
  written to the frozen encoding.
- **Kernel:** `driving_award` gains `wm_tray_clock_text/_clock_set/_theme/_theme_set/
  _clip/_clip_set` + `tray_set(clock, theme, clip)` (clamps + marks the taskbar, window
  255, dirty); the tray render is source-selected (WM value when `_set`, else shim
  derived); `clear_wm_chrome` + `arm()` reset the `_set` flags. `wm_server` gains
  `wmctl_tray = 10` + `tray_count` + `note_tray()`; `syscall` gains the cmd-10 handler
  (validates flags, the `HH:MM` charset, and `D`/`L`/`A`; ENOSYS unregistered, EACCES
  non-registrant, EINVAL malformed). `monitor` gains the pure `dui tray-state` probe and
  the `wm` row `tray=` counter.
- **WND.BIN:** consts `wmctl_tray=10` + flags, `tray_refresh_every=10` (kind-18 ticks
  are 1 Hz = seconds), `TrayState` + `format_wm_hhmm` (the shim's exact minute-rollover
  formula — parity) + `tray_tick_policy` (issue TRAY only on content change, mirroring
  the shim drain), wired into the composite_tick arm every 10 ticks with a
  `sys_clipboard_get` probe; emits `wnd: tray clock=HH:MM theme=D clip=yes|no`.
- **Tests:** new `syscall: TRAY (cmd 10, claim 3744)` contract test (stores all three
  fields, partial flags, EINVAL paths, teardown resets) — green in all 6 aggregated
  binaries; new wnd drift-guard pins + a pure `tray_tick_policy`/`format_wm_hhmm` test.
- **Drive-by fix (pre-existing Gate-A bug, honest note):** running the standalone `wnd`
  test suite surfaced a broken Alt+Tab drift guard — `mirrors = undefined` left unseeded
  slots' `.valid` garbage (the rule iterates the whole table), and its third assertion
  expected `3` with a single candidate, which the rule correctly no-ops to `null`. Fixed
  both (zero-fill; the corrupt-slot case now exercises two real candidates and expects
  `5`). The suite was never in the gate MODULES (WMS3 honesty note) — that's why it
  shipped; all 8 wnd tests pass deterministically now.
- **Live class-B gate `tools/verify-live-wnd6-tray-drain.sh` PASS on VZ (2026-08-29),**
  headless, no pointer injection (time-driven): Boot A (no WM) shows the kernel-derived
  tray (`clock_set=no`, valid HH:MM — zero regression). Boot B (WM registered): the WM
  decided (`wnd: tray clock=00:00 theme=D clip=no`), the kernel applied (`wm: tray=1` →
  `2`), the counter grew between the two probes (the clock REFRESHES under the WM — it
  was frozen before this gate), the probe clock matched the marker clock (the WM's
  string is what renders), and a `clip hello` mid-run flipped the WM's clipboard
  decision (`clip=yes clip_set=yes` in the probe). Registered in `tools/sweep-vz.sh`.
- **All host tests green** (incl. the new TRAY test), fmt clean, coordination clean.
  Docs: ADR 0007 (cmd-10 row + Gate-E amendment), march WMS6 row updated to
  `✅ claims 4510/7557/6154/9197/3744` + Gate-E note, status.md Gate-E block. Claim
  flipped ✅. **#626 closes when the PR merges — all five surfaces (alt-tab, notification
  center, tooltip, dock, tray) now drain into WND.BIN.**
