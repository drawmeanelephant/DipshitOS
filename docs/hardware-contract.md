# DipshitOS hardware contract

This file records every hardware and firmware assumption the project makes.
Anything listed here is a commitment: code in later milestones must either
honor it or update this file first. Entries are tagged **[observed]** when we
have log/command evidence on a real machine and **[inferred]** when the
assumption comes from documentation or reasoning only.

## Instruction set

- **AArch64 (ARMv8 / ARMv9-A)**. All guest code compiles for
  `aarch64-uefi`. **[observed]** — the EFI binary is AArch64 PE/COFF (see
  `zig build inspect` output).

## Firmware interface

- **UEFI 2.x**. The guest uses only the EFI System Table: the
  `SimpleTextOutput` protocol (`ConOut`) and, implicitly, the standard
  "return from entry point" exit convention.
- The standard removable-media ARM64 boot path is used:
  `\EFI\BOOT\BOOTAA64.EFI` on a FAT volume.
- **[inferred]** Firmware scans removable media for `BOOTAA64.EFI` when no
  explicit boot entry exists (both edk2 and Apple Virtualization implement
  this part of the UEFI spec).

## Hosts and their devices

### Apple Virtualization.framework (macOS, Apple silicon)

- UEFI firmware: Apple's Virtualization EFI. Vendor and revision are
  unknown/undocumented by Apple. **[inferred]**
- Disk: virtio block device (`VZVirtioBlockDeviceConfiguration`), attached
  read-write so the guest can write its evidence file.
- Console: virtio console serial port
  (`VZVirtioConsoleDeviceSerialPortConfiguration`). **Observed**: on
  macOS 27 / Apple silicon, Apple's EFI firmware does NOT route UEFI
  `ConOut` to this port; the captured log stays empty.
- Framebuffer: virtio-gpu with a 1280x720 scanout shown in a
  `VZVirtualMachineView`. **Observed**: the firmware renders nothing to it;
  captured PNGs are blank/gray. UEFI text is therefore NOT visible on the
  VZ framebuffer either.
- Execution evidence: the guest also writes its message to `\BOOTED.TXT` on
  the ESP via the UEFI Simple File System protocol. **Observed**: after a
  VZ boot, the file exists on the image with the exact expected content.
  This is the primary, host-observable proof of guest execution on Apple
  silicon.
- EFI variable store: file-backed (`VZEFIVariableStore`), persisted at
  `artifacts/efi-vars.bin`. Creating one requires
  `init(creatingVariableStoreAt:options:)` on first boot; `init(url:)` only
  opens an existing store.
- Config used: 256 MiB RAM, 2 vCPUs, optional virtio-gpu for observation,
  no networking.

### QEMU `-M virt` (aarch64)

- Firmware: edk2 `QEMU_EFI.fd` (`edk2-aarch64-code.fd`), either passed via
  `-bios` or QEMU's built-in default. **[inferred]** on this machine —
  QEMU is not installed here.
- Console: `-nographic -serial stdio`; edk2 redirects UEFI console output
  to the serial port in this configuration. **[inferred]**
- Disk: `virtio-blk-device` with a `format=raw` drive.

## Milestone one: kernel handoff (2026-08-05, branch `m1-kernel-handoff`)

- **Kernel image on the ESP**: `\KERNEL.BIN` is read from the same FAT
  volume via the UEFI Simple File System protocol. **[observed]** — the
  loader reads the file; `LOADER.TXT` records the size it read and the
  first 16 bytes that landed in RAM.
- **Kernel image allocation**: `AllocatePages` with type `EfiLoaderCode`.
  The loader may place the image at any free 4K-aligned address (observed
  at 0x7e55f000 and at 0x7f328000 in different runs); the kernel must be
  position-independent. **[observed]** — `MEMMAP.TXT` shows the allocation
  in ordinary cacheable RAM (`xp=0 wb=1`).
- **Cache maintenance before the jump**: the loader cleans the D-cache and
  invalidates the I-cache over the image (`dc cvau` / `ic ivau` / `dsb` /
  `isb`) before transferring control. **[observed]** — without correct
  handling the kernel never executes (RC.TXT absent); with it the kernel
  runs and returns.
- **The kernel runs without `ExitBootServices`**: it keeps using UEFI Boot
  Services and the Simple File System protocol (its evidence write), on the
  loader's stack. Until a later milestone records an ExitBootServices
  design here, no guest code may touch MMU, interrupts, timers, or device
  MMIO directly. **[inferred]** — we rely on the firmware keeping these
  services available, per the UEFI spec.
- **Known quirk (observed)**: on Apple VZ firmware the kernel's *own* file
  writes land scrambled (the file is created with the right size, but the
  bytes are shifted slices of the kernel image's `.rodata`), while the
  loader's identical writes land byte-perfect. Recorded as a known issue in
  ADR 0002; root cause not yet determined. QEMU/edk2 behavior is not yet
  observed (QEMU not installed).

## What milestone zero does NOT assume (and does not touch)

- No direct MMIO. No UART programming. No DMA. No interrupts. No GIC.
- No memory map assumptions beyond what the firmware provides.
- No timer services. (The "wait" in the boot application is a plain busy
  loop with no hardware access.)
- No platform clock, no RTC, no power management.
