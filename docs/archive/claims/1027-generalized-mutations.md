# Claim: generalize the bit-order mutation check beyond glyphs (issue 125 hardening)

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** "Extend the mutation-check technique to other bit-order-sensitive kernel tables (e.g., the FAT structure parsing or virtio descriptor walks) so the gate pattern generalizes beyond glyphs"
- **Scope:** the glyph-raster gate (claim 9358) proved `font8x8.row_pixel` reversal fails its goldens — a single hand-rolled mutation. Generalize the technique into a manifest-driven class-A gate covering the kernel's bit-order-sensitive seams and wire it into `verify-portable` + CI.
- **Depends on:** claim 9358 (the glyph mutation check + named gate), claim 9263 (full-table goldens), claim 8742 (the LSB-first fix).
- **Status:** ✅ done 2026-08-15

## The generalization

`tools/verify-mutations.sh` (new, class A) is a manifest-driven mutation
gate. Each entry names a file, the exact old/new code strings, and the
module tests that MUST FAIL under the mutation; the gate applies the
mutation, runs the modules, requires failure, and restores the file. A
golden that does not fail against its mutation fails the gate.

Manifest entries (the kernel's bit-order-sensitive seams):

1. **font8x8 row_pixel** (the glyph raster convention, issue 125):
   reversing which bit is "leftmost" must break every raster golden
   (font8x8 + text + driving_award).
2. **FAT read_le endianness**: reading FAT entries big-endian instead of
   little-endian must break the mount/read/write tests. `read_le` is the
   ONE shared reader; `write_le` is left untouched so the write path still
   emits little-endian fixtures the tests compare against — a pure
   READ-side bit-order flip.
3. **virtio chain-walk NEXT bit**: `free_chain` walks the descriptor chain
   by testing bit 0 (VIRTQ_DESC_F_NEXT); testing the WRITE bit (0x2)
   instead must break the alloc/free/recycle tests.

## The design rule (learned from issue 125)

A mutation must NOT be self-consistent with the code under test. Mutating
a shared constant that both the production code AND the tests read is NOT
a valid check — both flip together and the tests stay green. Verified
empirically: mutating the `vq_next` CONSTANT (0x1 → 0x2) was caught only
by an accidental collision with `vq_write` (also 0x2), so each manifest
entry flips the READING of a bit/byte, never a constant both sides share.

## Wiring

- `tools/verify-mutations.sh` (new, class A, deterministic).
- `tools/verify-glyph-raster.sh` leg 3 now delegates to the generalized
  script (the glyph row_pixel mutation is manifest entry 1 — no duplicated
  mutation logic).
- `justfile` `verify-portable` + `.github/workflows/ci.yml`: the mutation
  gate runs in the class-A set (a separate named step in CI).
- `docs/gate-inventory.md`: `mutations` rows (human table + machine
  records, `class=A ci=yes`).

## Verification

- `bash tools/verify-mutations.sh` **PASS**: all three mutations applied,
  each module suite FAILED under its mutation (the acceptance proof), and
  the files were restored (`git status` clean afterwards).
- Each mutation validated both ways: green without the mutation, red with
  it (the negative control — the constant mutation — confirmed the design
  rule: it is NOT a valid check).
- `bash tools/verify-glyph-raster.sh` **PASS** via the delegation.
- Class A suite green (fmt, unit aggregate, transcript, build,
  coordination).
- CI runs the gate on every push/PR to `main`.
