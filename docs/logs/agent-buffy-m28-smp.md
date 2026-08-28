# Log — `agent/buffy/m28-smp`

## 2026-08-27 — Claim 6438: M28 Symmetric Multi-Processing (SMP)

- **Claim:** 6438
- **Goal:** Symmetric Multi-Processing (SMP) multi-core bringup on Apple Silicon Virtualization.framework (Issue #595, `docs/march-m28.md`).
- **Status:** ✅ PASSED
- **Evidence:**
  - `kernel/src/spinlock.zig`: Native AArch64 atomic spinlock (`cmpxchgWeak`, `yield`, `IrqSaveSpinlock` with DAIF save/restore). Unit tests passing (2/2).
  - `kernel/src/psci.zig`: ARM PSCI v0.2+ calling convention implementation via HVC (`CPU_ON_64` 0xC4000003, `PSCI_VERSION` 0x84000000). Unit tests passing (2/2).
  - `kernel/src/smp.zig`: SMP core management, secondary entry trampoline `secondary_entry_asm` + `secondary_entry`, per-core stacks, and SGI IPI dispatch (`send_ipi`, `handle_sgi`). Unit tests passing (2/2).
  - `kernel/src/mmu.zig`: Added `setup_secondary_core()` programming `MAIR_EL1`, `TCR_EL1`, `TTBR0_EL1`, and `SCTLR_EL1` (MMU, caches, instruction cache) on secondary cores.
  - `kernel/src/gic.zig`: Added `init_secondary()` for secondary GICv3 redistributor wake, SGI Group 1 enablement, and CPU system registers (`ICC_SRE_EL1`, `ICC_PMR_EL1`, `ICC_IGRPEN1_EL1`). Updated `select_redist_frame` with exact per-core stride calculation. Unit tests passing (25/25).
  - `kernel/src/timer.zig`: Added `init_secondary()` for secondary core `CNTP_CTL_EL0` / `CNTP_CVAL_EL0` arming.
  - `kernel/src/scheduler.zig`: Integrated `current_by_core` and `current_task_for_core()`. Unit tests passing (326/326).
  - `kernel/src/monitor.zig`: Added `smp` command reporting CPU topology, online cores, and per-core task state. Unit tests passing (547/547).
  - `tools/verify-unit-tests.sh`: All 42 present monitor modules and 1000+ tests passed.
  - `bash tools/verify-live-smp.sh`: ALL 1 BOOT(S) PASSED on Apple Silicon Virtualization.framework hardware (`artifacts/live-smp-gate.txt`):
    - `smp: cores=2 online=2`
    - `core 0: bsp mpidr=0x0000000080000000 state=online task=shell`
    - `core 1: ap  mpidr=0x0000000080000001 state=online task=idle`
    - Shell responsiveness and parallel execution verified (`rx-smp-ok`, no exception park).
  - `bash tools/verify-coordination.sh`: ok.
