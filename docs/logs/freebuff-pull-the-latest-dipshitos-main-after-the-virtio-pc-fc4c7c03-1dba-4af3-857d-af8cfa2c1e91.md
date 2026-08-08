# Log — `freebuff/pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-07** — **Claim (buffy, this branch):** claim 0017 filed —
  pre-ExitBootServices virtio-pci console TX experiment (diagnostic). Pulled
  latest main (PR #29/#30: claim 0015 NVRAM console, claim 0016 virtio-pci
  TX spec review) merged cleanly. The one-question answer being sought:
  can the current virtio-pci console TX a known string while Boot Services
  and the firmware address space are still active? Status: 🔄 claimed,
  implementation starting.

- **2026-08-07** — **Done (buffy):** claim 0017 — **A. PRE-EXIT TX WORKS,
  OBSERVED.** Added a build-gated (`-Dpreexit-tx`, default off) pre-exit
  TX diagnostic: `preexit_tx_experiment()` stages `DIPSHITOS PREEXIT
  VIRTIO TX` into the SAME `virtio_tx` buffer and calls the SAME
  `virtio_pci_flush()` the post-exit path uses, right before
  `ExitBootServices`, bracketed by new NVRAM markers `M2_PEXT!`/`M2_PEXD!`
  plus the flush's own `M2_TXST!`/`M2_TXNT!`/`M2_TXPL!` (new host needle
  entries in the runner). New gate `tools/verify-preexit-tx.sh` (+ `zig
  build preexit-tx`, `just verify-preexit-tx`) boots the VZ image and
  asserts the exact string in `vm-serial.log`.

  **Result (single VZ boot):** `vm-serial.log` = exactly
  `DIPSHITOS PREEXIT VIRTIO TX`; ladder bracket complete `M2_PEXT! →
  M2_TXST! → M2_TXNT! → M2_TXPL! → M2_PEXD!`, then the takeover continues
  (`M2_PREX! → M2_EXIT! → M2_MAPD! → M2_MMUP! → M2_RAW! → M2_READY`) and
  ends at a second `M2_TXST!` — the post-exit banner flush hanging before
  `M2_TXNT!` exactly as claim 0013 documented. Interpretation A is
  observed: the same device/queue/notify communicate pre-exit; the
  residual failure is across ExitBootServices/MMU/post-exit access, not
  in the transport as such.

  Evidence: `artifacts/preexit-tx-gate.txt`,
  `artifacts/preexit-tx-run.txt`, `artifacts/preexit-marker-dump.txt`,
  `artifacts/vm-serial.log`, `artifacts/efi-vars.bin` (loader evidence
  `/BOOTED.TXT`, `/LOADER.TXT` preserved). No regression: default build,
  50/50 unit tests, coordination gate, and `verify-marker.sh` (ladder
  still reaches `M2_READY`, post-exit hang unchanged) all pass. The
  post-exit banner TX (claim 0002) is untouched; this does NOT pass the
  VZ serial gate.

- **2026-08-07** — **Re-verified (buffy):** claim 0017 result reproduced on
  **three consecutive VZ boots** (gate twice + `zig build preexit-tx`
  smoke run, which also validated the new zig step end-to-end) — each run
  showed the exact string in `vm-serial.log`, the full
  `M2_PEXT! → M2_TXST! → M2_TXNT! → M2_TXPL! → M2_PEXD!` bracket, the
  takeover continuing to `M2_READY`, and the post-exit flush hanging at
  its second `M2_TXST!` (before `M2_TXNT!`). Evidence files refreshed to
  the 2026-08-07T23:45 run. Also applied code-review nits:  the gate now
  labels the no-bracket-no-bytes case "STILL INDETERMINATE" (distinct
  from B), a tee-drain trap guarantees a complete gate log on every exit
  path, and a kernel comment notes the flush's `VP pst=` dump stays
  in-RAM after probe persistence.

