# DipshitOS architecture

## Current state (milestones zero and one implemented; milestone two next)

Milestone zero proved, end to end, that a Zig-compiled AArch64 UEFI
application can be built, placed on a FAT-formatted boot medium at the
standard removable-media path, and executed by real firmware, with its
output observed on a host. Milestone one added a separate freestanding
kernel image: the boot application loads `\KERNEL.BIN` from the ESP,
allocates `EfiLoaderCode` pages, copies the image, performs D/I-cache
maintenance, and jumps to the kernel entry (see
`docs/decisions/0002-kernel-handoff.md`). The project targets Apple silicon
/ Virtualization.framework only; there is no QEMU path.

**Next phase — milestone two, the kernel proper** (designed in
`docs/decisions/0004-kernel-proper.md`, not yet implemented): the kernel
calls `ExitBootServices` itself and keeps the machine — it captures the
EFI memory map before exit, replaces the firmware's page tables with its
own identity-map tables (TTBR0_EL1, 4K granule), and drives a minimal MMIO
serial console, printing `DipshitOS kernel has seized control.` directly to
the device the firmware never used. No firmware services remain in use
after exit; output moves from `\BOOTED.TXT` (a UEFI protocol) to the
serial log. See `docs/roadmap.md` for the milestone-two gates.

## Components

| Component | Where | Role |
|-----------|-------|------|
| Guest boot loader | `boot/src/main.zig` | AArch64 UEFI application; prints via Simple Text Output, loads `\KERNEL.BIN` from the ESP, jumps to the kernel entry, writes host-readable evidence (`\BOOTED.TXT`, `\LOADER.TXT`, `\RC.TXT`) |
| Boot medium | `image/mkfat32.py` + `image/make-image.sh` | GPT disk with a FAT32 EFI System Partition containing `EFI/BOOT/BOOTAA64.EFI` |
| macOS host launcher | `host/vm-runner/` (Swift + Virtualization.framework) | Boots the image under UEFI on Apple silicon, captures the guest serial console and framebuffer |
| Build system | `build.zig`, `build.zig.zon`, `justfile` | Compile, kernel, image, run, inspect, context |
| Evidence tooling | `tools/inspect.sh`, `tools/context/` | Binary/image inspection and a deterministic project snapshot |

## Data flow

```
boot/src/main.zig  ──zig build──▶  zig-out/bin/BOOTAA64.EFI   (PE/COFF, AArch64)
                                        │
image/make-image.sh ──mkfat32.py──▶  artifacts/disk.img        (GPT + FAT32 ESP)
                                        │
        ▼
VZEFIBootLoader (macOS VZ)
   └─ UEFI firmware boots EFI/BOOT/BOOTAA64.EFI
        │
        └── ConOut ──▶ virtio console ──▶ artifacts/vm-serial.log  (empty: firmware doesn't route ConOut here)
        └── loader loads \\KERNEL.BIN ──▶ kernel entry
             │  milestone two: ExitBootServices, identity-map MMU
             └── uart MMIO ──▶ virtio console ──▶ artifacts/vm-serial.log  (planned: first real content)
             └── milestone one: kernel returns ──▶ RC.TXT
```

## Interfaces

- **Guest ↔ firmware:** the UEFI System Table only, and only until
  milestone two's `ExitBootServices`. Milestone zero calls
  `SimpleTextOutput.OutputString` (`ConOut`) and then returns, which is the
  UEFI-defined way to give control back to firmware. In milestone two the
  kernel calls `ExitBootServices` itself (per ADR 0004) and no UEFI
  protocol is usable afterwards.
- **Guest ↔ host storage:** the disk is presented as a virtio block device.
  The guest never touches the storage device directly in milestones zero
  and one; the firmware reads `EFI/BOOT/BOOTAA64.EFI` from it, and both the
  loader and the kernel write evidence files through the UEFI Simple File
  System protocol.
- **Guest → host console:** a virtio console serial port. Observed on Apple
  silicon: the VZ firmware does not route `ConOut` there (empty log) and
  renders no text to the virtio-gpu framebuffer (blank captures).
  Milestone two plans to drive that device directly from the kernel via
  MMIO (the `uart` console driver, ADR 0004 D4) so the log gets its first
  real content; the device's register layout is `[inferred]` until a probe
  observes it (see `docs/hardware-contract.md`).
- **Guest → host evidence:** because the VZ firmware exposes no visible
  text channel, the guest also writes its two lines to `\BOOTED.TXT` on the
  ESP via the UEFI Simple File System protocol. The host reads that file
  back with `image/mkfat32.py --cat-file`; this is the observed proof of
  execution on Apple silicon (see `docs/testing.md`).

## Non-goals (explicit exclusions for the current phase)

Milestone two ships the kernel proper but still excludes: an allocator
beyond fixed carve-outs, an ELF loader, memory management beyond the
identity map, interrupts/GIC, timers, a scheduler, processes, filesystems,
graphics, networking, SMP, syscalls.

- libc or POSIX in guest code. The guest is freestanding Zig for
  `aarch64-uefi`; the boot app links nothing, and the kernel's only direct
  hardware touch in milestone two is the MMU and the serial device.

## Observed vs inferred

The project keeps a strict separation between **observed** behavior (output
of commands and logs, saved under `artifacts/`) and **inferred** behavior
(what we believe from documentation or reasoning). Claims of successful
boots are only made where a log shows the expected output. See
`docs/testing.md`.
