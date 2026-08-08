# Claim: M1.5 — TX-transition matrix: which transition destroys virtio-pci console access (controlled A/B/C/D experiments)

- **Owner:** buffy (`freebuff/pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91`)
- **Prompt / plan:** task prompt 2026-08-07 — pull latest main (pre-exit TX
  claim 0017 + fine-grained TX-marker bisect claim 0018, landed), then run
  controlled one-variable-at-a-time experiments to determine **which
  transition actually destroys access to the virtio-pci console**.
- **Scope:** diagnostic instrumentation only, behind a new build option
  `-Dtx-transition-{a,b,c,d}` (each default off — default builds are
  byte-identical). Four separate builds, one experiment site per build:
  A. pre-ExitBootServices; B. immediately after a successful
  ExitBootServices while the firmware translation regime is still active
  (before DipshitOS page tables); C. immediately after installing the
  DipshitOS identity map (before unrelated runtime-service/diagnostic
  work); D. at the normal final location (where the banner TX happens).
  Same payload, same armed transport, same flush path in every phase. No
  RX, no production ordering change, no edit to `docs/status.md`.
- **Depends on:** claim 0017 (pre-exit TX works — transport proven), claim
  0018 (post-exit first flush dies at the first BAR/common-config read,
  `M2_TXBR!` written / `M2_TXAR!` absent), claim 0016 (spec-correct
  flush), claim 0009 (NVRAM marker channel alive post-exit)
- **Status:** ✅ done 2026-08-07 — **the transition that destroys access is the MMU switch (B→C); ExitBootServices is exonerated** (evidence under `artifacts/transition-gate.txt`, `transition-report.txt`, `transition-matrix.txt`, `transition-run-{a,b,c,d}-*.txt`, `transition-serial-*.log`)

## Notes

**Precondition (task rule):** if pre-EBS TX had already failed in the
preceding claim (0017), STOP and close as blocked on transport correctness.
It did NOT fail — claim 0017 observed `DIPSHITOS PREEXIT VIRTIO TX` in
vm-serial.log on three consecutive boots, so the experiment proceeds.

**Question:** which single transition — (A→B) `ExitBootServices`, (B→C)
installing the DipshitOS identity map, or (C→D) the unrelated post-MMU
runtime-service/diagnostic work — first destroys guest access to the
virtio-pci console transport?

**Mechanism (kernel, per-phase comptime-gated):** each phase build runs ONE
`transition_tx_experiment(st, phase)` at its named location. The function
stages the SAME fixed line `DIPSHITOS TRANSITION TX\n` into `virtio_tx`
and calls the SAME `virtio_pci_flush()` the production path uses (same
desc/avail/used rings, same 16-bit notify, same used-ring poll), bracketed
by persistent NVRAM markers (claim-0009 channel):