- **2026-08-07** — **Claim (buffy, this branch):** claim 0018 filed —
  post-exit virtio TX failure bisect with per-stage NVRAM markers
  (`-Dtx-diag`, default off). The flush gains ten ordered 8-byte markers
  (M2_TXFL!/TXDA!/TXCC!/TXBR!/TXAR!/TXBN!/TXAN!/TXUP!/TXUC!/TXFR!) around
  each potentially fatal operation of the first post-exit transmission;
  the diag flush removes the large post-exit probe-tail SetVariable and
  the logging-only status read (the read remains only as the bracketed
  stage-4/5 access). Goal: report the smallest confirmed failure interval
  and whether the death point is deterministic across N identical boots.
  Status: 🔄 claimed, implementation starting.

- **2026-08-07** — **Done (buffy):** claim 0018 — **smallest confirmed
  failure interval: the first post-exit BAR/common-config read does not
  return.** 12 identical `-Dtx-diag` boots (revision
  `44316990a…`, `tools/verify-tx-diag.sh`, evidence under
  `artifacts/tx-diag-*`): 10/12 stop at `M2_TXBR!` (TXFL!/TXDA!/TXCC!/TXBR!
  written, TXAR! absent — the device-status read at `vp_common+0x14` never
  returns), 2/12 stop at bare `M2_TXFL!` (before descriptor publication;
  not an MMIO TX access). `M2_TXOK!` absent and `vm-serial.log` 0 B in all
  12 — the first post-exit TX never returned in any boot. The notify, the
  used-ring poll, and the (now-removed) probe-tail SetVariable are
  excluded as the hang site; the same read completes pre-exit (claim
  0017). No invented root cause — the ladder names the interval. The diag
  flush also dropped the large post-exit probe-tail SetVariable and the
  logging-only status dump; default builds stay byte-identical
  (`-Dtx-diag` default off).

- **2026-08-07** — **Claim (buffy, this branch):** claim 0019 filed —
  TX-transition matrix: which transition destroys virtio-pci console
  access. Precondition checked: pre-EBS TX did NOT fail in claim 0017, so
  the experiment proceeds. Four separate `-Dtx-transition-{a,b,c,d}`
  builds (default off), one experiment site per build (A pre-EBS, B
  post-EBS/pre-MMU, C post-MMU, D final location), same payload
  `DIPSHITOS TRANSITION TX\n`, same armed transport, same flush, bracketed
  by new M2_TRx1!/x2!/xU! markers (+ M2_TRNX! skip). Transition builds
  gate the flush's probe-tail SetVariable off (confound removal, mirroring
  claim 0018). Status: 🔄 claimed, implementation starting.

- **2026-08-07** — **Done (buffy):** claim 0019 — TX-transition matrix
  complete. **The transition that destroys virtio-pci console access is
  the DipshitOS identity-map install (the MMU switch); ExitBootServices is
  exonerated.** 8 deterministic VZ boots (2 per phase, `bash
  tools/verify-tx-transition.sh`, revision `bd1692b5`; evidence under
  `artifacts/transition-*`): phase A (pre-EBS) and phase B (post-EBS /
  pre-MMU, firmware translation still active) both transmit the full
  bracket `M2_TRx1! → TXST! → TXNT! → TXPL! → M2_TRx2! → M2_TRxU!` with
  the 24-byte payload in vm-serial.log; phase C (first post-MMU access)
  and phase D (final location) both hang right after `M2_TRx1! → TXST!`
  (desc/avail posted) at the common-cfg device-status read — claim 0018's
  interval — with no return, no used advance, no bytes. New
  `-Dtx-transition-{a,b,c,d}` build options (default off; default builds
  byte-identical — verify-marker still passes with the standard ladder),
  13 new M2_TR* needles in the runner, and the new gate
  `tools/verify-tx-transition.sh`. Mechanism (why the post-switch read
  hangs) stays a hypothesis; the matrix names only the transition. ✅

