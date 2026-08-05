# DipshitOS roadmap

## Milestone zero (this milestone) — boot pipeline proof

A tiny AArch64 UEFI application, written in Zig, is built, placed at
`EFI/BOOT/BOOTAA64.EFI` on a FAT32 ESP inside a GPT image, and booted under
UEFI by the Swift Virtualization.framework launcher (Apple silicon only;
there is no QEMU path in this project). The application prints

```
DIPSHITOS BOOTLOADER
firmware has agreed to cooperate
```

and returns control to the firmware.

Deliverables: `boot/`, `host/vm-runner/`, `image/`, `tools/`, `docs/`,
`build.zig`, `build.zig.zon`, `AGENTS.md`, `README.md`.

**No kernel, loader, allocator, scheduler, filesystem, graphics, networking,
SMP, or userspace exists at the end of this milestone.**

## Milestone one — separate kernel image (implemented)

> Load a separate AArch64 kernel image and transfer control to its entry
> point.

**Implemented** on branch `m1-kernel-handoff` (see
`docs/decisions/0002-kernel-handoff.md`): the boot UEFI app loads
`\KERNEL.BIN` (flat format v1, magic "DSK1") from the ESP via the Simple
File System protocol, allocates `EfiLoaderCode` pages with Boot Services,
copies the image, performs D/I-cache maintenance, and jumps to the kernel
entry (handoff ABI: x0 = base, x1 = size, x2 = System Table, x3 = open
root directory; the kernel returns a u64 status). The kernel is a few
hundred bytes of freestanding Zig and returns 0.

Observed evidence on Apple M4 / macOS 27: `BOOTED.TXT` (loader ran),
`LOADER.TXT` (loader-observed placement, byte-perfect copy), `RC.TXT`
(`kernel_rc=0x0` — the kernel ran and returned), `MEMMAP.TXT`.

**Known issue (observed):** the kernel's own `\KERNEL.TXT` write lands
scrambled on Apple VZ firmware (shifted slices of the kernel image's
.rodata) while the loader's identical writes are byte-perfect. Root cause
not yet determined; investigation state is recorded in ADR 0002 and
`artifacts/m1-run*.txt`. The milestone gates on `RC.TXT`, not `KERNEL.TXT`.

Next steps for this milestone's loose ends:
- Root-cause the VZ `KERNEL.TXT` corruption (ADR 0002 "Known issue").

## Later milestones (sketches only, not commitments)

- Kernel proper in Zig: identity-map MMU setup, a minimal UART console
  driver, and a hand-off contract from the boot stub.
- A memory allocator and boot-time memory map walk (EFI memory map via Boot
  Services).
- Interrupt setup (GIC) and a timer.
- Eventually: a process abstraction, a filesystem, a network stack — each
  only when the ones below it are demonstrably working.

Each milestone must state what was **observed** versus **inferred** and must
record new hardware assumptions in `docs/hardware-contract.md`.
