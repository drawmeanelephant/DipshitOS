# DipshitOS architecture (milestone zero)

## Goal of milestone zero

Prove, end to end, that a Zig-compiled AArch64 UEFI application can be built,
placed on a FAT-formatted boot medium at the standard removable-media path,
and executed by real firmware, with its output observed on a host.

Milestone zero deliberately introduces **no kernel, no ELF loader, no
allocator, no scheduler, no filesystem, no graphics stack, no networking
stack, and no userspace**.

## Components

| Component | Where | Role |
|-----------|-------|------|
| Guest boot application | `boot/src/main.zig` | AArch64 UEFI application; prints a fixed two-line message via the UEFI Simple Text Output protocol, waits briefly, returns to firmware |
| Boot medium | `image/mkfat32.py` + `image/make-image.sh` | GPT disk with a FAT32 EFI System Partition containing `EFI/BOOT/BOOTAA64.EFI` |
| macOS host launcher | `host/vm-runner/` (Swift + Virtualization.framework) | Boots the image under UEFI on Apple silicon, captures the guest serial console |
| Secondary host | `zig build run-qemu` (QEMU `-M virt`) | Debug/secondary boot path; needs `qemu-system-aarch64` |
| Build system | `build.zig`, `build.zig.zon`, `justfile` | Compile, image, run, run-qemu, inspect, context |
| Evidence tooling | `tools/inspect.sh`, `tools/context/` | Binary/image inspection and a deterministic project snapshot |

## Data flow

```
boot/src/main.zig  ──zig build──▶  zig-out/bin/BOOTAA64.EFI   (PE/COFF, AArch64)
                                        │
image/make-image.sh ──mkfat32.py──▶  artifacts/disk.img        (GPT + FAT32 ESP)
                                        │
        ┌───────────────────────────────┼───────────────────────────────┐
        ▼                                                               ▼
VZEFIBootLoader (macOS VZ)                                      qemu-system-aarch64 -M virt
   └─ UEFI firmware boots EFI/BOOT/BOOTAA64.EFI                 └─ edk2 (if installed)
        │                                                               │
        └── ConOut ──▶ virtio console ──▶ artifacts/vm-serial.log       └── -serial stdio
```

## Interfaces

- **Guest ↔ firmware:** the UEFI System Table only. Milestone zero calls
  `SimpleTextOutput.OutputString` (`ConOut`) and then returns, which is the
  UEFI-defined way to give control back to firmware.
- **Guest ↔ host storage:** the disk is presented as a virtio block device
  (VZ) or `virtio-blk` (QEMU). The guest never touches it in milestone zero;
  the firmware reads `EFI/BOOT/BOOTAA64.EFI` from it.
- **Guest → host console:** a virtio console serial port. Observed on Apple
  silicon: the VZ firmware does not route `ConOut` there (empty log) and
  renders no text to the virtio-gpu framebuffer (blank captures). The QEMU
  path routes `ConOut` to the serial console when running `-nographic`
  (not yet observed here -- QEMU not installed).
- **Guest → host evidence:** because the VZ firmware exposes no visible
  text channel, the guest also writes its two lines to `\BOOTED.TXT` on the
  ESP via the UEFI Simple File System protocol. The host reads that file
  back with `image/mkfat32.py --cat-file`; this is the observed proof of
  execution on Apple silicon (see `docs/testing.md`).

## Non-goals (explicit exclusions for this milestone)

- Kernel, ELF loader, memory management, scheduler, processes, filesystems,
  graphics, networking, SMP, syscalls.
- libc or POSIX in guest code. The guest is freestanding Zig for
  `aarch64-uefi`; it links nothing and touches no hardware directly.

## Observed vs inferred

The project keeps a strict separation between **observed** behavior (output
of commands and logs, saved under `artifacts/`) and **inferred** behavior
(what we believe from documentation or reasoning). Claims of successful
boots are only made where a log shows the expected output. See
`docs/testing.md`.
