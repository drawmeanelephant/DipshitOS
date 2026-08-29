# Claim: WMS2 — kernel render-server register (slot 65 `sys_wmctl`, kind 18 `COMPOSITE_TICK`)

- **Owner:** buffy (`agent/buffy/wms2-wmctl-register`)
- **Issue:** https://github.com/drawmeanelephant/DipshitOS/issues/622 (WMS2 of 10, milestone 16)
- **ADR:** 0015 (seam A render-server) as accepted by claim 1484 (WMS1, #621); slot-65 subcommand encoding frozen in the ADR 0007 amendment (claim 1484): `WMCTL_REGISTER=1` / `WMCTL_SET_WINDOW=2` / `WMCTL_REQUEST_PRESENT=3`; error contract `EACCES` (-7) WM-exclusive refusal (seat taken / caller not the WM), `ENOSYS` (-4) no WM registered, `EINVAL` (-1) unknown cmd / bad args, `ENXIO` (-9) REGISTER with no GPU / unarmed compositor.
- **Status:** ✅ done
- **Heartbeat:** 2026-08-29
- **Touches:** `kernel/src/wm_server.zig` (new — the render-server register module), `kernel/src/syscall.zig` (slot 65 handler + dispatch row + `implemented_count` 65→66), `kernel/src/scheduler.zig` (tick-seam tick delivery + exit-path teardown), `kernel/src/monitor.zig` (`wm` report row + `syscalls` implemented=66), `kernel/src/shell.zig` (idle-drain guard + fallback report), `user/src/wndstub.zig` + `build.zig` + `image/make-image.sh` (WNDSTUB.BIN registrant stub + ESP embedding), `tools/verify-live-wmctl-register.sh` (new class-B gate), `tools/sweep-vz.sh` (gate registration), `tools/verify-unit-tests.sh` (wm_server module in the suite), `docs/march-m32-wm-migration.md` (WMS2 row), `docs/status.md` (M32 paragraph), `docs/logs/agent-buffy-wms2-wmctl-register.md`, `docs/claims/8482-wms2-wmctl-register-seam.md`
- **Depends on:** WMS1 (claim 1484, merged via PR #631) — slot-65 encoding frozen in ADR 0007 amendment; kind 18 routing-restricted per ADR 0009 D2
- **Blocks:** WMS3 (WM server process), WMS4–WMS6 (policy drain-out), WMS8
- **Heartbeat:** 2026-08-29
- **Status:** ✅ done

## Scope (from issue #622, verbatim commitments)

1. **Slot 65 handler** in `kernel/src/syscall.zig` + the `sys_wmctl` dispatch state **beside the unchanged shim** in `kernel/src/driving_award.zig`, per the WMS1-frozen ADR 0007 encoding (REGISTER=1 / SET_WINDOW=2 / REQUEST_PRESENT=3; `EACCES` seat-taken/not-the-WM; `ENOSYS` no WM registered; `EINVAL` unknown cmd; `ENXIO` REGISTER with no GPU / unarmed compositor). `implemented_count` 65 → 66.
2. **REGISTER**: registering process becomes the active compositor. Second registrant → `EACCES`; no WM registered → all slot-65 calls `ENOSYS`.
3. **Zero-regression pacing**: when no WM is registered, nothing changes — the shell idle `drain` keeps compositing exactly as today; every pre-M32 gate stays byte-identical. Only after REGISTER does composite pacing move to the tick path. Registration is one flag check on the hot path.
4. **COMPOSITE_TICK (kind 18)** delivery to the registered WM's process event queue (arg0 = present sequence, arg1 = reserved) — same delivery machinery as the E-series app events (`events.push`), once per scheduler tick pass while a WM is registered.
5. **REQUEST_PRESENT**: kernel transfers+flushes the scanout now (the G1 seam, `virtio_gpu`), observable as a present counter.
6. **WM-death teardown**: if the registered WM process exits or is killed, the kernel unregisters it and pacing falls back to the shell idle shim automatically (mirrors `close_owner(pid)` semantics in the scheduler exit path).
7. **Host tests**: register / refuse-second / EACCES-for-outsider / ENOSYS-when-empty / tick-delivery / teardown-on-exit.
8. **New class-B gate** `tools/verify-live-wmctl-register.sh`: WNDSTUB.BIN (minimal registrant) registers, receives ≥1 COMPOSITE_TICK, issues REQUEST_PRESENT (present counter advances), exits, kernel reports fallback (`wm: unregistered, shim resumed`); `syscalls` shows `65 sys_wmctl calls=N`, implemented 66. Default-VM runs stay byte-identical.
9. **Monitor `wm` row**: registered pid, present sequence, tick/present counters.

## Zero-regression rule (binding)

When no WM is registered, nothing changes: the shell idle `drain` keeps compositing exactly as today; every pre-M32 gate stays byte-identical. Only after `REGISTER` does composite pacing move to the tick path. Registration is one flag check on the hot path — the shim path reads unchanged in this card's diff.

## Out of scope

The real WM server process (WMS3), policy (WMS4–WMS6), IPC protocol (WMS7), kernel slimming (WMS8), chrome descriptors (WMS4 freezes the payload). Changing the shim's own compositing code — the shim path reads unchanged in this card's diff.

## Acceptance (gate)

New class-B gate `tools/verify-live-wmctl-register.sh` PASS on VZ: WNDSTUB.BIN registers, receives ≥1 `COMPOSITE_TICK`, issues `REQUEST_PRESENT` (present counter advances), exits, kernel reports fallback (`wm: unregistered, shim resumed`); `syscalls` shows `65 sys_wmctl calls=N`, implemented 66. Default-VM runs (no registrant) stay byte-identical; the full `verify-vz` aggregate re-runs green; M18–M31 window/desktop gates unchanged.

## Notes / decisions applied

- Frozen contract (ADR 0007 amendment, claim 1484): `WMCTL_REGISTER=1` / `WMCTL_SET_WINDOW=2` / `WMCTL_REQUEST_PRESENT=3`; `EACCES` (-7) WM-exclusive refusal (seat taken / caller not the WM); `ENOSYS` (-4) no WM registered; `EINVAL` (-1) unknown cmd / bad args; `ENXIO` (-9) REGISTER with no GPU / unarmed compositor.
- Kind 18 `COMPOSITE_TICK` is the first routing-restricted kind (ADR 0009 D2 note): delivered ONLY to the registered WM's process queue via the existing `events.push` machinery (same as E-series app events); never generated when no WM is registered.
- Present-sequence counter (arg0, monotonic u32) is the parity-cards' observability primitive — reported in the monitor `wm` row from day one.
- Tick cadence: once per scheduler tick pass while a WM is registered (the same tick seam `app_timers` fires from, per WMS1 frozen decision 3).
- WM-death teardown mirrors the `close_owner(pid)` window-teardown semantic in the scheduler exit path: on WM process exit, the kernel unregisters it, pacing falls back to the shell idle shim automatically, and the kernel reports `wm: unregistered, shim resumed`.
- A hung WM (not exited) is WMS3's watchdog problem — out of scope here per the issue's risk note.
- BSS budget: registry is fixed BSS (one registrant + counters), no heap; the 7.0 MiB `.bss` budget gate (`just verify-bss-budget`) must stay green.

## Verification plan

- Class A: `zig fmt --check`, `zig build`, `zig build test` (new host tests for register/refuse/EACCES/ENOSYS/tick/teardown), `just verify-bss-budget` (BSS budget stays green), `bash tools/verify-coordination.sh`.
- Class B (Apple silicon): `bash tools/verify-live-wmctl-register.sh` (new gate) + the full `verify-vz` aggregate re-run green with the default VM byte-identical.