- **2026-08-07** — **Correction/hardening (buffy):** per code review, claim
  0019's kernel gained a comptime guard rejecting combined phase options
  (`-Dtx-transition-a=true -Dtx-transition-b=true` → compile error
  "enable EXACTLY ONE phase") so a second experiment can never contaminate
  a phase's transport state; the claim's determinism wording was softened
  to note the two observed hang stages within the first post-switch flush
  (after M2_TRx1! or after M2_TXST!, matching claim 0018's two stages).
  The full gate re-ran on the final kernel: identical matrix, 8/8 boots.

- **2026-08-07** — **Correction (buffy):** the entries above referencing
  claim 0019 (TX-transition matrix) now refer to **claim 0020** — the
  previous turn's claim file collided with `0019-ragshit-impact.md`
  (merged via PR #31) and was renumbered to
  `docs/claims/0020-tx-transition-matrix.md`; code comments and the gate
  script were updated to match.

- **2026-08-07** — **Claim (buffy, `freebuff/mmu-debt-contract`):** claims
  0021 and 0022 filed. 0021 = firmware MMU-state capture diagnostic
  (`-Dfw-mmu-capture`, default off): pre-exit capture of SCTLR/TCR/MAIR/
  TTBR0/TTBR1/ID_AA64MMFR0 plus a bounded walk of the firmware TTBR0 tables
  for the virtio BAR0 window (0x100010000) and a RAM control address,
  diffed against the kernel's planned values (claim-0020 follow-up; feeds
  0022's "what is OBSERVED"). 0022 = MMU debt boundary contract: new ADR
  0006, ADR 0004 D3 pointer, hardware-contract updates, and a deterministic
  no-VM `tools/verify-mmu-debt.sh` gate wired into justfile/CI. Prior work
  renumbered: claim 0019 → 0020 (collision with ragshit's 0019). Status:
  🔄 both claimed, implementation starting.

- **2026-08-07** — **Done (buffy):** claim 0021 — firmware MMU-state
  capture. `-Dfw-mmu-capture` (default off) records SCTLR/TCR/MAIR/TTBR0/
  TTBR1/ID_AA64MMFR0 pre-exit + walks the firmware TTBR0 tables for the
  virtio BAR0 window and a RAM control address (persisted as `DipshitMmu`).
  `bash tools/verify-fw-mmu-capture.sh` PASS. **Finding: firmware and
  kernel memory attributes are byte-identical** — BAR = 1 GiB identity
  Device-nGnRnE block (XN=1), RAM = Normal WB 0xff SH=3; `TCR_EL1`
  matches claim 0010's quote exactly; TTBR1 = 0. The post-switch hang is
  NOT an attribute mismatch (structural diffs: block vs 4K page
  granularity, XN/PXN, T0SZ, MAIR index). Evidence under
  `artifacts/fw-mmu-capture-*`. ✅

- **2026-08-07** — **Done (buffy):** claim 0022 — MMU debt boundary
  contract. New **ADR 0006** (`docs/decisions/0006-mmu-debt-boundary.md`):
  the no-TLBI takeover as a precise contract — safety argument S1–S4,
  validity window, layers of certainty, and the binding invalidation list
  (descriptor/attribute changes, page reclamation, non-identity, ASID,
  unmapping, above-blanket, TCR/MAIR). **ADR 0004 D3 addendum** records
  the tlbi is NOT executed and points to 0006. **hardware-contract**
  flips the VZ re-walk fault / no-TLBI survival / post-switch BAR hang /
  firmware translation state to [observed]. New deterministic gate
  `tools/verify-mmu-debt.sh` (no VM) wired into `just verify` + CI; PASS
  (`artifacts/mmu-debt-gate.txt`). No kernel code, no `docs/status.md`.
  The "MMU debt boundary" statement for the next status review is in the
  claim and the PR description. ✅
