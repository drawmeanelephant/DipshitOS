# Log — agent/buffy/wms3-wnd-server

> Append-only per-branch changelog (AGENTS.md multiagent rules). Newest last.

## 2026-08-29 — WMS3 claimed (issue #623)

- Claimed **WMS3 — WM server process scaffold (WND.BIN + drift-guard extraction)**
  as `docs/claims/3881-wms3-wnd-server.md` (status 🔄, heartbeat 2026-08-29).
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
  (WMS1) + 8482 (WMS2) + 7786 (kill).
- **Heartbeat:** 2026-08-29.- **2026-08-29 — WMS3 complete; live gate PASS on real VZ.** `verify-live-wnd-server.sh` (3 scripted phases) green: shim mode default, `wnd start` → REGISTER (slot 65) → `wnd: registered`; kind-18 COMPOSITE_TICK serviced and REQUEST_PRESENT issued at the server's own cadence (`wm: registered pid=1 present_seq=1 presents=1 ticks=7` while the shell idle drain was gated off); `kill WND.BIN` → exit status 137 → WMS2 teardown → `wm: unregistered, shim resumed` fallback → fresh `wnd start` re-registers into the freed seat; shell responsive (`rx-wnd-server-ok`). All 12 gate checks + 24/24 unit tests + fmt + build + BSS budget (688 KiB headroom) + coordination green.
- **Root cause found via the built-in tracer (`strace exec WND.BIN`), a great debugging seam:** the alive-marker `sys_write` returned `0xfffffffffffffffd` (EFAULT). The marker string `"wnd: present\n"` is 13 bytes but the naked payload passed `mov x2, #14`; the extra byte crossed the program's content-region end (VA 0x4000C9) so `uaccess.range_ok` refused the copy-in and the write silently vanished (WND does not check the write result). The registered marker (16 bytes, exact) fit exactly and printed. Fixed the count to 13; the marker now prints and the gate observes the pacing. Note for future naked-asm payloads: exact string lengths matter — an over-count that crosses the content region is a silent EFAULT, not a crash.
- **Test-gap honesty note:** the earlier session added `wnd` to `verify-unit-tests.sh`'s MODULES, but that list resolves `kernel/src/<name>.zig` and the WND.BIN source lives at `user/src/wnd.zig` — so the module was silently skipped and the marker-shape pin test never ran under the gate. That is how the 14-vs-13 marker-length bug (above) slipped through a "green" unit suite. Fixed the pin to the true length (13) and removed the misleading `wnd` entry from MODULES (the WND.BIN contract is enforced by the live gate's grep targets, and the single-source compile of `wnd_core` is enforced by the WND.BIN build). `wnd_core` remains a real kernel module and its parity tests still run.
