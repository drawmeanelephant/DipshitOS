# Claim: M1.5 — T0SZ start-level diagnostic: does correcting the 4 KiB translation initial lookup level (T0SZ 25→16) restore post-MMU virtio-pci console TX? (class-D experiment)

- **Owner:** buffy (`freebuff/t0sz16-startlevel-diag`)
- **Prompt / plan:** task prompt 2026-08-08 — narrow class-D experiment on the
  current M1.5 blocker: does the current AArch64 translation-table
  start-level mismatch (T0SZ=25 starts the 4 KiB stage-1 walk at level 1,
  while the built tables are an L0-rooted L0→L1→L2→optional-L3 hierarchy
  with TTBR0 at the L0 root) explain the first post-MMU virtio-pci console
  failure? Diagnostic only — NOT permission to fix the console, redesign the
  MMU, or rewrite virtio.
- **Scope:** one default-off diagnostic build option that changes ONLY T0SZ
  from 25 to 16 in `install_identity_map()`; page tables byte-for-byte
  unchanged; TTBR0 same root; MAIR/attributes/BAR window/blanket/cache
  maintenance unchanged; no-TLBI behavior kept; virtio transport semantics,
  queue setup, feature negotiation, notify width, DMA buffers, used-ring
  handling and the claim-0020 phase-C experiment location unchanged; no RX;
  no allocator/GIC/timer/scheduler/fs/network/graphics work. A controlled
  A/B comparison on real Apple-silicon VZ hardware (≥6 baseline + ≥6
  candidate boots, fresh EFI variable store per boot) using the existing
  claim-0020 phase-C TX experiment as payload and observation point.
- **Depends on:** claim 0020 (phase C = first post-MMU TX; hang at the first
  common-cfg read), claim 0021 (firmware TCR/TTBR capture: T0SZ=28, initial
  level L1, BAR as 1 GiB Device block), ADR 0004 D3 (identity-map install,
  no-TLBI), ADR 0006 (MMU debt boundary), claim 0010 (no-TLBI survival)
- **Status:** ✅ done 2026-08-08 — **T0SZ=16 lets the first post-MMU virtio-pci TX complete end-to-end in 6/18 boots across three independent runs (2/6, 3/6, 1/6): phase C returns, `used.idx` advances, exact payload in `vm-serial.log`, kernel reaches the live `dipshit>` shell; 12/18 still hang at the same boundary — hypothesis strengthened, not reproducible** (evidence under `artifacts/t0sz16-compare-final.txt`, `t0sz16-report-baseline.txt`, `t0sz16-report-candidate-18.txt`, `t0sz16-gate.txt`, `t0sz16-{baseline,candidate}-{run,marker,serial}-*.{txt,log}`, `t0sz16-run{1,2,3}/` per-run batches)

## Notes

