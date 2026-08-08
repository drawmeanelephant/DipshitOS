# Claim: M2 — firmware MMU-state capture: TTBR0/1, MAIR, TCR + virtio BAR-window descriptor walk (diagnostic)

- **Owner:** buffy (`freebuff/mmu-debt-contract`)
- **Prompt / plan:** follow-up to claim 0020 (TX-transition matrix) — record
  the firmware's MMU state and the exact mapping attributes of the virtio
  BAR window before ExitBootServices, then diff against the DipshitOS
  identity map, to identify what attribute/mapping difference makes the
  post-switch common-cfg read hang on VZ. Also feeds claim 0022's
  "reconstruct exactly what is OBSERVED" step.
- **Scope:** diagnostic instrumentation only, behind a new build option
  `-Dfw-mmu-capture` (default off — default builds byte-identical). Pre-exit
  register reads + a bounded firmware translation-table walk for the virtio
  BAR window and one RAM address, persisted via the proven pre-exit NVRAM
  probe channel. No production behavior change, no edit to `docs/status.md`.
- **Depends on:** claim 0010 (TCR capture precedent: `TCR_EL1=0x18080351c`,
  T0SZ=28, TG0 4K, 36-bit IPS — quoted, raw artifact missing from this
  checkout), claim 0020 (post-switch BAR read hangs; the walk target is the
  BAR the firmware mapped), claim 0013 (BAR0 = `0x100010000` above the 4 GiB
  blanket, common cfg at BAR0+0x0000)
- **Status:** ✅ done 2026-08-07 — firmware MMU state + BAR-window walk captured; **firmware and kernel use byte-identical memory attributes** (evidence under `artifacts/fw-mmu-capture-gate.txt`, `fw-mmu-capture-lines.txt`, `fw-mmu-capture-efi-vars.bin`, `fw-mmu-capture-run.txt`)

## Notes

**Why:** claim 0020 proved the first post-switch MMIO read of the virtio BAR
window does not return on VZ, while the same read pre-switch works. What we
do NOT yet have is the firmware's own mapping of that window: which
translation regime (TTBR0 vs TTBR1), which descriptor type (block/page),
which MAIR attribute index and memory attributes, AF/AP/SH bits. The
DipshitOS identity map maps the window Device nGnRnE (MAIR Attr0, 4 KiB
pages, AF set). If the firmware mapped it differently (e.g. Normal
cacheable, or a Device variant, or a 1 GiB block), that difference is a
candidate mechanism for the post-switch hang — to be tested by a later
claim, not asserted here.

**Mechanism (kernel, `-Dfw-mmu-capture`, default off):** pre-exit, after the
virtio probe armed the transport (vp_bar0 known) and before
ExitBootServices, capture:

- `SCTLR_EL1`, `TCR_EL1`, `MAIR_EL1`, `TTBR0_EL1`, `TTBR1_EL1`,
  `ID_AA64MMFR0_EL1` (the firmware's live values);
- a bounded walk of the firmware's TTBR0 tables (initial level derived from
  `TCR_EL1.T0SZ` for the 4 K granule) recording the descriptor chain and the
  final descriptor for (a) the virtio BAR0 window base `vp_bar0` and (b) one
  RAM address (the handoff stack) as a control;
- our OWN planned values (`MAIR_EL1=0xff00`, `TCR_EL1=25|(ips<<32)`,
  TTBR0 = our table base, the BAR mapped Device 4 K) so the host can diff
  firmware-vs-kernel side by side.

Lines are appended to the existing `probe_dump` buffer (plain ASCII,
`dump_str`/`dump_hex`) and persisted pre-exit via the proven `DipshitP*`
chunked NVRAM channel; the host reads `artifacts/efi-vars.bin` after the
run. Register reads and table walks are plain (volatile) RAM loads — no
post-exit access, no MMIO beyond what the pre-exit probe already does.

