# Claim: mechanical split of kernel/src/main.zig into hardware modules

- **Owner:** buffy (`freebuff/mainzig-modules`)
- **Prompt / plan:** `docs/` — freebuff "reduce kernel/src/main.zig into mechanically separated modules" (no prompt file; plan in this claim + `docs/logs/freebuff-mainzig-modules.md`)
- **Scope:** kernel/src/main.zig refactor only — mechanical extraction, no behavior change; `docs/status.md` untouched
- **Depends on:** main with claims 0020/0021/0022 landed (PR #33, merged)
- **Status:** ✅ done 2026-08-07 — main.zig split into mmio/mmu/pci/evidence/virtio_console (2508 → 758 lines); KERNEL.BIN byte-identical (580312 B, sha 55325752…) across every extraction; verify-marker + verify-nvram-console ladders unchanged (final M2_TXST!); all portable gates + all 9 diagnostic builds pass (evidence under artifacts/mainzig-*)

## Notes

### Goal

Reduce `kernel/src/main.zig` (~2500 lines) from a hardware/debugging junk
drawer into mechanically separated modules **without intentionally changing
behavior**. Main keeps orchestration: handoff → capture map → discovery →
ExitBootServices → MMU → console → monitor.

### Module boundaries (moved verbatim, only import/name plumbing changes)

- `kernel/src/mmio.zig` (new, tiny): the shared volatile MMIO accessors
  (`mmio_read8/16/32/64`, `mmio_write8/16/32/64`). Cross-cutting (used by
  pci, virtio, probe, evidence dumps); a separate file keeps the four
  named modules one-way-importable with no import cycle.
- `kernel/src/mmu.zig` (new): page-table construction/attributes/table
  allocation, `clean_dcache_range`/`invalidate_dcache_range`,
  `install_identity_map`, `build_identity_map`. The virtio BAR window that
  `build_identity_map` maps above the blanket is passed in as an optional
  parameter (the caller reads `virtio_console.vp_ready`/`vp_bar0`), so
  mmu.zig does not depend on the virtio module.
- `kernel/src/evidence.zig` (new): takeover markers (all `M2_*` constants,
  values/names preserved), `set_marker`/`write_marker_var`/
  `write_marker_fallback`, the `DipshitProbe` dump machinery
  (`dump_str`/`dump_hex`/`dump_*_line`/`write_probe_var`/`write_probe_tail`/
  `dump_config_table`/`dump_mmio_descriptors`/...), and the claim-0021
  firmware-MMU-capture diagnostic (`DipshitMmu`, `fw_walk`, ...). The
  capture reads `read_mmfr0` + the table root from mmu.zig and receives
  `vp_ready`/`vp_bar0` as parameters.
- `kernel/src/pci.zig` (new): `pci_ecam`, ECAM config-space access
  (`pci_read32`/`pci_read8`/`pci_read32_unaligned`, dead `pci_write32`
  moved verbatim), bus/device discovery + BAR dump (`dump_pci`), and
  `dump_acpi` (the ACPI walk that discovers the MCFG/ECAM base and dumps
  SPCR/DBG2/FACP — kept whole so the walk's behavior cannot drift; it is
  the ECAM discovery path feeding `pci_ecam`).
- `kernel/src/virtio_console.zig` (new): virtq structs + ring globals,
  `vp_*` globals, `st_tx`, `virtio_pci_init`, `virtio_pci_flush`,
  `virtio_init` (dead, moved verbatim), the claim-0017/0020 TX experiment
  functions + the `tx_transition_*` option consts + exactly-one-phase
  comptime check.

### Main.zig keeps

Entry/shim (`_start`), `kernel_main` orchestration, `capture_map`,
`valid_handoff` (now built on the shared `handoff.zig` `HandoffV2` +
`handoff.validate` — the duplicate private struct is deleted, as
`handoff.zig`'s own doc comment anticipated), console discovery + polled
TX driver (`probe_serial_pre`/`probe_serial`/`uart_*`/`layout_name`/
`pl011_init`), the M1.5 `M15Console` seam + `nvram_script`.

### Marker preservation

All `M2_*` marker names, values, and write ordering in `kernel_main` are
preserved byte-for-byte. The NVRAM variable names (`DipshitM2`,
`DipshitProbe`, `DipshitP*`, `DipshitMmu`) and the vendor GUID are
unchanged.

### Verification (after each extraction)

`zig fmt`; `bash tools/verify-unit-tests.sh`; `zig build`;
`zig build image`; `zig build inspect`; `bash tools/verify-coordination.sh`;
`bash tools/verify-mmu-debt.sh` (updated to grep `kernel/src/mmu.zig` for
the no-TLBI comments, which moved with `install_identity_map`); a VZ
hardware gate on this host (`bash tools/verify-marker.sh` — the marker
ladder is the behavior fingerprint of the takeover path). At the end, all
diagnostic build variants (`-Dnvram-console`, `-Dpreexit-tx`, `-Dtx-diag`,
`-Dtx-transition-{a,b,c,d}`, `-Dfw-mmu-capture`, `-Dbad-handoff`) must
still compile.

### No behavioral claims from compiling

Compiling is not evidence of unchanged hardware behavior; the VZ marker
gate + serial log are the evidence. If a clean boundary requires a
behavior change, stop and report instead of smuggling the change in.

### Evidence

Baseline (before): `artifacts/mainzig-baseline-gates.txt`,
`artifacts/mainzig-baseline-kernel.txt` (size/sha/symbols). After:
per-step gate logs `artifacts/mainzig-gate{1,2,3,4}.txt` +
`mainzig-gate*-marker.txt` + `mainzig-gate4-nvram.txt` +
`mainzig-final-marker.txt`. `docs/status.md` untouched.