| Marker | Meaning |
|--------|---------|
| `M2_TRx1!` | experiment entered, about to flush (x = A/B/C/D) |
| `M2_TRx2!` | flush returned (TX did not hang) |
| `M2_TRxU!` | flush returned AND used.idx advanced (device consumed) |
| `M2_TRNX!` | experiment skipped — transport not armed (indeterminate) |
| (flush's own `M2_TXST!/TXNT!/TXPL!`) | hang site inside the flush: TXST! without TXNT! = died between post and notify (the first common-cfg read, since the probe-tail write is gated off in transition builds); TXNT! without TXPL! = died in the used-ring poll; TXPL! = poll finished |

The transition builds also gate the flush's large post-exit probe-tail
`SetVariable` off (the class of write claim 0013 proved hangs post-exit;
claim 0018 removed it in diag builds for the same reason) so the bracketed
window contains only MMIO accesses + marker writes.

**Temporary diagnostic deviation vs ADR 0004:** the ADR's production order
(exit → build tables → install tables → probe → banner) is unchanged in
default builds. The B and C experiments insert a TX attempt at diagnostic
points the ADR does not sanction as production (B: touching the transport
between ExitBootServices and the table install; C: touching it immediately
after the MMU switch). These run ONLY under `-Dtx-transition-*` (default
off); the production path is restored in every default build, which stays
byte-identical.

**One-variable-at-a-time:** each phase is a separate build + fresh VM boot,
so the transport is armed pre-exit and never transmitted before its phase's
experiment — no prior-TX confound, and the ONLY difference between phase
builds is the site at which the one TX attempt runs.

**Per-boot capture (`tools/verify-tx-transition.sh`):** last marker in the
ladder; `vm-serial.log` bytes (and whether the payload line appears);
whether TX returned (`M2_TRx2!`); whether used.idx advanced (`M2_TRxU!`);
whether the VM remained alive (any marker after the experiment's bracket).

**Interpretation rules (no invented root cause — the first failed phase
names the transition):**

- A fails → transport not proven pre-exit (contradicts 0017; re-check).
- A works, B fails → **ExitBootServices itself destroys access** (the
  firmware's translation of the BAR window dies at exit).
- B works, C fails → **installing the DipshitOS identity map destroys
  access** (the MMU switch, the claim-0013/0018 hypothesis).
- C works, D fails → the death is in the post-MMU diagnostic/runtime work
  between C and D (would refute the MMU-switch hypothesis).
- D works → transport survives every transition (claim 0002 gate remains
  blocked only on the final banner flush, not the transition).

**Honesty:** diagnostic evidence only; vm-serial.log reaching the payload
line does not pass claim 0002. The claim's answer is the matrix, nothing
more.

## Result (2026-08-07) — deterministic across 2 boots per phase (8 boots)

`bash tools/verify-tx-transition.sh` (revision `bd1692b5`, `-Dtx-
transition-{a,b,c,d}`, 2 boots per phase, macOS 27.0, zig 0.16.0):

| phase | TX reaches host | TX returned | used.idx advanced | VM alive | last marker |
|-------|-----------------|-------------|-------------------|----------|-------------|
| A pre-EBS | **yes** (24 B payload in vm-serial.log) | **yes** (M2_TRA2!) | **yes** (M2_TRAU!) | yes | M2_TXST! |
| B post-EBS/pre-MMU | **yes** (24 B payload in vm-serial.log) | **yes** (M2_TRB2!) | **yes** (M2_TRBU!) | yes | M2_TXST! |
| C post-MMU | **NO** (0 B) | **NO** (no M2_TRC2!) | NO | NO | M2_TXST! |
| D final | **NO** (0 B) | **NO** (no M2_TRD2!) | NO | NO | M2_TXST! |

Across every boot in this run: A and B transmit the full bracket
(`M2_TRx1! → TXST! → TXNT! → TXPL! → M2_TRx2! → M2_TRxU!`) and the boot
continues to the banner; C and D hang inside the FIRST post-switch flush
with no `M2_TXNT!`, no return marker, no bytes. The hang site within the
flush varies between two stages — this run's C/D boots died right after
`M2_TRx1! → M2_TXST!` (desc/avail posted, at the common-cfg read), while
an earlier run's phase-C boot 2 died at bare `M2_TRC1!` (before descriptor
publication) — the same two stopping stages claim 0018 observed
(`M2_TXBR!` without `M2_TXAR!` 10/12, bare `M2_TXFL!` 2/12). Both stages
are inside the first post-switch flush; the matrix cells are unaffected
(no return, no used advance, no bytes in either stage).

**Answer — the first failure is at C, so the transition that destroys
guest access to the virtio-pci console is the DipshitOS identity-map
install (the MMU switch, B→C):**

- **ExitBootServices is exonerated.** Phase B runs the SAME flush with the
  SAME BAR/rings/payload immediately after a successful exit on the
  firmware translation regime and it fully works (host bytes, returned,
  used.idx advanced) — so the claim-0018 hang is NOT an ExitBootServices
  artifact.
- **The MMU switch is the killer.** Phase C places the very first
  post-switch MMIO access to the transport (the common-cfg device-status
  read in the flush, after the marker write + desc/avail + cache cleans)
  immediately after `install_identity_map()`, before any other work, and
  it does not return — exactly claim 0018's smallest interval
  (`M2_TXBR!` written, `M2_TXAR!` absent, i.e. the first post-switch
  BAR/common-config read). No speculation beyond the matrix: A works, B
  works, C hangs, D hangs.
- **Phase D** (final location) fails identically — the same read hang — so
  nothing can be concluded about the post-MMU diagnostic work (C never
  gets past its first access, and D never reaches the banner either).

**Production path restored:** all four phase options default off; the
`comptime`-gated calls compile out of every default build. `zig build`
(default) and `bash tools/verify-marker.sh` pass with the byte-identical
standard ladder (no M2_TR* markers, banner still hangs at M2_TXST! as
before). The flush's probe-tail SetVariable gating in transition builds is
a documented diagnostic deviation (confound removal, mirroring claim
0018); default builds still call it.

**No invented root cause:** the matrix names the failing transition; the
mechanism (VZ MMIO emulation unreachable from the post-switch page tables,
per claim-0013/0018) remains a hypothesis for a future claim.
