# Claim: M1.5 — T0SZ start-level residual separation: is the post-MMU virtio TX hang a translation defect, a TLB artifact, or a VZ device/emulator hang? (class-D experiment design + pilot)

- **Owner:** buffy (`freebuff/okay-we-ve-been-kind-of-freestyling-off-away-from--0584ad0f-9850-473f-8884-7c28b20acab7`)
- **Prompt / plan:** user request 2026-08-08 — investigate claim 6460 further (why did T0SZ=16 restore post-MMU virtio TX in only 6/18 boots?) and design a deterministic experiment to separate the start-level mismatch from the residual hang. Characterize first, then implement the smallest diagnostic instrumentation that makes the separation deterministic, and pilot it on real VZ hardware.
- **Scope:** class-D diagnostics only — two new default-off build options (`-Dtlbi-after-switch`, `-Dwalk-probe`) + a matrix runner; default builds stay byte-identical. No production T0SZ flip, no console fix, no RX, no allocator/GIC/timer/scheduler/fs/network/graphics.
- **Depends on:** claim 6460 (T0SZ 25→16, 6/18, not reproducible), claim 0010 (no-TLBI survival; TLBI-at-switch dies at `M2_TTBR!`), claim 0018 (`M2_TXBR!` written / `M2_TXAR!` absent — first post-switch BAR/common-config read), claim 0020 (MMU switch B→C destroys access), claim 0021 (firmware T0SZ=28, attributes byte-identical), ADR 0006 (no-TLBI debt boundary)
- **Status:** ✅ done

## Notes

**Characterization (why 6/18, from the landed evidence + source):**

1. The kernel's tables are **L0-rooted** (`table_storage[0]` = L0; `indices()` uses the 48-bit layout: root→L1→L2→L3).
2. Production programs **T0SZ=25 → W=39 → the 4 KiB stage-1 walk starts at level 1** (ARM ARM D8.2.8 / Table D4-11; corroborated by Linux arm64: 39-bit = 3 levels, top table = hardware L1). The hardware therefore treats TTBR0's table as an **L1** table indexed by VA bits [38:30].
3. The built ROOT only populates entry 0 (VA bits [47:39] = 0 for all VAs < 2^39). So **any fresh walk of a VA ≥ 1 GiB reads ROOT[1..3] = 0 → invalid → synchronous translation fault** (the BAR at `0x100010000` reads ROOT[4] = 0). VAs < 1 GiB mostly misparse (L2-block descriptors read as L3 page descriptors → invalid).
4. The kernel has **no exception vectors** → a translation fault manifests as an **indistinguishable hang** (VBAR_EL1 = 0; the abort handler fetch itself faults/hangs).
5. The **no-TLBI crutch (ADR 0006)** keeps stale firmware TLB entries live; they cover the hot addresses (kernel code/stack/map buffer/NVRAM controller — all touched microseconds pre-exit). That is why the post-switch marker ladder, memmap, and the RAM parts of the virtio flush work under T0SZ=25 — the tables are never walked.
6. The **virtio BAR read is the first post-switch access whose TLB entry was evicted** (last touched early pre-exit) → walk → fault → hang. Deterministic: 0/6 (claim 6460 baseline), 0/12 past the read (claim 0018). Claim 0010's `tlbi vmalle1` death at `M2_TTBR!` is exactly this: forcing a re-walk exposed the broken tables.
7. **T0SZ=16 (W=48 → start L0) matches the built hierarchy** → the walk resolves → 6/18 complete TX end-to-end. The residual 12/18 hang at the SAME first common-cfg read can therefore no longer be a fault of the BAR's own translation — it is either (a) a boot-varying VZ device-emulation/race behavior on the first post-switch MMIO read, or (b) a second, unidentified fault — indistinguishable without an ESR discriminator, because the hang signature is identical either way.

**Conclusion of the characterization:** the 6/18 rate is two stacked causes — the start-level mismatch (deterministic under T0SZ=25, removed by T0SZ=16) times a residual boot-varying failure at the first post-switch MMIO read that persists even with a correct walk (~2/3 of boots). P(success | T0SZ=16) ≈ 1/3.

