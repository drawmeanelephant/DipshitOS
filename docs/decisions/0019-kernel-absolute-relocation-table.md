# ADR 0019: Kernel absolute-relocation table (image format v2, magic "KRN2")

Status: **ACCEPTED** (claim issue #1042) · Date: 2026-09-10 · Milestone:
M43 — Device depth (USB beyond HID), U1 follow-up

## Context

ADR 0002 D1 chose a flat kernel image ("DSK1") with **no loader relocation
pass**, on the premise that the kernel is position-independent by
construction: every internal reference is `adr`/`adrp` (PC-relative), so
placing the content at `base+0` keeps it valid at any 4K-aligned load base
(ADR 0002 D4). ADR 0002's consequences explicitly said that adding
relocations later would be a new ADR.

That premise turned out to be **incomplete**. PC-relative codegen covers
*instructions*, but the toolchain also emits **absolute, base-0 pointer
tables in initialized data** for some code shapes. The M43 U1 boot died
silently: a `switch` over four field addresses made LLVM emit a link-time
absolute pointer table; the loader placed the image at `0x7dd25000` and
never patched the table, so the first dereference used a base-0 value and
killed the guest with no exception print (evidence #1040, fix #1041).

A sweep with `lld --emit-relocs` (2026-09-10) measured the class kernel-wide:

| section | `R_AARCH64_ABS64` | resolves to |
|:--|--:|:--|
| `.rela.rodata` | 70 | LLVM jump tables (`$d`), `shell.park_body`, `Io.Writer.*` |
| `.rela.data` | 44 | outlined `driving_award.paint_scene` blocks |
| `.rela.text` | 0 | all `ADR_PREL` / `ADD_ABS_LO12` / `CALL26` |

114 absolute slots were live and unrelocated — latent because the current
gates do not branch through them, but the U1 crash proved the class is
reachable. The source-level sweep is clean (the only pointer-valued
`switch` was the U1 site, now `@offsetOf`-based), so a coding convention
alone cannot prevent a compiler from reintroducing the pattern.

## Decisions

### D1. Image format v2 ("KRN2") carries an absolute-relocation table

`\KERNEL.BIN` gains a second format. The header grows from 24 to 40 bytes
and the file gains a table after the loadable content:

| offset | size | field |
|--------|------|-------|
| 0      | u32  | magic `0x324E524B` ("KRN2") |
| 4      | u32  | flags (0) |
| 8      | u64  | `entry_offset` — file-relative, includes the 40-byte header |
| 16     | u64  | `image_size` — total file size (header + content + table) |
| 24     | u64  | `reloc_offset` — file offset of the table |
| 32     | u64  | `reloc_count` — number of 24-byte entries |
| 40     | …    | loadable content (same layout as v1) |
| `reloc_offset` | 24 × count | `{ u64 offset, u64 value, u32 width, u32 _ }` |

`offset` is a **content offset** (`vaddr - image base`), `value` is the
link-time base-0 absolute address, and `width` is 8 (`ABS64`) or 4
(`ABS32`). The loader writes `(value + kernel_base)` at `content[offset]`
as `width` bytes, after the content load and before the cache flush. A
malformed or out-of-bounds entry aborts the handoff (the loader returns)
rather than jumping into a half-patched image.

The v1 "DSK1" format still loads (no table, no patches); legacy user
images are unaffected (they are exec'd by the kernel, not the boot stub).

### D2. `elf2bin.py --relocs` derives the table from lld relocation records

`build.zig` links the kernel with `link_emit_relocs = true` and clears
`strip` (lld forbids `--emit-relocs` with `--strip-all`; the retained
symbols are non-`PT_LOAD`, so the flat image is unchanged by them).
`elf2bin.py --relocs` parses every `SHT_RELA` section, keeps the
`R_AARCH64_ABS64`/`ABS32` entries whose target section is allocatable,
file-backed and inside a `PT_LOAD`, and reads the **already-linked bytes**
at each site as the value (lld resolves symbol+addend in place, so no
symbol-table walk is needed). Any other absolute type (`ABS16`/`ABS8`) in
loadable content is a hard build failure, so an unrepresentable absolute
reference can never silently ship.

### D3. The retained symbols stay out of the runtime image

`strip = false` inflates the emitted **ELF** (symtab, `.rela.*` for
`.text`/`.debug_*`), not the flat image: `elf2bin` copies only `PT_LOAD`
bytes and appends the table. Runtime RAM and the on-disk `KERNEL.BIN`
size are effectively unchanged apart from the table (114 × 24 B ≈ 2.7 KiB).

## Evidence (observed on Apple M4 / macOS 27 / Zig 0.16.0, 2026-09-10)

- `zig build` emits `KRN2 ... reloc_count=114`; `zig build` exits 0.
- `live-usb-bulk` **PASS 2/2** on VZ (the exact M43 U1 regression path).
- `live-args` **PASS 1/1**; `live-args` had been deterministically failing
  before the payload write-atomicity fix (below), so both the loader pass
  and the payload are exercised.
- `live-args` also surfaced a **pre-existing print atomicity bug** in
  `USER.BIN`: each `user: arg=<n>` line was three `sys_write`s (prefix,
  arg, newline), so a timer preemption between them split a logical line
  and tripped the gate's substring assertion once the kernel's timing
  shifted. Fixed by building the line in a stack scratch and emitting it
  in one `sys_write` (same bytes, one call) — the gate is now deterministic.
- Class-A: `zig fmt` clean, `zig build test` and the portable gate suite
  (below) green.

## Consequences

- The kernel is position-independent again **in behaviour**, without
  requiring the compiler to avoid absolute tables: any the toolchain emits
  are captured and patched. New absolute relocations need no source change.
- A new gate class is created: the build **cannot** produce a KRN2 image
  with an unrepresentable absolute relocation, so the U1 failure shape
  (`no exception print, VM stops`) cannot recur silently.
- The loader grows an ELF-relocation-aware path; ADR 0002 D1's "no
  relocation pass" premise is superseded for the kernel image (0002 stays
  the record of the v1 format and the content-at-`base+0` invariant).
- Adding further image formats or a dynamic linker seam is again a new ADR.
