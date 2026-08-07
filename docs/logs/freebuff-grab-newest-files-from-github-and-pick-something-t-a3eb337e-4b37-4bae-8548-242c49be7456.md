# Log — M2 MMU-takeover root cause & fix (claim 0010)

- **2026-08-07** — *buffy
  (`freebuff/grab-newest-files-from-github-and-pick-something-t-a3eb337e-4b37-4bae-8548-242c49be7456`)*:
  claimed `docs/claims/0010-m2-mmu-takeover-fix.md` (the unclaimed follow-up
  named in claim 0009 / `docs/status.md` gate work item 2) → plan:
  root-cause the `install_identity_map()` death in the MMU-takeover window;
  hypothesis: TCR_EL1 granule mismatch (tables are 4 KB-granule; prior
  `1 << 8` selects TG0 = 0b01 = 64 KB under the ARMv8.0 field layout, and TG0
  sits at [15:14] under the ARMv8.1+ layout Apple silicon implements — the
  fix leaves TG0 0b00 in both positions); gate: `bash tools/verify-marker.sh`
  ladder must advance `M2_MAPD! → M2_MMUP! → M2_SERIA` → status: 🔄 in
  progress. Reference-checked TG0/IPS encodings against Apple xnu
  `proc_reg.h` (TG0 at shift 14, IPS at shift 32) before editing. No code
  written yet.
- **2026-08-07** — *buffy*: MMU-takeover **root-caused and fixed** (claim
  0010 → ✅). Evidence chain (all ladder-gated): (1) pre-switch firmware
  register capture (NVRAM `DipTCR`) showed the guest uses the ARMv8.1+ TCR
  layout (TG0 at [15:14], 4KB, 36-bit IPS) — the granule was never the
  cause; (2) host-side table replay against the real EFI map proved the map
  must cover *undeclared* firmware MMIO as Device — the identity map now
  maps declared RAM Normal WB and everything else Device (2 MiB blocks, 4 KiB
  at edges); (3) bisect stages between the switch steps proved the switch
  works and the first post-switch runtime call succeeds, but any
  TLBI-forced re-walk faults on VZ — the `tlbi vmalle1` is dropped at the
  switch (stale firmware TLB entries are identity-compatible), and the table
  carve-out is D-cache-cleaned pre-switch. Result: ladder
  `M2_ENTRY → … → M2_MAPD! → M2_MMUP! → M2_SERIA` — the MMU takeover
  completes on VZ and the probe finds no usable device, confirming claim
  0009's prediction that the serial gate is blocked on device absence, not a
  crash. Evidence: `artifacts/m2-mmu-takeover-gate.txt`,
  `artifacts/m2-mmu-bisect-tlbi.txt`, `artifacts/m2-firmware-regs.txt`,
  `artifacts/m2-table-walk.txt`. Docs updated: status.md (gate table + gate
  work item 2 note), hardware-contract.md (MMU-takeover finding superseded),
  march-m15.md step 8, README.md, testing.md. All gates green.
