# Log — M2 fixed-memory-marker fallback (ADR 0004 D4, gate work item 3)

- **2026-08-06** — *buffy (`agent/buffy/m2-marker-fallback`)*: claimed
  `docs/claims/0009-m2-marker-fallback.md` (status.md gate work item 3) →
  plan: volatile kernel stage markers (M2_ENTRY/M2_EXIT!/M2_MMUP!/
  M2_BANNER) + host-side `--dump-marker` scan in the VZ runner + a
  `verify-marker.sh` gate with saved `artifacts/` evidence → status: 🔄 in
  progress. No code written yet.
- **2026-08-07** — *buffy*: gate work item 3 implemented and **passing**.
  Kernel: stage markers + EFI NVRAM `DipshitM2` variable channel (runtime
  `SetVariable` survives exit on VZ — observed via `artifacts/efi-vars.bin`),
  `M2M!` breadcrumb moved off the discriminating word. Runner: `--dump-marker`
  now reads the NVRAM ladder (the memory-scan form is provably impossible on
  VZ — guest RAM is not host-mapped; a full submap-aware walk found no 256
  MiB region and only the runner's own constant arrays). Gate:
  `tools/verify-marker.sh` asserts the ladder; `zig build marker` + `just
  marker`/`just verify-marker` wired. Result: ladder ends `M2_MAPD!` on every
  run — `install_identity_map()` (the MMU switch) is the death site; with
  the switch skipped (diagnostic), the probe runs and finds no usable device
  (`M2_SERIA`). Evidence: `artifacts/m2-marker-gate.txt`,
  `artifacts/marker-dump.txt`, `artifacts/probe*-run.txt`. Docs updated:
  `status.md` (gate row + work item 3 done), `hardware-contract.md`
  (observed: runtime services survive exit, guest RAM not host-mapped, MMU
  switch faults, probe finds no device), claim 0009 → ✅. All gates green:
  zig build/image/fmt, swift build, unit tests 50/50, transcript 65/65,
  bad-handoff (RC.TXT kernel_rc=0x2), verify-coordination.
