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

The project targets Apple silicon / Virtualization.framework only; there is
no QEMU path.

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
  services available, per the UEFI spec. **Superseded for the kernel
  proper by milestone two**: ADR 0004 records the ExitBootServices design;
  from milestone two on, the boot stub never exits (it keeps this
  constraint forever) while the kernel proper may touch MMU and device
  MMIO under the assumptions in the next section.
- **Resolved quirk (observed)**: the milestone-one `KERNEL.TXT` corruption
  — the kernel's *own* file writes landing as shifted slices of its
  `.rodata` while the loader's identical writes landed byte-perfect — is
  fixed. The loader parses the 24-byte DSK1 header but does **not** load it
  into RAM: the image content sits at `base+0`, so ELF VMA `V` is at RAM
  `base+V`. This is the addressing invariant the kernel's PC-relative
  references depend on — `adr` rides the content offset inside the PC,
  while `adrp`+`add` computes `(PC page) + VMA offset` and only resolves
  correctly with the content at `base+0`. **[observed]** — `KERNEL.TXT` is
  byte-perfect and byte-identical across repeated boots (ADR 0002,
  `artifacts/m1-fix-run{1,2,3}.txt`).

## Milestone two: the kernel proper (planned, ADR 0004 — all assumptions **[inferred]**)

Milestone two is designed but not implemented; every assumption below is
**[inferred]** (documentation/reasoning only) and each must be flipped to
**[observed]** with log evidence before milestone three may rely on it.
The concrete numbers are deliberately isolated so one observed probe can
correct them without redesign.

### MMU

- The kernel runs at EL1 with the MMU **enabled** and the firmware's
  identity map in effect at kernel entry; the firmware does not disable
  the MMU when jumping. **[inferred]** — standard UEFI AArch64 behavior;
  consistent with milestone-one runs but not directly observed.
- The kernel builds its own translation tables (never firmware tables):
  TTBR0_EL1, 4K granule, identity map (VA == PA) for RAM, the kernel
  image, and the MMIO windows the drivers need. **[inferred]** — this is a
  design choice, not a hardware fact; it is recorded here because later
  milestones depend on the address space being under kernel control.
- MAIR_EL1 uses two attributes: Device `nGnRnE` for MMIO and Normal
  Write-Back for RAM. **[inferred]** — standard ARMv8 attribute set.
- IPS (physical address size) is read from `ID_AA64MMFR0_EL1` at runtime.
  **[inferred]** — standard CPU register; the exact value reported by VZ
  is unobserved.

### MMIO / serial console (UART)

- A memory-mapped serial console device is reachable by the guest from
  EL1. **[inferred]** — VZ configures a virtio console serial port; its
  register interface is undocumented by Apple and no register has been
  observed.
- The device's **base address and register layout** are unknown.
  **[inferred]** — primary candidate is a PL011-style register file (ARM
  SBSA standard); 16550-style and the VZ virtio-console register file are
  the alternatives a milestone-starting device probe must discriminate
  between. If no serial device is observable, evidence falls back to a
  fixed physical memory marker the host dumps (ADR 0004 D4).
- Virtio devices sit in an MMIO window whose address range is
  undocumented. **[inferred]** — the exact range is discovered by the same
  probe.

### Interrupts (not programmed in milestone two)

- A GIC (Generic Interrupt Controller, ARM GIC architecture) is present
  and is the interrupt controller a later timer/GIC milestone will
  program. **[inferred]** — per the ARM virtual-platform architecture VZ
  emulates; not observed and not touched in milestone two.
- Interrupts are masked at kernel entry (firmware boots with them
  masked). **[inferred]** — standard firmware behavior; the kernel keeps
  them masked in milestone two.

## What milestone zero does NOT assume (and does not touch)

- No direct MMIO. No UART programming. No DMA. No interrupts. No GIC.
- No memory map assumptions beyond what the firmware provides.
- No timer services. (The "wait" in the boot application is a plain busy
  loop with no hardware access.)
- No platform clock, no RTC, no power management.
