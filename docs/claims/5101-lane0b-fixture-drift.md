# Claim: Lane 0b — live-asm/live-disas fixture drift (#774)

- **Owner:** t3code (`t3code/b2feefd3`)
- **Prompt / plan:** issue #774 (umbrella #620 Lane 0): fix live-asm/live-disas fixture drift so assembler/disassembler gates are green at HEAD, prerequisite for Lane 2 compiler encodings
- **Scope:** root-cause "bad entry offset" mismatch in `tools/verify-live-asm.sh` / `tools/verify-live-disas.sh` and correct fixture or gate so both gates green at HEAD
- **Touches:** docs/claims/5101-lane0b-fixture-drift.md, docs/logs/t3code-b2feefd3.md (re-verification only — no code edited; the gate scripts were not modified by this claim)
- **Depends on:** none
- **Heartbeat:** 2026-09-01
- **Status:** ✅ done

## Notes

**Observed at HEAD `fd0d2d0` (2026-09-01): both gates PASS 1/1 live on VZ — no code change required, the drift was already corrected on main**

- `bash tools/verify-live-asm.sh` — PASS 1/1: `asm: wrote 96 bytes to /esp/PROG.ELF` → `exec: loaded PROG.ELF size=96` → `tasks user-exec exited status=71` + `rx-asm-ok` (artifacts/m22-asm-live.txt serial-bytes 11766, banner 1, listed 1, written 1, assembled 1, loaded 1, exit71 1, reaped 1, echo 1, fatal 0)
- `bash tools/verify-live-disas.sh` — PASS 1/1: `asm: wrote 96 bytes` → `00000054: 680080d2 movz x8, #3` + `svc #0` → `tasks user-exec exited status=71` + `rx-disas-ok` (serial-bytes 5389, dump 1, movz 1, svc 1, exit71 1, echo 1, fatal 0)

**Root cause of the previously-red “bad entry offset” (claims 2259/5069 triage; fixed by commit 57b8cb3 `fix(fat): grow the FAT32 root chain` 2026-08-31, issue #728):**

1. *Disk-full wall* — image shipped 77 entries + 3 boot files (`BOOTED.TXT`/`MEMMAP.TXT`/`LOADER.TXT`) = 80/80 root slots (5 clusters × 16). `fat.write_file` scanned for `0x00`/`0xE5` and returned `.disk_full` even though 77 MiB free; FAT32 roots are growable chains, unlike FAT16/12. Fix: `grow_dir_chain()` appends a zeroed cluster when scan finds no free slot (applied to `write_file`, `write_fb_bmp`, `create_dir`; host regression test 22/22 in `kernel/src/fat.zig`).

2. *Chain-split fixture stale* — gates staged `write PROG.S _start:;mov x8, 3;...` unquoted. M19 P3 chaining (claim 5759, issue #292) made `;` a statement operator, so unquoted `;` was chain-split and only `_start:` (7 bytes) reached the file. ASM.BIN then emitted an empty ELF (84 bytes header-only, no code) and `exec PROG.ELF` loader rejected it: `entry 0x400000 outside filesz 0` → `bad_entry` → `bad entry offset`. Fix: single-quote the SRC in both gates (`SRC="'_start:;mov x8, 3;mov x0, 71;svc 0'"`) — the tokenizer's fully-literal quotes protect `;` (chain_split respects single quotes). Restores claim-time 96-byte ELF (84-byte ELF32 header + 12 bytes = 3 instructions: `movz x8,#3`=0xD2800068, `movz x0,#71`=0xD28008E0, `svc #0`=0xD4000001) and exit-status-71 marker.

**Host verification of the encoding contract (Lane 2 prerequisite):** `zig test kernel/src/elf.zig` 11/11, `zig test user/src/asm.zig` 12/12, `zig test user/src/disas.zig` 7/7 — `build_elf32` emits ELF32 at `0x400000` with `e_entry` inside PT_LOAD filesz; disas inverse matches (`00000054` = 84 decimal = `elf_code_offset`) and `verify-coordination.sh` ok. No fixture drift remains; images after `zig build image` list 74 root entries + 3 boot files = 77/80 (5-cluster chain verified via `python3 image/mkfat32.py --list`), so grow path not exercised but proven.

**Evidence:** `artifacts/m22-asm-live.txt` + `artifacts/m22-disas-live.txt` (tee logs), per-boot serial copies `artifacts/live-asm-serial-*.log` / `artifacts/live-disas-serial-*.log`, reports `artifacts/live-asm-report.txt` / `artifacts/live-disas-report.txt`, fixed disk `artifacts/disk.img` (128 MiB, root chain 5 clusters → 80 slots, FAT valid). The fix commit 57b8cb3 (issue #728) documents byte-exact before/after; this claim re-verifies at HEAD.
