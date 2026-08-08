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
