# Claim: WMS3 — WM server process scaffold (WND.BIN + drift-guard extraction)

- **Owner:** buffy (`agent/buffy/wms3-wnd-server`)
- **Issue:** https://github.com/drawmeanelephant/DipshitOS/issues/623 (WMS3 of 10, milestone 16)
- **Stacked on:** `agent/buffy/wms2-wmctl-register` (PR #633) — the WMS3 PR builds on WMS2's code
- **ADR:** 0015 (seam A render-server); slot-65 encoding + kind-18 from WMS1/WMS2 (claims 1484/0622)
- **Status:** 🔄 agent/buffy/wms3-wnd-server
- **Heartbeat:** 2026-08-29
- **Depends on:** WMS2 (claim 0622) — `sys_wmctl` slot 65 + kind-18 `COMPOSITE_TICK` delivery + WM-death teardown must be present (this branch is cut from the WMS2 branch so it builds on them)
- **Blocks:** WMS4–WMS6 (policy drain-out), WMS7

## Scope (from issue #623)

1. **WND.BIN** (`user/src/wnd.zig`): a long-lived EL0 process that never exits — calls `sys_wmctl REGISTER` at startup, then loops on `sys_wait_event` (slot 22) servicing kind-18 `COMPOSITE_TICK`, issuing `REQUEST_PRESENT` at its own cadence. The FIRST present pacing that is not the shell idle.
2. **Own event loop with a bounded tick budget per wake**: the WM blocks in `sys_wait_event` between wakes (no busy-spin), does bounded work per wake, and yields — a hung WM cannot stall the kernel (the WMS2 exit fallback covers exit; this covers hang).
3. **Single-source logic extraction (the drift guard):** lift `driving_award`'s PURE geometry/registry/hit-test/focus/clamp logic into a dependency-free shared module compiled by BOTH the kernel shim and the WM server, so the two cannot behaviorally drift while both are live. **Decision (this claim's first): a single shared source file (`kernel/src/wnd_core.zig`) imported by both `driving_award.zig` (kernel) and `user/src/wnd.zig` (EL0)** — one physical source, no checked copy to drift. `driving_award` delegates its hit-test / workspace-visibility / resize-clamp / title-layout to the shared functions; `wnd.zig` imports the same module. Extract ONLY what WMS4–WMS6 need (rects, registry, z-order, hit-test, focus/clamp) — not the whole 4,740-line file.
4. **Bootstrap:** a shell/monitor launch step starts WND.BIN (`wnd start`) — infrastructure, NOT in `APPS.TXT`. The default VM stays shim-only (no auto-start), so every pre-M32 gate is byte-identical.
5. **Crash story end-to-end:** kill WND.BIN → kernel unregisters (WMS2 teardown) → shell idle resumes compositing → windows stay visible → a fresh WND.BIN re-registers.

## Out of scope
- Any behavior change — while registered, WND.BIN only PACES (chrome/geometry/z-order policy stay in the kernel shim until WMS4–WMS6).
- App↔WM IPC (WMS7). Desktop chrome (WMS6). Moving policy out (WMS4+).

## Zero-regression rule
Default VM (no `wnd start`) is byte-identical to pre-M32. The `wnd start` launch path is opt-in. The drift-guard extraction is pure-function delegation with identical semantics (host parity tests pin it); the shell/monitor transcript tests + full unit suite must stay green.

## Acceptance (gate)
New class-B sibling of `verify-live-wmctl-register.sh`: WND.BIN boots, registers, services ticks, presents at its own cadence (present-sequence advances while the shell idle is idle); `wm` monitor row shows the registered pid; kill + re-register cycle proves the fallback; the shim-intact default VM stays green.

## Notes / decisions

- Shared module placement: `kernel/src/wnd_core.zig`, dependency-free (pure math + a minimal pure `WindowGeom` row; NO kernel-module imports). `@import` from `user/src/wnd.zig` via a relative path. Single-source (not a checked copy), which is the whole point of the drift guard.
- The kernel side keeps its public API identical; each pure helper delegates to `wnd_core` with the same inputs, so behavior is unchanged.
- Present cadence: WND.BIN issues REQUEST_PRESENT every N COMPOSITE_TICKS (its own pacing), writing a periodic alive marker so the live gate can observe it pacing while the shell idle drain is a no-op (WM registered → shell `drain` path is gated off by WMS2).
- Kill+re-register: the `kill <pid>` monitor command (claim 7786) + WMS2 exit-path unregister (claim 0622) + a fresh `wnd start` — the seat is free after teardown, so re-register succeeds.

## Touches
`kernel/src/wnd_core.zig` (new — shared pure module), `kernel/src/driving_award.zig` (delegate pure helpers), `user/src/wnd.zig` (new — WND.BIN), `build.zig` (forty-eighth ESP program), `image/make-image.sh` + `image/mkfat32.py` (WND.BIN embedding), `kernel/src/monitor.zig` + `kernel/src/shell.zig` (`wnd start` bootstrap + server report), `tools/verify-live-wnd-server.sh` (new class-B gate), `tools/sweep-vz.sh`, `tools/verify-unit-tests.sh`, docs (claim/log/march/status).

## Verification plan
- Class A: `zig fmt --check`, `zig build`, unit tests (new wnd_core parity + WND.BIN module + wm_server), BSS budget, `bash tools/verify-coordination.sh`.
- Class B: `bash tools/verify-live-wnd-server.sh` on VZ + default-VM regressions (the WMS2 gate and a spot M-series gate stay green).