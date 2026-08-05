# ADR 0001: AArch64 + UEFI + Zig, Swift-hosted, FAT boot medium

- Status: accepted (milestone zero)
- Date: 2026-08-05

## Context

DipshitOS is a from-scratch operating system. It is not Linux-based and must
not depend on libc, POSIX, or an existing guest OS. Milestone zero must
produce the smallest reliable pipeline that proves a compiled guest can boot
on real firmware and produce visible output, without building a kernel.

## Decisions

### 1. AArch64 as the initial architecture

The target is AArch64 (ARMv8+), the architecture of Apple silicon. The
primary development host is an Apple M4 Mac, so AArch64 is the only
architecture that can be exercised with the host's native virtualizer
(Virtualization.framework) without an emulator in the loop. All guest code
compiles for `aarch64-uefi`.

### 2. UEFI as the firmware interface

The guest speaks only the UEFI 2.x System Table interface: it uses
`SimpleTextOutput` (`ConOut`) to print and returns from its entry point to
give control back to firmware. UEFI is the de-facto firmware interface for
AArch64 servers and is what Apple Virtualization provides on this project's
target host. No legacy BIOS path.

### 3. Zig as the guest implementation language

Zig provides freestanding cross-compilation with no libc: a `uefi` OS target
with a built-in entry convention, no runtime, and no mandatory dependencies.
This fits the project's constraint of "no libc, no POSIX" in guest code
better than C (which drags in a runtime story) while staying low-level.
Zig 0.16.0 is pinned in `.zigversion`; the build system is written against
that release and documented as such.

### 4. Swift + Virtualization.framework as the macOS host launcher

On Apple silicon, Virtualization.framework boots custom UEFI images
natively (no emulation) and is available with the Xcode/Command Line Tools
Swift toolchain already installed. The launcher is deliberately minimal: it
configures only the devices needed to boot and observe output, validates the
configuration before starting, and captures the guest serial console.

### 5. FAT EFI system partition as the initial boot medium

The standard removable-media ARM64 UEFI path is `EFI/BOOT/BOOTAA64.EFI` on
a FAT volume. Milestone zero ships a GPT disk with a FAT32 ESP built by a
pure-Python tool (`image/mkfat32.py`) so image creation needs no root, no
mtools, and no loopback mounts.

### 6. QEMU as a secondary debugging environment — superseded 2026-08-05

Originally: QEMU `-M virt` with edk2 as a portable fallback/debug target
(scriptable, headless, shows the same UEFI output). **Superseded**: the
project now targets Apple silicon / Virtualization.framework only. The
`run-qemu` build step, the QEMU tooling, and all QEMU documentation were
removed on 2026-08-05.

### 7. The kernel is explicitly excluded from milestone zero

No kernel, ELF loader, allocator, scheduler, filesystem, graphics,
networking, SMP, or userspace code exists in this milestone. The milestone
ends at "guest UEFI application boots and prints". This keeps the proof
small enough to verify honestly and avoids committing to kernel
architecture before the boot pipeline is demonstrated.

## Consequences

- The guest binary runs under Apple Virtualization.framework's UEFI — the
  only supported host (QEMU support was removed 2026-08-05).
- Guest code has no libc/POSIX dependency, satisfying a hard project
  constraint from day one.
- The build tooling is pinned to Zig 0.16.0; upgrading requires revisiting
  `build.zig` and `build.zig.zon` (both are documented for that release).
- Image creation depends on Python 3 (present on macOS and most Linux
  distributions) but needs no privileged operations.
- Host-specific behavior (whether Apple's firmware routes UEFI console
  output to the virtio serial port) is treated as an empirical question and
  recorded in `docs/testing.md` and the README rather than assumed.
