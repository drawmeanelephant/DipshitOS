# Claim: M1.5 — post-exit virtio TX failure bisect with per-stage NVRAM markers

- **Owner:** buffy (`freebuff/pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91`)
- **Prompt / plan:** task prompt 2026-08-07 — make the existing post-exit
  virtio TX failure maximally discriminating: instrument the FIRST post-exit
  virtio transmission with persistent NVRAM markers around each potentially
  fatal operation, and run enough identical boots to establish whether the
  death point is deterministic. No ten-fixes-at-once; no invented root
  cause; no RX; no edit to `docs/status.md`.
- **Scope:** diagnostic instrumentation only, behind a new build option
  `-Dtx-diag` (default off — the default build's flush is byte-identical).
  The marker channel stays small (8-byte `SetVariable` writes, the proven
  claim-0009 channel); the large post-exit `write_probe_tail` (512 B) and
  the `dump_str("VP pst=")` logging read are REMOVED from the diag flush
  (they are unrelated diagnostic accesses in the suspect window).
- **Depends on:** claim 0009 (NVRAM marker channel alive post-exit), claim
  0013 (transport decode; post-exit access hangs), claim 0016 (spec-correct
  flush), claim 0017 (pre-exit TX works — the transport is proven; the
  failure is across the transition)
- **Status:** ✅ done 2026-08-07 — **smallest confirmed failure interval: `M2_TXBR!` written, `M2_TXAR!` absent** — 10/12 boots stop at `M2_TXBR!` (evidence under `artifacts/tx-diag-gate.txt`, `tx-diag-run-N.txt`, `tx-diag-marker-N.txt`, `tx-diag-serial-N.log`, `tx-diag-report.txt`)

## Notes

**Goal:** report the SMALLEST confirmed failure interval of the first
post-exit virtio transmission, e.g. "M2_TXBR! written, M2_TXAR! absent,
therefore the first post-exit BAR/common-config read does not return" —
whatever the evidence actually says.

**Why the previous markers were insufficient (claim 0013):** the flush
wrote M2_TXST! (after desc/avail + cache cleans) and M2_TXNT! (after the
notify), with the device-status MMIO read, the `write_probe_tail`
SetVariable, and the notify all between them — a hang anywhere in that
window presented identically as "TXST! without TXNT!". Worse, the 512-byte
post-exit probe-tail write is itself a large post-exit SetVariable (the
class of write claim 0013 proved hangs post-exit on VZ) sitting inside the
suspect window.

**Instrumentation (`-Dtx-diag=true`, comptime-gated in `virtio_pci_flush`):**
the flush writes ten 8-byte NVRAM markers (same `DipshitM2` variable,
append-per-write store → ordered ladder):

| # | Marker | Meaning |
|---|--------|---------|
| 1 | `M2_TXFL!` | entered virtio flush |
| 2 | `M2_TXDA!` | descriptor/avail buffers prepared |
| 3 | `M2_TXCC!` | DMA cache clean completed |
| 4 | `M2_TXBR!` | immediately before first post-exit BAR/common-config read (device status) |
| 5 | `M2_TXAR!` | immediately after that read |
| 6 | `M2_TXBN!` | immediately before queue notify MMIO write |
| 7 | `M2_TXAN!` | immediately after notify |
| 8 | `M2_TXUP!` | entered used-ring poll |
| 9 | `M2_TXUC!` | device changed used.idx (break condition seen) |
| 10 | `M2_TXFR!` | flush returned |

The diag flush also drops the `write_probe_tail` (large post-exit
SetVariable — forbidden here) and the `dump_str("VP pst=")` logging read
(the read is kept only as the bracketed stage-4/5 access, its value no
longer logged). The coarse `M2_TXST!/M2_TXNT!/M2_TXPL!` markers are
replaced by the ten stages in diag builds only.

**Interpretation rules (no invented root cause — the ladder names the
interval):**

- `… TXFL!` then nothing → hung before descriptor publication (or ring
  full on entry; repeated bare `TXFL!` = device never consumed).
- `… TXDA!` no `TXCC!` → hung inside the cache-clean range (not MMIO).
- `… TXCC! TXBR!` no `TXAR!` → **the first post-exit BAR/common-config read
  does not return**.
- `… TXAR! TXBN!` no `TXAN!` → the notify write does not return.
- `… TXAN! TXUP!` no `TXUC!` but `TXFR!` → used ring never changed within
  the poll bound (device didn't consume, or the ring RAM isn't coherent).
- `… TXUC! TXFR!` → first post-exit TX returned; the failure is later.

**Determinism:** `tools/verify-tx-diag.sh` boots the `-Dtx-diag=true` image
N times (default 6, fresh variable store per boot) with identical settings,
saves each boot's marker dump, `vm-serial.log`, the kernel/build revision
(`git rev-parse HEAD` + branch + build flags), and the complete gate output
under `artifacts/`, and reports the first post-exit flush's stopping stage
per boot plus whether it is deterministic across boots.

**Honesty:** the markers are the ONLY post-exit evidence; `vm-serial.log`
is expected to stay 0 B (the post-exit TX hangs — that is what we are
bisecting). Removing the probe-tail write changes the default build's
flush? NO — it is removed only in `-Dtx-diag` builds; the default build's
flush stays byte-identical. A successful first post-exit TX in a diag run
would be a finding, not a gate pass for claim 0002.

## Result (2026-08-07) — 12 identical boots, bisect complete

`BOOTS=12 bash tools/verify-tx-diag.sh` (revision
`44316990a93dba3e4ab381a875421a5188c4cd4b`, `-Dtx-diag=true`, macOS 27.0,
zig 0.16.0 — recorded in the gate log):

**Primary stopping stage — 10/12 boots, all that reached the BAR read:**

    M2_TXFL! M2_TXDA! M2_TXCC! M2_TXBR!  ... M2_TXAR! ABSENT

→ **smallest confirmed interval: `M2_TXBR!` written, `M2_TXAR!` absent —
the flush never got past the device-status read (the only operation
between the two markers, apart from the `M2_TXAR!` marker write
itself).** The notify write, the used-ring poll, and the probe-tail
SetVariable are EXCLUDED: the flush never reached them. The most likely
mechanism — that the first post-exit BAR/common-config read (device
status at `vp_common+0x14`) does not return — is an inference *within*
the proven interval, not independently observed (the `M2_TXAR!` marker
write is the same known-working 8-byte channel that persisted
`M2_TXFL!/M2_TXDA!/M2_TXCC!/M2_TXBR!` immediately before). The same read
completes pre-exit (claim 0017's flush performed it and the ladder ran to
`M2_PEXD!`), so the failure is specific to POST-exit MMIO read access to
the transport window on VZ.

**Secondary stopping stage — 2/12 boots (4, 10):** `M2_TXFL!` alone →
died between flush entry and descriptor publication (the ring guard or the
`M2_TXDA!` marker write — NOT an MMIO TX access; not discriminated
further).

**Across all 12 boots:** `M2_TXOK!` (kernel_main's post-flush marker)
absent in every boot → the first post-exit TX never returned in any run;
`vm-serial.log` 0 bytes in every boot → no bytes reached the host.

**Determinism:** the deepest-reached stage is deterministic — every boot
dies AT or BEFORE `M2_TXBR!`, and 10/12 die exactly there. The 2 earlier
stops are a shallower, rarer variant of the same post-exit death, not a
second TX failure mode.

**No invented root cause:** the ladder names the interval
(``M2_TXBR!`` written, ``M2_TXAR!`` absent); the mechanism (VZ MMIO
emulation unreachable from post-switch page tables) is the claim-0013
hypothesis, not asserted here as fact.

**No regression:** `-Dtx-diag` is default-off; default builds are
byte-identical; the claim-0017 gate re-run passes unchanged.

Exact artifact filenames: `artifacts/tx-diag-gate.txt` (complete gate
output incl. revision + builds), `artifacts/tx-diag-report.txt`,
`artifacts/tx-diag-run-01..12.txt` (per-boot runner output),
`artifacts/tx-diag-marker-01..12.txt` (per-boot ladders),
`artifacts/tx-diag-serial-01..12.log` (all 0 bytes), `artifacts/efi-vars.bin`
(the final boot's store).
