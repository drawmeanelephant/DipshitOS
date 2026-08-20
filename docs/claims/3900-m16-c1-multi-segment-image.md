# Claim: Milestone 16 Card C1 — multi-segment user image (writable globals + lifted 16 KiB bound)

- **Owner:** Muse Spark (`docs/site-current-state-m15`)
- **Prompt / plan:** `docs/march-m16.md`
- **Scope:** Milestone 16, Card C1 (Issue #190: wishlist 15 — multi-segment user image, text W^X + writable data + zeroed BSS, second loader path, larger images)
- **Depends on:** Milestone 15 (audio, claim 7636 pressure)
- **Status:** ✅ done 2026-08-20 — DSK2 live: BIGTEST.BIN 28768 B (>16 KiB) 2 seg RX+RW, exec at EL0, markers green, exit 42, VZ gate PASS (`verify-live-m16-image.sh` 1/1)

## Notes

Wishlist 15 activated by M15-era pressure: JINGLE.BIN 33 KB draft would not load (16 KiB exec bound, claim 7636) and global chunk_buf faulted on write (W^X single-segment, no writable data). Card C1 gives ELF programs a real writable data segment and BSS, page-aligned, with lifted bound.

Promise: DSK2 second loader path alongside DSK1 (boot payload stays DSK1). DSK2: magic 0x324B5344 "DSK2", header 48 B (magic/flags/entry/segment_count/image_size + segment table), each segment descriptor 24 B (vaddr_offset/filesz/memsz/flags). Segments extracted from ELF PT_LOADs via new tools/elf2bin-dsk2.py; new user/linker-m16.ld page-aligns text at 0x00400000 (RX) and data/bss at 0x00410000 etc. Kernel exec detects magic, validates, allocates per-segment pages from phys allocator, maps via extended mmu.build_user_root_multi (text RX, data RW, bss RW zero), extends uaccess regions + scheduler task regions + process descriptor to cover data/bss, lifts exec_program_max to 64 KiB (staging) and per-process page accounting.

Live gate: verify-live-m16-image.sh — exec BIGTEST.BIN (>16 KiB, global+writable BSS) at EL0, markers green, page accounting exact, VZ sweep green.

Constraints: zero heap, default VM byte-identical, full verify-vz sweep at card landing.
