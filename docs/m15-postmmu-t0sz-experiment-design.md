# M1.5 — post-MMU T0SZ experiment: start-level mismatch vs. residual hang (design + pilot)

Status: piloted on real VZ hardware ✅ (claim 7896) · Date: 2026-08-08 ·
Claim: `docs/claims/7896-t0sz16-residual-separation.md` · Follows from:
claim 6460 (T0SZ 25→16 restored post-MMU virtio TX in only 6/18 boots),
claim 0010, claim 0018, claim 0020, claim 0021, ADR 0006.

## 1. Goal

Characterize *why* T0SZ=16 restored post-MMU virtio TX in only 6/18 boots
and design a deterministic experiment that separates the **start-level
mismatch** (translation defect: T0SZ=25 forces a level-1 start over
L0-rooted tables) from the **residual hang** (the ~2/3 of boots that still
fail at the first post-switch MMIO read even with a correct walk).

## 2. Mechanism being tested

The kernel's tables are L0-rooted. Production programs T0SZ=25 → W=39 →
the 4 KiB stage-1 walk starts at **level 1** (ARM ARM Table D4-11;
Linux arm64 corroborates: 39-bit = 3 levels, top table = hardware L1), so
the hardware reads TTBR0's table as an L1 table. The built ROOT only
populates entry 0, so **any fresh walk of a VA ≥ 1 GiB faults**
(ROOT[1..3] = 0). The kernel has no exception vectors, so a translation
fault is an indistinguishable hang.

The **no-TLBI crutch (ADR 0006)** leaves stale *firmware* TLB entries
live across the switch. Under T0SZ=25 those stale entries are the only
thing that lets the post-switch ladder work at all; when the virtio BAR's
entry has been evicted, the first fresh walk faults. This makes TLB state
the uncontrolled, boot-varying variable — which is why the rate is
6/18 rather than 0 or 18/18.

The deterministic lever: **`tlbi vmalle1; dsb ish; isb` immediately after
the switch** (new `-Dtlbi-after-switch` build option), so the FIRST
post-switch access must re-walk. Then a **cold-address probe battery**
(`-Dwalk-probe`) reads sentinel addresses, each bracketed by an NVRAM
marker (`M2_WP_00`…`M2_WP_05`), so the ladder NAMES the first address
that does not resolve:

| probe | address | what it proves |
|-------|---------|----------------|
| P1 | kernel's own BSS word (~2 GiB RAM) | the walk serves RAM at the kernel's own VA |
| P2 | `0x4f000000` (ram-hi, 1.23 GiB) | conventional RAM, high region |
| P3 | `0x4e000000` (ram-mid, 1.22 GiB) | conventional RAM, mid region |
| P4 | `0x40001000` (ram-lo, 1 GiB + 4 KiB) | conventional RAM, first page |
| P5 | `0x100010000` (virtio-pci console BAR) | a real device window (readable pre-exit, claim 0013) |

All probes are ≤ 2^39, all mapped by the identity map, and the battery is
RAM-only plus the BAR, so a read can never hang on an unbacked Device
window. Values fold into a volatile `probe_sum` so the loads are
observable and unelidable.

## 3. The four cells

| cell | flags | question |
|------|-------|----------|
| A | `-Dtlbi-after-switch` (T0SZ=25) | does the first post-TLBI access fault? (start-level mismatch, deterministic) |
| B | `-Dtlbi-after-switch -Dt0sz16 -Dwalk-probe` | with an empty TLB and a correct walk, does phase C complete every boot? (residual is or is not translation) |
| C | `-Dwalk-probe` (T0SZ=25, no TLBI) | which addresses does the stale-TLB crutch actually cover? (TLB-coverage survey) |
| D | `-Dwalk-probe -Dt0sz16` (no TLBI) | claim-6460 residual reproduction with the probe battery live |