**Premise (verified 2026-08-08, current main `fff37a5`):** `mmu.zig`
`build_identity_map()`/`map_low_identity()` builds an L0 → L1 → L2 →
optional L3 hierarchy in a fixed BSS carve-out with TTBR0 pointed at the L0
root (`table_storage[0]`), and `install_identity_map()` programs
`TCR_EL1.T0SZ = 25` (`const tcr: u64 = 25 | (ips << 32)`). Under the ARM
ARM VMSAv8-64 4 KiB stage-1 rules (Table D4-11 / D5-10, "initial lookup
level"), the initial lookup level is a function of W = 64 − T0SZ:
W 40–48 → level 0, W 34–39 → level 1, W 32–33 → level 2, W 26–31 → level 3
(4 KiB granule). T0SZ=25 (W=39) therefore starts the walk at **level 1**,
while T0SZ=16 (W=48) starts at **level 0**. The current source therefore
programs the walker to treat TTBR0's target (a level-0 table) as a level-1
table — a start-level mismatch. Corroborated by Linux arm64 (4 KiB pages:
39-bit VA → 3 table levels, top level = hardware L1; 48-bit VA → 4 levels,
top level = L0 — `pgtable-hwdef.h` `PGDIR_SHIFT =
ARM64_HW_PGTABLE_LEVEL_SHIFT(4 - PGTABLE_LEVELS)`) and the kernel's memory
layout doc ("3 levels … 39-bit; 4 levels … 48-bit"). Note: the repo's own
`evidence.zig fw_initial_level()` comment ("W 39..48 → L0") is off-by-one at
the W=39 boundary; it was never exercised there (the firmware walk ran at
W=36 → L1 under both readings, claim 0021), and the empirical post-switch
survival (claim 0010) is explained by the no-TLBI stale-firmware-TLB-entry
mechanism, not by the tables resolving.

**Hypothesis under test:** at T0SZ=16 the walk starts at level 0, matching
the built L0-rooted hierarchy, so a post-switch TLB miss that must walk the
kernel's tables resolves correctly — including the first post-MMU read of
the virtio BAR window (claim 0020 phase C), which currently hangs. If phase
C then returns, `used.idx` advances, and the exact payload reaches
`vm-serial.log`, the start-level mismatch is (part of) the explanation.

**Experiment design (smallest possible variant):**

- `build.zig`: ONE default-off diagnostic option `-Dt0sz16` (comptime bool).
- `kernel/src/mmu.zig`: `install_identity_map()` selects `t0sz = 16` when
  the option is set, else the production `25`. Nothing else changes.
- `kernel/src/evidence.zig`: the claim-0021 kernel-plan print ("TCR=…")
  uses the comptime-selected T0SZ instead of hard-coded 25, so a
  `-Dfw-mmu-capture` + `-Dt0sz16` build prints the true planned TCR. No
  transport or marker semantics change.
- `tools/verify-t0sz16.sh` (new, class-D): builds baseline
  (`-Dtx-transition-c=true`, T0SZ=25) and candidate (`-Dtx-transition-c=true
  -Dt0sz16=true`), boots each N times (default 6) with a fresh EFI variable
  store per boot, saves per-boot runner output / marker ladder / serial log
  under `artifacts/` with baseline/candidate names, and reports entered /
  flush-returned / used.idx-advanced / payload-in-serial / last-marker per
  boot plus a comparison table. Registered in `docs/gate-inventory.md`
  (class D).

**Success (support for the hypothesis) requires ALL of:** T0SZ=25 baseline
reproduces the known post-MMU failure, AND T0SZ=16 repeatedly lets phase C
return, AND `used.idx` advances, AND the exact TX payload reaches
`vm-serial.log`. A compile, boot, marker advance, or returning MMIO read
alone is NOT "fixed".

**Stopping rules:** if T0SZ=16 fails at the same boundary → falsified (do
not try another MMU variable); if it moves the failure later but no TX →
record the new smallest interval and stop; if baseline no longer reproduces
the historical failure → premise changed, investigate only enough to
identify what superseded it. The default T0SZ stays 25 regardless of the
outcome — a positive result ends with evidence + a recommendation for the
smallest production follow-up, not a silent flip.

**Verification discipline:** the diagnostic conclusion requires class-D real
VZ evidence; the class-A suite proves build/test portability only. This
claim does not flip the production default.

## Result (2026-08-08) — class-D A/B on real VZ hardware

**Environment:** real Apple-silicon VZ host (macOS 27.0 build 26A5388g,
arm64, zig 0.16.0, Swift 6.2.3). Revision `fff37a5e6af8476c273dc959aefce0f412e11554`
+ 9 dirty files (this branch's changes), branch
`freebuff/t0sz16-startlevel-diag`. Fresh EFI variable store per boot,
`--timeout 25`, phase-C payload `DIPSHITOS TRANSITION TX\n` (claim 0020).

The two phase-C kernels differ in EXACTLY one instruction (objdump diff of
the full ELF disassembly): `install_identity_map`'s T0SZ immediate
(`mov w8, #0x19` = 25 baseline vs `mov w8, #0x10` = 16 candidate); every
other instruction, all tables, TTBR0 root, MAIR, cache maintenance and the
no-TLBI switch are identical. Default builds are byte-identical to main
(KERNEL.BIN sha256 `55325752e3f85d1f495f46c00e9f5f387f399f3215efa325904a6fc5d41e8919`
on both).

**A/B matrix (baseline 6 boots, candidate 18 boots — three runs of 6):**

| boot | entered | returned | used.adv | payload | alive | last marker |
|------|---------|----------|----------|---------|-------|-------------|
| baseline-01..06 | 1/1 each | 0 | 0 | 0 | 0 | `M2_TXST!` (all 6) |
| candidate-01..03,06 (run1) | 1 | 0 | 0 | 0 | 0 | `M2_TXST!` |
| candidate-04,05 (run1) | 1 | **1** | **1** | **1** | **1** | `M2_TXPL!` |
| candidate-01,04,06 (run2) | 1 | 0 | 0 | 0 | 0 | `M2_TXST!` |
| candidate-02,03,05 (run2) | 1 | **1** | **1** | **1** | **1** | `M2_TXPL!` |
| candidate-01,02,03,05,06 (run3) | 1 | 0 | 0 | 0 | 0 | `M2_TXST!` |
| candidate-04 (run3) | 1 | **1** | **1** | **1** | **1** | `M2_TXPL!` |

**Baseline total: 0/6 returned, 0/6 used-advanced, 0/6 payload — the known
post-MMU failure reproduces on every boot** (ladder ends `M2_MMUP! →
M2_TRC1! → M2_TXST!`, 0 serial bytes: the first post-switch common-cfg read,
claims 0018/0020).

**Candidate total: 6/18 returned + used-advanced + payload across three
independent runs (2/6, 3/6, 1/6); 12/18 hang at the same boundary.** On the
6 successful boots the ladder is complete:
`M2_TRC1! → M2_TXST! → M2_TXNT! → M2_TXPL! → M2_TRC2! → M2_TRCU! →
M2_RAW! → M2_READY → M2_TXST!/M2_TXNT!/M2_TXPL! (banner) → M2_TXOK!`, and
`vm-serial.log` contains the exact `DIPSHITOS TRANSITION TX` payload, the
full banner + memory-map print, `kernel terminal state`, and a live
`dipshit>` prompt — i.e. the ENTIRE post-MMU console path works on those
boots, which has never been observed at T0SZ=25.

**Conclusion — hypothesis strengthened, not proven reproducible:**

- The start-level mismatch is a REAL architecture defect (ARM ARM
  D4.2.5/Table D4-11: 4 KiB stage-1, T0SZ=25/W=39 → initial level 1;
  T0SZ=16/W=48 → level 0; corroborated by Linux arm64 3-vs-4-level
  layouts). The current T0SZ=25 build programs a level-1 walk over an
  L0-rooted tree.
- Correcting ONLY T0SZ to 16 demonstrably CAN restore the first post-MMU
  virtio-pci access: 6/18 boots complete TX end-to-end (return, used.idx
  advance, exact payload in serial) across three independent runs, vs 0/6 at
  baseline. When it works, the whole kernel console comes up.
- The discriminator is NOT reproducible on VZ: 12/18 candidate boots still
  die at the same first-read boundary (per-run success: 2/6, 3/6, 1/6 — a
  stable ~1/3 rate, not a single lucky run). The failure is therefore not
  *only* the start level; a residual boot-varying component remains at the
  same site. That residual is consistent with the ADR 0006 debt — the
  no-TLBI design keeps stale firmware TLB entries in play, and the VZ
  re-walk/MMIO behavior is uncharacterized — but this experiment does not
  characterize it further.
- Per the prompt's rules, this is a STOP point (no second speculative MMU
  variable). The production default T0SZ stays 25. Smallest production
  follow-up if pursued: keep the corrected start level (T0SZ=16 with the
  same tables) AND characterize the remaining VZ TLB/re-walk failure in the
  same change (ADR 0006 invalidation list), with a regression gate.

**Class-A verification (green, proves portability only):** `zig fmt --check`,
all unit tests, `zig build test-console` (transcript byte-identical),
`zig build`, `zig build image`, `zig build inspect`, swift runner build,
`zig build context`, `verify-coordination`, `test-coordination` (15/15),
`verify-mmu-debt`. The class-D conclusion above rests ONLY on the real VZ
A/B evidence.
