# Claim: ESP create on a full root grows the FAT32 root chain (issue #728)

- **Owner:** buffy (`agent/buffy/fix-728-esp-create-disk-full`)
- **Prompt / plan:** issue #728 (triangulated in `artifacts/gate-triage-2026-08-31/`)
- **Scope:** kernel fix + gate re-green: `write` create must not report `disk
  full` on an image whose root-directory window is 80/80; re-green
  `verify-live-asm` / `verify-live-disas`.
- **Touches:** kernel/src/fat.zig, tools/verify-live-asm.sh, tools/verify-live-disas.sh
- **Depends on:** —
- **Heartbeat:** 2026-08-31
- **Status:** ✅ done

## Notes

**The bug (observed, not inferred).** On the 75-file image the root-directory
window is 80/80 slots by the time the user types anything: the image ships 77
entries and the boot itself creates `BOOTED.TXT` / `MEMMAP.TXT` / `LOADER.TXT`
(3 more). `fat.write_file`'s create path scans the root chain for a free slot
(0x00 end marker or 0xE5 deleted) and returned `.disk_full` when none existed —
even though the volume had 77 MiB free and the FAT32 root is a *growable*
cluster chain. Evidence: guest `sysinfo` reported 77 MiB free while
`write PROG.S` failed with `not persisted - disk full`; a direct disk probe
showed the root at 80/80 with 4 free slots consumed by the boot files.

**The fix.** `grow_dir_chain()` (fat.zig) appends one zeroed cluster to a
directory's chain when the slot scan finds no free slot — FAT32 semantics,
valid for the root exactly like any subdirectory (unlike FAT16/12's fixed
root). `write_file`, `write_fb_bmp`, and `create_dir` all use it; on failure
the chain is left untouched and the new cluster is released (no orphans).

**Second regression found en route (test fixture, not kernel).** After the
disk-full wall fell, `verify-live-asm` still failed: the gate stages its
source as `write PROG.S _start:;mov x8, 3;...` — but M19 P3 chaining (claim
5759, issue #292) made `;` a statement operator, so the unquoted content was
chain-split and only `_start:` (7 bytes) was written. ASM.BIN then produced an
empty ELF (84 bytes, no code) and `exec PROG.ELF` failed with `bad entry
offset`. The gates now single-quote the SRC (the tokenizer's fully-literal
quotes), restoring the claim-time 96-byte ELF and the exit-status-71 marker.

**Verification.** Host: `zig test kernel/src/fat.zig` 22/22 (new regression
test "write_file grows a full root directory chain (issue 728)", mutation-
proven to fail without the fix); `tools/verify-unit-tests.sh` all modules
green. Live on VZ: `verify-live-asm` PASS 1/1 (written/assembled/loaded/
exit71 all 1), `verify-live-disas` PASS 1/1, plus the write-path neighbours
`verify-live-filemanager-mkdir` (create_dir growth), `verify-live-gfs`
(DATA-volume writes), `verify-live-history` (two-boot ESP writes) all PASS.
Evidence under `artifacts/issue-728/`.
