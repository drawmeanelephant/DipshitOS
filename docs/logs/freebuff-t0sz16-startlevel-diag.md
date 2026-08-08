# Log — `freebuff/t0sz16-startlevel-diag`

Append-only per-branch changelog (AGENTS.md). One entry per change.

- **2026-08-08** — *buffy (freebuff/t0sz16-startlevel-diag)*: claim 6460
  claimed → premise verified against current main `fff37a5` and the ARM ARM
  VMSAv8-64 4 KiB stage-1 initial-lookup rule (T0SZ=25/W=39 starts at level
  1; T0SZ=16/W=48 starts at level 0) + Linux arm64 corroboration; the
  current T0SZ=25 L0-rooted hierarchy is a start-level mismatch. Experiment
  = one default-off `-Dt0sz16` build option changing only T0SZ, phase-C TX
  payload unchanged, A/B on VZ. ⬜ claimed → 🔄 in progress.
- **2026-08-08** — *buffy (freebuff/t0sz16-startlevel-diag)*: claim 6460
  done → implemented `-Dt0sz16` (build.zig) + comptime T0SZ in
  `install_identity_map` (mmu.zig) + honest kernel-plan print (evidence.zig)
  + `tools/verify-t0sz16.sh` (class-D, gate-inventory registered). Class-A
  set green; default KERNEL.BIN byte-identical to main; the two phase-C
  kernels differ in exactly one instruction (T0SZ immediate). Class-D A/B on
  real VZ: baseline 0/6 reproduce the known post-MMU hang; candidate T0SZ=16
  completes the full post-MMU TX (phase C returns, used.idx advances, exact
  payload in vm-serial.log, live `dipshit>` shell) in 5/12 boots, 7/12 still
  hang at the same boundary → hypothesis strengthened, not reproducible;
  STOP per prompt; default T0SZ not flipped. Evidence:
  `artifacts/t0sz16-compare-final.txt`, `t0sz16-gate.txt`,
  `t0sz16-report-{baseline,candidate}.txt`, `t0sz16-{baseline,candidate}-{run,marker,serial}-*`,
  `t0sz16-run1/` (first candidate run). ✅ done.
