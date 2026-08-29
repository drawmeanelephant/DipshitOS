# Log — agent/buffy/wms3-wnd-server

> Append-only per-branch changelog (AGENTS.md multiagent rules). Newest last.

## 2026-08-29 — WMS3 claimed (issue #623)

- Claimed **WMS3 — WM server process scaffold (WND.BIN + drift-guard extraction)**
  as `docs/claims/0623-wms3-wnd-server.md` (status 🔄, heartbeat 2026-08-29).
  Branch `agent/buffy/wms3-wnd-server` cut from the WMS2 branch (PR #633,
  commit f8dbe39) so it builds on the slot-65 register + kind-18 tick
  delivery — WMS3 legitimately depends on WMS2's code being present, so the
  WMS3 PR is dependency-stacked on #633.
- Scope per issue #623: `WND.BIN` (long-lived EL0 WM server — REGISTER, then
  a `sys_wait_event` loop servicing kind-18 ticks with REQUEST_PRESENT at its
  own cadence); bounded tick budget per wake (no busy-spin; a hung WM cannot
  stall the kernel); single-source pure-logic extraction into a shared module
  (`kernel/src/wnd_core.zig`) compiled by BOTH the kernel shim and the WM
  server (drift guard — first decision recorded: one shared source file, not
  a checked copy); a `wnd start` shell bootstrap (infrastructure, NOT in
  `APPS.TXT`; default VM stays shim-only); kill+re-register crash story.
- Declared touches in the claim's `Touches:` list; depends on claims 1484
  (WMS1) + 0622 (WMS2) + 7786 (kill).
- **Heartbeat:** 2026-08-29.