**Experiment design (deterministic separation):** see `docs/m15-postmmu-t0sz-experiment-design.md`. Core idea: the no-TLBI crutch makes TLB state the uncontrolled variable, so the deterministic lever is to **force an empty TLB with `tlbi vmalle1` immediately after the switch** and then run a **cold-address probe battery**, each probe bracketed by an NVRAM marker:

- Cell A `-Dtlbi-after-switch` (T0SZ=25): first post-switch access needs a fresh walk → faults → ladder ends at `M2_MMUP!`, no probe markers — every boot (reproduces claim 0010 deterministically with the site named).
- Cell B `-Dtlbi-after-switch -Dt0sz16` (T0SZ=16): full probe ladder, then phase-C TX outcome. With an empty TLB, any remaining phase-C failure is **provably device/emulator-level**, not translation.
- Cells C/D (walk-probe without tlbi, both T0SZ): a TLB-coverage survey + residual reproduction.

**Pilot on real VZ hardware:** cells A and B, a few boots each, fresh EFI variable store per boot. Expected: A dies deterministically right after the switch; B passes the probes and reproduces the ~1/3 phase-C success.

## Pilot results (real VZ hardware, 2026-08-08)

3 boots per cell, fresh store per boot (full matrix: `BOOTS=3 bash
`tools/verify-t0sz16-walkprobe.sh`; extended runs: cell B 9/9, cell D
5/6). Evidence: `artifacts/walkprobe-gate.txt`, `artifacts/walkprobe-
report-{A,B,C,D}.txt`, `artifacts/walkprobe-compare.txt`, per-boot
`{run,marker,serial}` files.

| cell | flags | boots | wp-depth | outcome |
|------|-------|-------|----------|---------|
| A | 25 + TLBI | 3/3 | 0 | ladder ends at `M2_MMUP!` — first post-switch access faults, EVERY boot |
| B | 16 + TLBI + probe | 3/3 (9/9 ext.) | 6 | full probe battery + phase C complete every boot (`M2_TRC1!→M2_TRC2!→M2_TRCU!`, payload in `vm-serial.log`) |
| C | 25, no TLBI, probe | 3/3 | 5 | dies between `M2_WP_04` and `M2_WP_05` — crutch covers all four RAM probes, NOT the BAR |
| D | 16, no TLBI, probe | 3/3 | 6 | probes pass; phase C 1/3 (2 hang at `M2_TXST!`) — reproduces claim 6460 |

**Interpretation (revised, evidence-backed):**

1. **Start-level mismatch is real and deterministic** — cell A proves
   T0SZ=25 cannot work cold; cell C names the exact coverage boundary (the
   crutch serves every RAM probe, not the BAR window).
2. **The claim-6460 residual is stale-TLB interference, NOT a
   device/emulator hang** — the controlled pair B vs D is the same T0SZ=16
   with a provably correct walk (wp-depth=6 in both), and an **empty TLB
   makes phase C complete 9/9**, while the no-TLBI crutch keeps the ~1/3
   rate. Boot-variation comes from which firmware-era TLB entries survive
   the switch.
3. **Deterministic fix direction:** T0SZ=16 + `tlbi vmalle1` at the switch
   works 100% on this host; production (T0SZ=25) needs L1-rooted tables
   for W=39, or the ADR-0006 crutch debt stands with the residual now
   classified as a TLB artifact.

**Decoder-gap lesson:** the first pilot run decoded wp-depth=0 for every
boot — the probes were in the store all along (`00_PW_2M`…`50_PW_2M`
reversed-byte needles), but the host-side marker whitelist didn't know the
`M2_WP_*` needles, so they were silently dropped from the ladder. Fixed in
`host/vm-runner/Sources/VMRunner/main.swift` (needles added), runner
rebuilt, matrix re-run. Distinguish a decoder bug from a kernel bug before
redesigning instrumentation.

**Stopping rules (as met):** cell A died at the first cold access 3/3 → start-level model confirmed. Cell B showed a full probe ladder AND phase C completing every boot → the "residual is device/emulator-level" branch was **falsified** (the residual is the TLB artifact). No Stage-2 device matrix needed; the ESR-abort probe idea is moot for the residual and only matters if a future change reintroduces a real walk fault.

**Verification discipline:** class-D evidence only; a payload hit does NOT pass claim 0002. Default builds must stay byte-identical (KERNEL.BIN sha256 `55325752…`).
