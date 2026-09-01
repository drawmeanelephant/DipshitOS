# Log — `agent/buffy/fix-728-esp-create-disk-full`

Claim: [9930](../claims/9930-esp-create-disk-full.md)

## 2026-08-31 — issue #728: ESP create reports "disk full" on an 80/80-slot root

Triangulated in the gate sweep (evidence `artifacts/gate-triage-2026-08-31/`):
`write PROG.S` failed with `not persisted - disk full` while `sysinfo` showed
77 MiB free. Bisected to the create-path slot scan — a direct disk probe
proved the image root is 80/80 after boot (77 shipped entries + BOOTED/MEMMAP/
LOADER), and the FAT driver had no way to grow the root chain.

Fix (claim 9930): `fat.grow_dir_chain()` appends a zeroed cluster to a full
directory chain (FAT32 roots are growable chains, unlike FAT16/12's fixed
root); `write_file`, `write_fb_bmp`, `create_dir` fall back to it when the
slot scan finds no 0x00/0xE5 slot. No orphans on failure. Host regression
test in fat.zig (22/22, mutation-proven). Live: verify-live-asm PASS 1/1 and
verify-live-disas PASS 1/1, plus filemanager-mkdir / gfs / history PASS.

Also found while re-greening the gates: their `write PROG.S _start:;mov ...`
staging was silently chain-split by M19 P3 chaining (claim 5759, issue #292)
— only `_start:` (7 bytes) reached the file, so ASM.BIN produced an empty
ELF and `exec PROG.ELF` failed with `bad entry offset`. Both gates now
single-quote the SRC, restoring the claim-time 96-byte ELF + exit-status-71
marker. Kernel behavior is correct as designed (unquoted `;` chains);
the fixture was stale.
