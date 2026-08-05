# ADR 0002: Kernel handoff format and ABI (milestone one)

Status: **accepted** · Date: 2026-08-05 · Milestone: one

## Context

Milestone one requires loading a *separate* AArch64 kernel image from the
ESP and transferring control to its entry point. The loader (`boot/`) and
the kernel (`kernel/`) are compiled separately: the loader is an AArch64
UEFI application, the kernel is an `aarch64-freestanding` blob with no
libc/POSIX/OS. The two must agree on an image format and a register-level
handoff contract, and the milestone must be provable from the host using
the project's observed-vs-inferred evidence rule.

## Decisions

### D1. The kernel image is a flat binary (format v1, magic "DSK1"), not a raw ELF

The on-ESP file `\KERNEL.BIN` is a 24-byte header followed by the raw
loadable content:

| offset | size | field |
|--------|------|-------|
| 0      | u32  | magic `0x314B5344` ("DSK1") |
| 4      | u32  | flags (0) |
| 8      | u64  | `entry_offset` — bytes from the **start of the file** to the entry point (i.e. includes the 24-byte header) |
| 16     | u64  | `image_size` — total file size including the header |
| 24     | …    | loadable content |

`tools/elf2bin.py` converts the linked freestanding ELF into this format:
it places the PT_LOAD segments at their `vaddr` relative to the lowest
segment vaddr (preserving the linker's exact relative layout so PC-relative
`adr/adrp` addressing stays valid at any 4K-aligned load base) and
zero-fills `memsz > filesz` tails (BSS).

Rationale: the kernel is position-independent by construction (see D4), so
a flat image avoids the loader needing an ELF parser, a relocation pass, or
a dynamic section — a smaller, more auditable loader. The header keeps the
loader honest (magic, size cap, explicit entry) and lets host tools
(`elf2bin.py --info`, `mkfat32.py --cat-file`) verify the image on disk.

### D2. No `ExitBootServices` in milestone one

The kernel keeps running with the full UEFI Boot Services environment
(and on the loader's stack). It uses the EFI System Table and the Simple
File System protocol for its evidence write, exactly like the loader.
Consequences for the hardware contract: the kernel may not touch MMU,
interrupts, timers, or any device directly until a later milestone records
an ExitBootServices design in the contract. This is the same posture the
loader already has, so milestone one adds no new firmware dependencies.

### D3. The loader allocates the kernel image as `EfiLoaderCode` via `AllocatePages`

The loader reads the image header, sanity-checks magic/size, allocates
`ceil(image_size / 4096)` pages of type `EfiLoaderCode` (not
`EfiLoaderData`), and copies the file into them. `EfiLoaderCode` is used
because firmware may map data-type memory as execute-never, and the loader
is about to execute this memory — the same choice real UEFI bootloaders
make. `AllocatePages` returns 4K-aligned pages, which is the alignment the
kernel's PC-relative addressing relies on. `image_size` is capped at 16 MiB
as a sanity bound for this milestone.

### D4. The kernel is always built `ReleaseSmall`, with a dense linker script

`build.zig` pins the kernel to `ReleaseSmall` regardless of the loader's
build mode. Debug mode pulls in the safety runtime (`ubsan_rt` etc.) which
bloats the flat blob and emits absolute-address `movk` chains, violating the
load-anywhere contract. `kernel/linker.ld` lays the loadable sections out
densely from address 0; without it lld's default 64 KiB max-page-size
padding inflates the image ~100x (66 KiB → 0.7 KiB for the same code).

Position independence is verified before each change by disassembling the
linked ELF: all internal references must be `adr`/`adrp` (PC-relative), with
no absolute `movk` chains.

### D5. The loader performs cache maintenance before the jump

The image bytes are written by data accesses, so before jumping the loader
cleans the D-cache to the point of unification and invalidates the I-cache
over the image (`dc cvau` + `ic ivau`, per byte, then `dsb ish` and `isb`)
— the same maintenance the firmware's own `LoadImage` performs. Without it
the instruction stream can be stale on ARMv8.

### D6. Handoff ABI (AAPCS64, register arguments on entry)

| register | value |
|----------|-------|
| x0 | kernel image base address (4K-aligned) |
| x1 | kernel image size in bytes |
| x2 | pointer to the EFI System Table |
| x3 | pointer to the already-open ESP root directory (`EFI_FILE_PROTOCOL`) |
| x0 (return) | u64 status; 0 = success |

The kernel runs on the loader's stack and returns to the loader, which
returns to the firmware.

## Evidence (observed on Apple M4 / macOS 27 / Zig 0.16.0)

`zig build`, `zig build image`, and `zig build run` complete. After a VZ
boot the ESP contains (all host-readable via `python3 image/mkfat32.py
--cat-file`):

- `BOOTED.TXT` — loader evidence; exact expected content. **Observed.**
- `LOADER.TXT` — loader-observed kernel placement: `base=`, `size=`,
  `entry_offset=0x18`, `first8=0x314b5344` (magic), `second8` (entry) —
  proving the copy landed byte-perfect. **Observed.**
- `RC.TXT` — `kernel_rc=0x0000000000000000` — the kernel executed and
  returned 0 to the loader. **Observed.** This is the primary handoff proof.
- `MEMMAP.TXT` — the EFI memory map (27+ descriptors, all RAM `xp=0 wb=1`);
  the kernel allocation sits in ordinary cacheable RAM. **Observed.**
- `KERNEL.BIN` — the flat image, verified by `elf2bin.py --info`
  (`entry_offset=0x18`, size, magic). **Observed.**

## Known issue (observed, unresolved): kernel-side file writes are scrambled on VZ

The kernel's own write to `\KERNEL.TXT` executes (the file is created with
the write's exact size and the kernel's write path returns normally), but
the stored bytes are scrambled: they are shifted slices of the kernel
image's own `.rodata` rather than the intended content. This is **observed**
and reproducible across kernel load addresses (0x7e55f000 and 0x7f328000
both corrupt) and with or without caller-side `dc cvac` cleaning of the
write buffer.

Investigation so far (all recorded in `artifacts/m1-run*.txt`):
- The loader's identical file-write pattern (open → write → flush → close,
  including repeated open/setPosition(0) probes) lands **byte-perfect**
  before and after the jump — so the firmware's Simple File System path and
  the loader's buffers are not the problem.
- The kernel's string constants are byte-intact at their load-time offsets
  (dumped from memory by the loader via the `IMGDATA.TXT` probe) and the
  kernel's `adr` targets match them — so the kernel passes correct
  pointers.
- The scrambled bytes vary in offset run to run and are slices of the
  kernel image region — consistent with the firmware's storage path reading
  a stale/incoherent view of the kernel allocation (a VZ firmware cache or
  DMA quirk), not with a kernel logic bug.

Consequence: milestone-one proof does **not** rest on `KERNEL.TXT`
content. `zig build run` gates on `BOOTED.TXT` (loader ran) and `RC.TXT`
(kernel ran and returned) and prints `KERNEL.TXT` for the record. The next
milestone prompt carries the root-cause thread forward (see
`docs/roadmap.md`). (There is no QEMU path in this project; Apple VZ is the
only supported host.)

## Consequences

- The loader stays ~600 lines of pure UEFI services; the kernel is a few
  hundred bytes of freestanding Zig.
- Adding ELF loading, relocations, or ExitBootServices later is a new ADR,
  not a patch to this one.
- Any change to the flat format or ABI must update this ADR, `elf2bin.py`,
  the loader, and the kernel together.
