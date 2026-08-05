# DipshitOS roadmap

## Milestone zero (this milestone) — boot pipeline proof

A tiny AArch64 UEFI application, written in Zig, is built, placed at
`EFI/BOOT/BOOTAA64.EFI` on a FAT32 ESP inside a GPT image, and booted under
UEFI by (a) the Swift Virtualization.framework launcher and, where
installed, (b) QEMU. The application prints

```
DIPSHITOS BOOTLOADER
firmware has agreed to cooperate
```

and returns control to the firmware.

Deliverables: `boot/`, `host/vm-runner/`, `image/`, `tools/`, `docs/`,
`build.zig`, `build.zig.zon`, `AGENTS.md`, `README.md`.

**No kernel, loader, allocator, scheduler, filesystem, graphics, networking,
SMP, or userspace exists at the end of this milestone.**

## Milestone one (next) — separate kernel image

> Load a separate AArch64 kernel image and transfer control to its entry point.

Not started. Nothing in milestone zero anticipates it beyond keeping the
guest free of libc/POSIX and keeping the firmware interface honest (UEFI
Boot Services, loaded image protocol).

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
