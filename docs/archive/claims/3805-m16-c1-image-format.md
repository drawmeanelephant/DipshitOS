# Claim: M16 C1 — multi-segment user image (writable data + BSS, lifted load bound)

- **Owner:** buffy (`agent/buffy/m16-c1-image-format`)
- **Prompt / plan:** `docs/march-m16.md` (card C1, issue #190)
- **Scope:** Milestone sixteen card C1 (wishlist 15). Introduce a segmented
  user-image format (text RX / data RW / zeroed BSS RW+NX) consumed by the
  ESP `exec` loader, lift the 16 KiB load bound so programs can grow, and
  give EL0 real writable globals — reversing the M15 JINGLE finding
  (`chunk_buf` faulted because the flat W^X text page had no writable data).
- **Depends on:** — (C1 is the milestone's first card)
- **Status:** ✅ done — `tools/verify-live-m16-image.sh` PASS 1/1 on VZ (claim 3805)

## Notes

The existing `exec` loader treats a flat DSK1 image as ONE read-only text
page (W^X), so `.data`/`.bss` globals land on a read-only page and fault on
write (claim 7636). C1 adds a second loader path: a DSK3-magic image with a
48-byte header carrying `text_size` (RX), `data_file_size` (initialized RW),
and `data_mem_size` (RW incl. zero-fill BSS tail). `elf2bin.py` gains a
`--segments` mode for user programs; KERNEL.BIN keeps DSK1 (the boot
payload's loader is untouched). The mmu user root maps a third aperture
(data, EL0 RW + UXN) beside text and stack; the process descriptor owns the
new data pages and frees them at reap. The load bound lifts 16 KiB → 256 KiB.

Verification: fmt, unit tests, transcript, build/image/inspect, swift build,
coordination, and a new class-B gate `tools/verify-live-m16-image.sh` — a
program (`GLOBALS.BIN`) with an image > 16 KiB and writable global data +
BSS runs from EL0, prints write/read markers, and exits cleanly with the
kernel's own page accounting exact.
