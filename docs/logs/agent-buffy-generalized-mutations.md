# Log — generalized bit-order mutation gate (claim 1027)

**Branch:** `agent/buffy/generalized-mutations`

- **2026-08-15** — *buffy*: generalized the glyph mutation check (claim
  9358) into a manifest-driven class-A gate. Verified empirically that the
  FAT `read_le` endianness flip and the virtio `free_chain` walker
  NEXT-bit flip both break their module tests; the negative control proved
  mutating the `vq_next` CONSTANT is self-consistent (caught only by an
  accidental 0x2/0x2 collision) — the design rule: flip the READING, never
  a shared constant. `tools/verify-mutations.sh` holds the three-entry
  manifest; `verify-glyph-raster.sh` leg 3 now delegates to it. Wired into
  `verify-portable` + CI + gate inventory.
- Verified: all three mutations detected, files restored, tree clean;
  glyph gate still PASSes via delegation; class A green.
