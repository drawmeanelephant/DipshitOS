# Log — `agent/buffy/wms8-desktop-overlay-drain`

## 2026-08-29 — WMS8 Gate 1 claimed (issue #628), tooltip dwell-drain

- Claimed **WMS8 Gate 1 — delete the kernel tooltip dwell-decision policy** as
  `docs/claims/4270-wms8-tooltip-dwell-drain.md` (status 🔄, heartbeat
  2026-08-29). Branch `agent/buffy/wms8-desktop-overlay-drain` cut from
  `origin/main` (`5f02a4f`).
- WMS8 is the 5,316-line slimming card; the issue explicitly mandates one
  policy block per claim/PR. This is the first deletion gate.
- The tooltip dwell path is dead in the kernel: `tooltip_set` has no callers, so
  the shim's `tooltip_timer` never advances on its own and `tooltip_advance_tick`
  (the 10-tick hover decision) can never reveal the box; only the WM's TOOLTIP
  (cmd 8) seam shows it via `tooltip_show`/`tooltip_show_now`. Parity already
  proven by WMS6 Gate C (`verify-live-wnd6-tooltip-drain.sh`).
## 2026-08-29 — WMS8 Gate 1 done (claim 4270), PR up

- Deleted the tooltip dwell-decision from `kernel/src/driving_award.zig`:
  `tooltip_set`, `tooltip_advance_tick`, the composite idle call, and the
  `tooltip_timer`/`tooltip_hover_ticks` BSS. It was provably dead — no callers
  reached `tooltip_set`, so the kernel dwell timer could never reveal the box;
  the WM owns WHEN via the WMS6 Gate C TOOLTIP (cmd 8) seam.
- Retained the surface + the WM decision channel: `tooltip_show`/`tooltip_show_now`/
  `tooltip_clear`, the clamp/place/blit, and `dui tooltip-state` observability.
- `verify-live-wnd6-tooltip-drain.sh` re-ran **PASS on VZ** both boots (dormant
  shim shows nothing; WM still decides + applies `visible=yes text=Clock`).
  215 (driving_award) + 470 (syscall) host tests green; fmt + coordination
  clean; BSS budget re-ran green. `driving_award.zig` 5,301 lines.
- `docs/march-m32-wm-migration.md` WMS8 row + `docs/status.md` updated.
  Flip claim to ✅. #628 intentionally left OPEN — multi-PR deletion sequence.
