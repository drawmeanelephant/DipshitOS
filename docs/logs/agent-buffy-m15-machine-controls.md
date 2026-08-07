# Log — `agent/buffy/m15-machine-controls`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-07** — **Claim (buffy, `agent/buffy/m15-machine-controls`):**
  claimed M1.5 machine controls — real `reboot`/`shutdown` via EFI Runtime
  Services `ResetSystem` (claims `docs/claims/0011-m15-machine-controls.md`,
  Status 🔄). Plan written first, per the planning-first gate: new
  `kernel/src/machine.zig` implementing the monitor `MachineControl` VTable
  with an injectable reset function pointer (unit-testable arg
  construction), `M2_RST!` marker via the claim-0009 NVRAM channel, WFE
  park fallback if the firmware returns anyway; two additive edits in
  `kernel/src/main.zig` (pre-exit `machine.init(st.runtime_services)` +
  the M15 seam swap); `tools/verify-unit-tests.sh` module list; march-m15
  step-17 row and status.md hard-gate-6 pointer. 🔄 in progress — no code
  written yet.
- **2026-08-07** — **M1.5 machine controls slice done (buffy,
  `agent/buffy/m15-machine-controls`):** implemented real
  `reboot`/`shutdown` via EFI Runtime Services `ResetSystem` in new
  `kernel/src/machine.zig` — a `MachineControl` implementation (monitor
  VTable reused as-is) whose reboot→cold / shutdown→shutdown calls issue
  `ResetSystem(type, 0, 0, null)` through an injectable non-noreturn
  function pointer (so `zig test` asserts exact args and the kernel parks
  in WFE if firmware returns anyway), writing the `M2_RST!` stage to the
  claim-0009 `DipshitM2` NVRAM variable immediately before the call;
  honest `.not_implemented` when no runtime services were captured. Wired
  with exactly two additive edits in `kernel/src/main.zig` (pre-exit
  `machine.init(st.runtime_services)` + the M15 seam swap
  `disabled()` → `machine.control()`); `machine` added to
  `tools/verify-unit-tests.sh` MODULES; `docs/march-m15.md` step-17 row and
  `docs/status.md` hard-gate-6 pointer updated. **Observed:** `zig fmt
  --check` pass, `zig build` pass, `zig test kernel/src/machine.zig` 46/46
  pass (5 machine tests incl. reboot→cold, shutdown→shutdown, no-pointer→
  not_implemented), `verify-unit-tests.sh` 50/50 pass, `zig build
  test-console` transcript byte-identical, `zig build image` pass,
  `verify-coordination.sh` pass (evidence `artifacts/m15-machine-{fmt,
  build,unit-tests}.txt`). **Live (VZ, 2026-08-07):** ladder
  `M2_ENTRY → M2_CMAP! → M2_PREX! → M2_EXIT! → M2_MAPD! → M2_MMUP! →
  M2_SERIA` (`artifacts/m15-machine-live-run.txt`) — the kernel boots the
  full takeover with machine.zig wired (no regression) but halts at
  `M2_SERIA`: no usable serial device (claim 0002), so the monitor is
  unreachable and `ResetSystem` was never invoked — no `M2_RST!` in the
  raw store, `vm-serial.log` 0 B, no VM reset observed
  (`artifacts/m15-machine-evidence.txt`). Hard gate 6 stays open; claim
  0011 closed ⛔ (live) with the mechanism ✅ (unit-proven).