Runner: `bash tools/verify-t0sz16-walkprobe.sh` (cells via `CELL=…`,
boots via `BOOTS=…`), fresh EFI variable store per boot, evidence under
`artifacts/walkprobe-*`. Default builds stay byte-identical (KERNEL.BIN
sha `55325752…`) — the diagnostics are class-D only and a payload hit
does NOT pass claim 0002.

## 4. Pilot results (real VZ hardware, this host, 2026-08-08)

3 boots per cell, fresh store per boot, decoded via the ADR-0004 marker
ladder (host-side whitelist extended with the `M2_WP_*` needles — the
first pilot run silently dropped them, a decoder gap, fixed and re-run):

| cell | boots | wp-depth | outcome |
|------|-------|----------|---------|
| A (25+TLBI) | 3/3 | 0 | ladder ends at `M2_MMUP!` — first post-switch access faults, **every boot** |
| B (16+TLBI) | 3/3 | 6 | full probe battery + phase C complete (`M2_TRC1!→M2_TRC2!→M2_TRCU!`, payload in `vm-serial.log`) |
| C (25, no TLBI) | 3/3 | 5 | dies between `M2_WP_04` and `M2_WP_05` — the crutch covers all four RAM probes, **not the BAR** |
| D (16, no TLBI) | 3/3 | 6 | probes pass; phase C completes 1/3 (2 hang at `M2_TXST!`) — reproduces claim 6460 |

Earlier extended runs are consistent: cell B 9/9 complete (6 further
boots), cell D 5/6 complete + 1 death at `M2_TXST!`.

## 5. Interpretation

1. **The start-level mismatch is real and deterministic.** Cell A: with an
   empty TLB, T0SZ=25 dies at the first re-walk, every boot. Cell C names
   the coverage boundary: the stale-TLB crutch covers every RAM probe
   (P1–P4 all return) but NOT the virtio BAR (P5) — the first post-switch
   access whose firmware TLB entry is gone.
2. **The claim-6460 residual is stale-TLB interference, not a device or
   emulator hang.** Cell B vs D is the controlled pair: same T0SZ=16,
   correct walk in both, but an **empty TLB → 3/3 phase-C complete**,
   while the no-TLBI crutch → 1/3. A firmware-era stale entry that is
   still resident maps the address under the *firmware's* regime (wrong
   attributes / wrong PA), and the hardware uses it without re-walking;
   whether that entry survives is what varies per boot.
3. **The deterministic fix direction:** `T0SZ=16` + `tlbi vmalle1` at the
   switch works 100% on this host (cells A/B prove both halves: 25 is
   broken cold, 16 is clean cold). Production keeps T0SZ=25 (claim 6460),
   so the production-grade options are: build **L1-rooted tables** for
   W=39 (make the hardware's level-1 start correct), or accept the crutch
   debt (ADR 0006) with the residual documented as TLB-artifact — no
   evidence of a VZ device-level hang remains.

## 6. Stopping rules met / not met

- Cell A DID die at the first cold access (3/3) → start-level model
  confirmed; no re-derivation needed.
- Cell B did NOT show ~2/3 phase-C failure with an empty TLB (it showed
  3/3 success) → the "residual is device/emulator-level" branch was
  **falsified**; the residual is the TLB artifact. This is a stronger,
  cleaner outcome than the design predicted.

## 7. Files

| File | Change |
|------|--------|
| `build.zig` | two default-off options: `-Dtlbi-after-switch`, `-Dwalk-probe` |
| `kernel/src/evidence.zig` | `marker_wp00`…`marker_wp05` constants |
| `kernel/src/walkprobe.zig` | **new** — probe battery (`run`) |
| `kernel/src/main.zig` | comptime-gated calls: `tlbi vmalle1` after the switch; `walkprobe.run` |
| `host/vm-runner/Sources/VMRunner/main.swift` | marker whitelist + `M2_WP_*` needles (decoder gap fix) |
| `tools/verify-t0sz16-walkprobe.sh` | **new** — matrix runner |
