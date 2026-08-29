# Claim: WMS6 Gate E — the tray widgets drain into WND.BIN (the final chrome gate of #626)

- **Owner:** buffy (`agent/buffy/wms6-tray-drain`)
- **Issue:** https://github.com/drawmeanelephant/DipshitOS/issues/626 (WMS6 of 10, milestone 16 — Gate E, the FINAL gate)
- **Depends on:** WMS6 Gates A–D (claims 4510/7557/6154/9197, PRs #646/#648/#650/#652 merged — cmd 5/6/7/8/9 + kinds 19/21 + `wm_owns_input`). Cut from `main`.
- **Closes:** the #626 card (this is the last desktop-chrome surface; when this merges the issue is closed as completed).
- **Blocks:** WMS8 (deleting kernel chrome code)
- **Heartbeat:** 2026-08-29
- **Status:** ✅ (2026-08-29 — live gate PASS on VZ; all five issue-626 surfaces drain)

## Scope — Gate E of the card: the WM owns the tray widgets

Gates A–D drained the keyboard, click, hover, and dock chrome. Gate E drains the last
surface: the **tray widgets** (the taskbar's right 80 px — the M15 C4 clock, the theme
letter, and the Arc2 W3 clipboard indicator). Today the kernel `drain()` derives all
three from kernel state (the 1 Hz timer, `theme_id`, `clipboard.current_len()`), and —
critically — `drain()` is only called when NO WM is registered (shell.zig), so under a
WM the tray FREEZES. Gate E makes the WM the tray's policy owner:

1. **New slot-65 subcommand `TRAY = 10` (ADR 0007 amendment):** `a0` = flags (bit 0
   clock, bit 1 theme, bit 2 clipboard — each field OPTIONAL); `a1` = the 5-byte
   `HH:MM` clock text packed little-endian (chars validated to the `HH:MM` charset);
   `a2` = theme letter (low byte, clamped to `D`/`L`/`A`) | clipboard filled (bit 8).
   The WM formats the time from its OWN COMPOSITE_TICK count (kind 18 arrives at 1 Hz —
   the same timebase the shim's `format_hhmm` uses) via the SAME minute-rollover
   formula (parity by value), and probes the clipboard source of truth
   (`sys_clipboard_get`, slot 39, returns bytes copied → 0 = empty).
2. **The kernel renders from the WM's declaration (source-selected):** the tray renderer
   draws the WM's clock string / theme letter / clipboard indicator when that field's
   `_set` flag is true, else the shim-derived value (`format_hhmm(tray_tick)` /
   `theme_letter()` / `tray_clipboard_filled()`). The shim path is untouched (no WM →
   byte-identical; `drain()` still gates behind `!registered`). `tray_set` clamps +
   marks the taskbar (window 255) dirty. `clear_wm_chrome` (WM teardown) resets all
   three `_set` flags so the shim fallback re-derives them (a dead WM's values never
   stay painted).
3. **WND.BIN grows the tray policy:** every `tray_refresh_every` (10) ticks it formats
   HH:MM from its tick count, probes the clipboard, and issues `TRAY` when the content
   CHANGED (mirroring the shim's drain: repaint on change, not every tick) — the tray's
   first live refresh while the WM is seated. Emits pinned `wnd: tray clock=HH:MM
   theme=D clip=yes|no` markers.
4. **Headless CI:** a new pure `dui tray-state` report
   (`clock=HH:MM clock_set=yes|no theme=D theme_set=... clip=... clip_set=...`); NO
   pointer injection needed (time-driven). Boot A (no WM): `clock_set=no` + a valid
   HH:MM (shim-derived — zero regression). Boot B (WM): `wnd: tray` marker, `wm:
   tray=[1-9]` counter, the counter GROWS between two probes (the clock REFRESHES under
   the WM), the probe clock MATCHES the marker clock (the WM's string is what renders),
   and a `clip hello` mid-run flips the WM's clipboard decision (`clip=yes clip_set=yes`).
5. **On unregister** `clear_wm_chrome` resets the `_set` flags — the shim fallback
   re-derives all three (byte-identical).

## Design decisions

1. **The tray is the final drainable widget surface.** Clock refresh + theme letter +
   clipboard icon are policy (who decides the time string / the letter / the icon
   state). The theme letter IS drained (the WM is the theme owner — it declares the
   parity `'D'`; the kernel clamps to `D`/`L`/`A`).
2. **The WM timebase is kind 18.** COMPOSITE_TICK arrives at 1 Hz — the same cadence as
   the shim's timer — so the WM's `format_hhmm` from its tick count is the honest clock,
   and parity-by-value holds (same formula, both start at 00:00 at their own epoch).
3. **`sys_clipboard_get` is the source of truth** the WM probes — no new fan-out kind,
   the indicator stays honest to the kernel clipboard.
4. **The kernel keeps its tray functions** (WMS8 deletes them) — the shim path is
   byte-identical and the M15 C4/Arc2 W3 rows run against it.
5. **Drive-by fix (pre-existing Gate-A test bug):** the standalone `wnd` drift-guard
   suite (not part of the gate MODULES, per the WMS3 honesty note) had a broken
   Alt+Tab test — `mirrors = undefined` left unseeded slots' `.valid` bits garbage (the
   rule iterates the WHOLE table), and the third assertion expected `3` with a single
   candidate, which the rule correctly no-ops. Fixed: zero-fill the table first and make
   the corrupt-slot case exercise two real candidates (expects `5`). All 8 wnd tests
   now pass deterministically under `zig test`.

## Touches

`kernel/src/driving_award.zig` (`tray_set` + source-selected renderer + `clear_wm_chrome`
reset + `arm()` reset), `kernel/src/wm_server.zig` (TRAY const + counter), `kernel/src/syscall.zig`
(cmd 10 handler + contract test), `user/src/wnd.zig` (tray clock/theme/clip policy +
markers + drift-guard pins + alt-tab test fix), `kernel/src/monitor.zig` (`dui tray-state`
report + `wm` row `tray=`), new `tools/verify-live-wnd6-tray-drain.sh`,
`tools/sweep-vz.sh`, `docs/decisions/0007-syscall-abi.md`, `docs/status.md`,
`docs/march-m32-wm-migration.md`, claim + log. When merged, **close #626 as completed**
(the card's final gate).
