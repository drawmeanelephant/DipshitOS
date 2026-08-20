# Log — `agent/buffy/m16-c1-image-format`

## 2026-08-19 — claim 3805 opened

Claimed M16 card C1 (multi-segment user image + lifted load bound, issue
#190) on branch `agent/buffy/m16-c1-image-format`. Surveyed the current flat
DSK1 exec path (`exec.zig`, 16 KiB `exec_program_max`), `elf2bin.py` (already
flattens PT_LOAD + zero-fills BSS but emits no segment boundaries), the user
linker script (already emits `.data`/`.bss` sections), `mmu.build_user_root`
(text+stack apertures only), and the process descriptor page ownership.
Plan: DSK3 segmented format + a third data aperture + a `GLOBALS.BIN`
proof program.

## 2026-08-19 — claim 3805 done

Implemented and verified live. The DSK3 segmented image format is a second
`exec` loader path (the flat DSK1 path is byte-unchanged):

- `tools/elf2bin.py` gains `--segments` (DSK3: 48-byte header carrying
  `text_size`/`data_file_size`/`data_mem_size`, [text+rodata][data] on disk,
  BSS tail implicit zero-fill; page-aligns the RX/RW boundary).
- `kernel/src/exec.zig`: `parse_dsk3` (pure, host-tested), the load bound
  lifted 16 KiB → 256 KiB, data pages allocated + owned + freed at reap.
- `kernel/src/mmu.zig`: `build_user_root_full` maps a third EL0-RW+UXN data
  aperture beside text and stack.
- `kernel/src/process.zig`: data `va/len/phys/pages` in the address space +
  `ProcessInfo`; `release_resources` frees them.
- `kernel/src/monitor.zig`: the `exec` reply reports `data=<hex> datapages=<n>`
  ONLY for segmented images (flat DSK1 replies stay byte-identical).
- `user/linker-segmented.ld` (new) page-aligns `.data` for DSK3; the flat
  programs keep `user/linker.ld` untouched.
- `GLOBALS.BIN` (28th ESP program) — 28 KiB text + 8 B `.data` + 4 KiB `.bss`,
  five naked-asm checks (read init data, write/read data, read/write bss,
  read the 24 KiB `.rodata` blob), prints `globals: data bss ok`, exits 42.
  Wired through build.zig (`--segments`) + make-image.sh (DSK3 magic) +
  mkfat32.py.

Verification (all green): fmt clean, 474 transcript tests byte-identical, 22
unit + exec/mmu/process suites, build/image/inspect, swift build,
coordination ok, and `tools/verify-live-m16-image.sh` PASS 1/1 on VZ —
`size=0x7000` (28 KiB, past the old 16 KiB bound), `data=0x1010 datapages=2`
(exact page accounting), `globals: data bss ok`, `tasks user-exec exited
status=42`.

One real catch from the build: `export const big_blob` (24 KiB) was
dead-stripped in the freestanding build because nothing in `_start`
referenced it (the `export` alone didn't survive `--gc-sections`). The asm
now reads the blob's first byte, which both keeps the image > 16 KiB and adds
a `.rodata` read check.