**Mechanism (host):** `tools/verify-fw-mmu-capture.sh` builds the
`-Dfw-mmu-capture=true` image, boots it once in a VZ VM (fresh variable
store), extracts the capture lines from `efi-vars.bin`, prints the
firmware-vs-kernel side-by-side, and saves the evidence under
`artifacts/` (`fw-mmu-capture-gate.txt`, `fw-mmu-capture-run.txt`,
`fw-mmu-capture-efi-vars.bin`, `vm-serial.log`).

**Evidence gap recorded:** claim 0010's raw capture artifacts
(`m2-firmware-regs.txt`, `m2-mmu-bisect-tlbi.txt`, `m2-table-walk.txt`) are
NOT present in this checkout (artifacts/ is not tracked); only the quoted
values survive. This claim's capture re-derives the firmware register file
and supersedes the missing artifact.

**Honesty:** diagnostic evidence only. Whatever the walk shows, this claim
only records the firmware's mapping; explaining the post-switch hang from it
is a separate, later claim.

## Result (2026-08-07) — firmware mapping recorded; attributes match the kernel's

`bash tools/verify-fw-mmu-capture.sh` passes (revision `bd1692b5`, `-Dfw-mmu-capture=true`, macOS 27.0, zig 0.16.0; `artifacts/fw-mmu-capture-lines.txt`):

**Firmware translation state (live, pre-switch):**

- `SCTLR_EL1=0x3080118d` (M=1, MMU on), `TCR_EL1=0x18080351c` (T0SZ=28 →
  2^36 VA space, TG0 bits [15:14] = 0b00 = 4 K granule, 36-bit IPS) —
  **matches claim 0010's quoted `0x18080351c` exactly** (its raw artifact is
  missing from this checkout; this capture supersedes it).
- `MAIR_EL1=0xffbb4400` (Attr0=0x00 Device-nGnRnE, Attr3=0xff Normal WB),
  `TTBR1_EL1=0` (no high-half tables), `ID_AA64MMFR0_EL1=0x10000f100021`
  (PARange = 0b0001 = 36-bit).

**Firmware walk of the virtio BAR0 window (`0x100010000`):**

- `L1 @0x7fffe020 E=0x0060000100000401 BLK out=0x0000000100000000 AIDX=0
  A=0x00 AF=1 SH=0 AP=0 XN=1` — a **1 GiB identity block** (VA 0x100010000
  → PA 0x100000000 + 0x10000), **Device-nGnRnE (MAIR Attr0 = 0x00), XN=1,
  PXN=1, AF=1, non-shareable, EL1 RW**.

**Firmware walk of a RAM control address (the handoff stack):**

- `L3 PAG out=0x7e4ce000 AIDX=3 A=0xff AF=1 SH=3` — **Normal Write-Back
  (MAIR byte 0xff), inner-shareable**.

**Kernel plan (for the diff):** `MAIR=0xff00` (Attr0=0x00 Device, Attr1=0xff
Normal), `TCR=0x100000019` (T0SZ=25, 36-bit IPS), BAR mapped as a Device
4 K page (`|0x403`).

**Default builds are byte-identical (observed, not inferred):** the
capture module is comptime-gated and `nm` on the default-built kernel ELF
shows **zero** capture symbols (`mmu_dump`/`fw_mmu_capture_diag`/`fw_walk`/
`mmu_str`) — the whole module, including the 4 KB `mmu_dump` BSS, is
linker-eliminated; the default `KERNEL.BIN` stays 580312 bytes (the
pre-capture baseline).

**Finding — no attribute mismatch:** the firmware's memory-attribute BYTES
for both RAM and the BAR are **identical to the kernel's choices** (Device
0x00, Normal 0xff; same SH values). The structural differences are:
granularity (1 GiB block vs the kernel's 4 K pages for the BAR), XN/PXN
(set on the firmware's BAR block, deferred by ADR 0004 D3), T0SZ (28 vs
25), and MAIR index numbering (Attr3 vs Attr1 for Normal). The claim-0020
post-switch BAR hang is therefore **not** explained by an attribute
mismatch; the mechanism (e.g. VZ TLB behavior at the TTBR0 switch,
block-vs-page granularity for the device window) remains a later claim's
question. Claim 0022's ADR 0006 records this capture as the reference for
"the firmware's mapping of X".
