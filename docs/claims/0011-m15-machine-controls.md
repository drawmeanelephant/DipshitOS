# Claim: M1.5 machine controls — real `reboot`/`shutdown` via EFI Runtime Services `ResetSystem`

- **Owner:** buffy (`agent/buffy/m15-machine-controls`)
- **Prompt / plan:** this slice's agent prompt (planning-first, dated
  2026-08-07); binding inputs: AGENTS.md, `docs/status.md` (hard gate 6,
  claims 0009/0010 marker-ladder evidence), `docs/march-m15.md` (step 17 +
  agent-split row C), ADR 0004 (`docs/decisions/0004-kernel-proper.md`),
  `docs/m15-commands-design.md` (§machine control), `kernel/src/main.zig`,
  `kernel/src/monitor.zig` (`MachineControl` + `MockMachineControl`),
  `tools/verify-unit-tests.sh`, `justfile`, `build.zig`
- **Scope:** M1.5 — new `kernel/src/machine.zig`; two additive edits in
  `kernel/src/main.zig` (pre-exit runtime-services capture + the M15 seam's
  `MachineControl` wiring); `tools/verify-unit-tests.sh` module list;
  `docs/march-m15.md` step-17 row and `docs/status.md` hard-gate-6 pointer
  line. No runner, probe, takeover-path, marker-ladder, or other-doc edits.
- **Depends on:** claims 0009/0010 (observed: runtime `SetVariable` survives
  `ExitBootServices` on VZ; the NVRAM ladder is the working evidence
  channel); the M15 command layer with `MachineControl.disabled()` seam
  (landed). Live observation additionally depends on the VZ serial gate
  (claim 0002, ⛔ blocked — no usable MMIO serial device, kernel halts at
  `M2_SERIA`).
- **Status:** ⛔ live gate blocked 2026-08-07 — real `ResetSystem`
  mechanism shipped + unit-proven and wired; live observation impossible
  this cycle (claim 0002: no usable serial device, kernel halts at
  `M2_SERIA` before the monitor runs, so `ResetSystem` is never invoked).
  No `M2_RST!` / no VM reset observed (evidence `artifacts/m15-machine-*.txt`);
  hard gate 6 stays open.

## Notes

**Goal.** Make `reboot` and `shutdown` real: call the EFI Runtime Services
`ResetSystem` (EFI spec §8.5) from the kernel's post-ExitBootServices state,
replacing `MachineControl.disabled()`. `ResetSystem` is a *runtime* service
— it survives `ExitBootServices`, the same table whose `_setVariable` is
observed working post-exit on VZ (claims 0009/0010). The kernel already maps
`runtime_services_code`/`runtime_services_data` as Normal WB, so the runtime
services code is reachable after the MMU switch. If VZ's firmware does not
actually reset the machine, report that honestly with evidence — never fake
a power-off.

**Design (all in `kernel/src/machine.zig` + minimal wiring).**

1. `machine.zig` implements the `MachineControl` VTable from
   `kernel/src/monitor.zig` (reuse the interface — no monitor redesign):
   reboot → `ResetType.cold`, shutdown → `ResetType.shutdown`, both with
   status 0 (`.success`) and null data. The runtime-services function
   pointer is **injectable** so `zig test` can assert the exact args
   (mirrors `MockMachineControl`'s style). If no pointer was captured,
   return `.not_implemented` (honest).
   - The reset call is made through a function pointer typed
     **non-noreturn** (cast from the raw `_resetSystem` pointer) so that if
     the firmware returns anyway the kernel **parks in WFE** instead of
     running off the end. (Calling a `noreturn`-typed function directly
     makes the park unreachable — the cast is required, and it is ABI-safe:
     same signature, only the declared return type differs.)
   - Evidence channel: reuse the claim-0009 NVRAM variable (`DipshitM2`,
     GUID `M2M2_DIPSHITOS-M`) — write the `M2_RST!` stage immediately
     before the reset call so the host can see in `artifacts/efi-vars.bin`
     that the call fired. (The runner's needle table does not list
     `M2_RST!`; the raw store is the evidence, scanned byte-wise.)
   - Unit tests: reboot→cold, shutdown→shutdown, status 0 + null data,
     no-pointer→`.not_implemented`.
2. `kernel/src/main.zig` — exactly two additive edits plus the seam import:
   (a) pre-exit in `kernel_main`, capture the runtime services table
   (`machine.init(st.runtime_services)` — it survives `ExitBootServices`);
   (b) in the M15 seam, replace `monitor.MachineControl.disabled()` with
   the real control (`machine.control()`). The probe, takeover path, and
   marker ladder are untouched.
3. `tools/verify-unit-tests.sh`: add `machine` to `MODULES`.
4. Docs: `docs/march-m15.md` step-17 row and `docs/status.md` hard-gate-6
   pointer line only.

**Verification (evidence under `artifacts/m15-machine-*.txt`).**

1. `zig fmt --check kernel/src/*.zig` and `zig build` pass — **observed**
   (`artifacts/m15-machine-fmt.txt`, build output in the unit-test run).
2. `zig test kernel/src/machine.zig` passes — 46/46 including the 5 machine
   arg-construction tests: reboot→cold, shutdown→shutdown, status 0 + null
   data, `M2_RST!` persisted before the call, no-pointer→`not_implemented`
   (`artifacts/m15-machine-unit-tests.txt`).
3. `bash tools/verify-unit-tests.sh` passes with `machine` in the module
   list — 50/50 across all eight modules (`artifacts/m15-machine-unit-tests.txt`).
4. Live (Apple silicon, 2026-08-07): booted the VM with a fresh
   `artifacts/efi-vars.bin` and captured what happened
   (`artifacts/m15-machine-live-run.txt`, `artifacts/m15-machine-evidence.txt`).
   **Observed:** the NVRAM ladder is
   `M2_ENTRY → M2_CMAP! → M2_PREX! → M2_EXIT! → M2_MAPD! → M2_MMUP! →
   M2_SERIA` — the kernel boots through the full takeover with the new
   `machine.zig` wired (no regression), then halts at `M2_SERIA`: the serial
   probe finds no usable MMIO device (claim 0002), so the monitor — and
   therefore `reboot`/`shutdown` — is **unreachable** on VZ this cycle.
   `ResetSystem` was never invoked: the raw store contains **no `M2_RST!`**
   byte sequence, `vm-serial.log` is 0 bytes, and the VM never reset
   (nothing called it; the runner simply timed out waiting for serial
   evidence). This closes the live half ⛔ with evidence — hard gate 6
   flips only on an observed reset, and an honest block is a win — while
   the mechanism itself is real and unit-proven and the WFE park fallback
   stays shipped and documented.
