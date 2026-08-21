# Claim: ADR 0004 D4 fixed-memory-marker fallback (host-side `takeover_marker` dump)

- **Owner:** buffy (`agent/buffy/m2-marker-fallback`)
- **Prompt / plan:** ADR 0004 D4 (`docs/decisions/0004-kernel-proper.md`),
  `docs/status.md` gate work item 3
- **Scope:** M2 gate work item 3 — discriminate the VZ serial-gate blocker:
  `layout=none` (`M2_SERIA` halt) vs. early post-exit crash (map/MMU/probe)
- **Depends on:** bad-handoff fix (landed 2026-08-06); claim 0002 blocked
  run of 2026-08-06 21:19 names this as the next step
- **Status:** ✅ done 2026-08-07 (gate work item 3 passes; evidence in
  `artifacts/m2-marker-gate.txt` and this claim's outcomes below)

## Notes

**Gate (from `docs/status.md` item 3):** saved host-side dump matching the
`M2_*` markers. The kernel already halts with `M2_TABLE` (identity-map build
failure) and `M2_SERIA` (probe found no usable serial device) BSS markers;
the missing piece is a **host-side memory-dump path** — the design doc
(`docs/m2-kernel-proper-design.md` §4) says the runner has none today.

**Mechanism:** Virtualization.framework runs the guest in-process, so the
guest's 256 MiB RAM is mapped into the VMRunner process's address space.
The runner adds `--dump-marker <file>`: before exiting it walks its own
address space (`mach_vm_region_64`), scans readable regions for the
distinctive `M2_*` 8-byte constants (little-endian), and saves every hit
with host address, containing region, and guest-physical offset. Exit code
in marker mode is 0 iff a marker was found (the marker channel, not the
silent serial channel, is the gate).

**Kernel additions (additive):** stage markers so a *no-marker* result is
not a black box — `M2_ENTRY` (valid handoff), `M2_EXIT!` (ExitBootServices
returned), `M2_MMUP!` (identity map installed), `M2_READY` (serial
selected, banner about to print). Writes are volatile (a bare dead store
could be elided in ReleaseSmall). `write_marker_fallback` no longer
overwrites the discriminating word: the final BSS marker on the no-device
halt is `M2_SERIA` (the `M2M!` breadcrumb moves to the virtio_tx scratch
region only).

**Outcomes:** `M2_SERIA` ⇒ decisive: no usable MMIO serial device in the
declared windows. `M2_TABLE` ⇒ map-build failure. Stage marker present but
no later stage ⇒ crash site narrowed to that window. No marker at all ⇒
crash before the first marker write. Evidence saved under `artifacts/`;
hardware-contract tags flip only with a quoted dump line.

## Outcomes (2026-08-07)

**The memory-dump form is impossible on VZ (observed).** A full
submap-aware walk of the VMRunner process's own address space (the runner
was assumed to host-mapped the in-process VZ guest RAM) finds no 256 MiB
region; every `M2_*` hit is the runner's own rodata/heap constant array
(`artifacts/marker-dump.txt` region landscape + context hex).
Virtualization.framework does not map guest RAM into the host process.

The **NVRAM ladder is the working form (observed).** The kernel writes each
takeover stage as the EFI non-volatile variable `DipshitM2` (VendorGuid
`M2M2_DIPSHITOS-M`) via runtime `SetVariable`; on VZ these calls survive
`ExitBootServices`, and the host reads `artifacts/efi-vars.bin` after the
run. Stage writes: `M2_ENTRY` (valid handoff), `M2_CMAP!` (about to capture
map), `M2_PREX!` (pre-exit), `M2_EXIT!` (first post-exit write), `M2_MAPD!`
(map built, pre-install), `M2_MMUP!` (post-install), `M2_SERIA` (probe found
no device), `M2_READY` (console selected, banner next).

**Gate result (pass):** `bash tools/verify-marker.sh` → `artifacts/m2-marker-gate.txt`,
2026-08-07. Every VZ run's ladder ends at `M2_MAPD!` — the identity map is
built but the post-install `M2_MMUP!` stage never appears. The kernel dies
in the **MMU-takeover window** — between the pre-install write and the
first post-switch call (i.e. inside `install_identity_map()` or at that
call itself; the marker channel cannot narrow it further because it *is*
the post-switch call) — before the serial probe runs.

**Controlled experiment (documented here for the next claim):** a
diagnostic build with `install_identity_map()` skipped proves the rest of
the takeover path works on the firmware map — the ladder advances
`M2_MAPD! → M2_MMUP! → M2_SERIA`. The probe then runs and finds **no usable
MMIO serial device** in the declared windows (`0x01000000..0x01010000`,
`0x20050000..0x20051000`). Two independent observed findings:

1. The MMU switch is the death site on the real path (serial never probed).
2. Even past the switch, the probe selects no device (`M2_SERIA` → zero
   serial output, consistent with the empty log).

**Hardware-contract updates with quoted evidence:**
`docs/hardware-contract.md` — EFI runtime services survive exit on VZ
(observed), guest RAM is not host-mapped (observed), the MMU switch faults
on VZ (observed), and the probe finds no usable device in the declared
windows (observed). `docs/status.md` gate table row + gate work item 3
marked done.

**Follow-up (unclaimed):** root-cause the `install_identity_map()` fault on
VZ (TCR/MAIR/TTBR0 sequence, or the first post-switch access). The
NVRAM-ladder gate now makes the fix verifiable. `docs/march-m15.md` step
referencing the serial gate should cite this claim.
