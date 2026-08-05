# DipshitOS

A from-scratch AArch64 operating system. Not Linux-based. No libc, no POSIX,
no existing guest OS. Guest code is written in Zig; the host launcher is
Swift. See `AGENTS.md` for the project rules.

**Status: milestone zero complete.** Milestone zero proves the smallest
reliable boot pipeline: a Zig-compiled AArch64 UEFI application on a FAT
boot medium, executed by real firmware, with its output observed on the
host. **No kernel, loader, allocator, scheduler, filesystem, graphics,
networking, SMP, or userspace exists yet.**

## The guest

`boot/src/main.zig` is an AArch64 UEFI application. It prints exactly

```
DIPSHITOS BOOTLOADER
firmware has agreed to cooperate
```

via the UEFI Simple Text Output protocol, waits briefly, and returns control
to the firmware. On Apple silicon, where the Virtualization firmware exposes
no visible text channel (see *Observed behavior*), it additionally writes
the same two lines to `\BOOTED.TXT` on the ESP through the UEFI Simple File
System protocol — still pure UEFI services, still no libc/POSIX.

## Toolchain

Pinned in `.zigversion`: **Zig 0.16.0**. The build system is written against
that release (see `docs/decisions/0001-arm64-uefi-zig.md` for the API
adjustments). Other tools used at build/run time: Swift (macOS 13+,
Apple silicon for the Virtualization path), Python 3 (disk image tooling),
`bash`. QEMU is optional and used only for the secondary boot path.

## Quickstart

```bash
zig build          # compile the AArch64 UEFI application -> zig-out/bin/BOOTAA64.EFI
zig build image    # build the GPT+FAT32 boot image -> artifacts/disk.img
zig build run      # boot it with Swift + Virtualization.framework (Apple silicon)
zig build run-qemu # boot it with QEMU (requires qemu-system-aarch64)
zig build inspect  # inspect the EFI binary and the disk image
zig build context  # regenerate artifacts/context.md (deterministic project snapshot)
```

`just` aliases exist for the same commands (`just build`, `just image`, ...).

## Repository layout

```
dipshitos/
├── AGENTS.md                  project rules (read this first)
├── README.md
├── build.zig / build.zig.zon  root build system (Zig 0.16)
├── justfile                   command aliases
├── .zigversion                pinned Zig version (0.16.0)
├── boot/src/main.zig          the AArch64 UEFI guest application
├── host/vm-runner/            Swift Virtualization.framework launcher
│   ├── Package.swift
│   ├── entitlements.plist     com.apple.security.virtualization
│   └── Sources/VMRunner/main.swift
├── image/
│   ├── make-image.sh          FAT32+GPT image builder (no root, no mtools)
│   └── mkfat32.py             pure-Python FAT32+GPT builder/lister/cat
├── tools/
│   ├── inspect.sh             EFI binary + image inspection (degrades gracefully)
│   └── context/               project-context generator + review prompt
├── docs/                      architecture, hardware contract, roadmap,
│                              testing, decisions/ADR 0001
└── artifacts/                 build evidence (gitignored)
```

## Verification results (observed on this development host)

Host: Apple M4, macOS 27.0 (arm64), Zig 0.16.0, Swift 6.2.3 (arm64), no QEMU.

| Step | Command | Result |
|------|---------|--------|
| Build EFI app | `zig build` | **Observed**: `zig-out/bin/BOOTAA64.EFI` — `PE32+ executable (EFI application) Aarch64` |
| Inspect binary | `zig build inspect` | **Observed**: `file format coff-arm64`, subsystem `0x0a (EFI application)`, `.text/.data/.pdata/.reloc` sections, real AArch64 disassembly |
| Build image | `zig build image` | **Observed**: 64 MiB GPT+FAT32 image; `EFI/BOOT/BOOTAA64.EFI` (139264 B) present; volume label `DIPSHITOS` |
| Inspect image | `zig build inspect` | **Observed**: `DOS/MBR boot sector` (protective), GPT header crc valid, ESP `LBA 2048..131038` |
| Build Swift runner | `zig build run` | **Observed**: SwiftPM build succeeds |
| Boot via Virtualization.framework | `zig build run` | **Observed**: VM boots; guest wrote `\BOOTED.TXT` to the ESP with exactly `DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n` |
| Boot via QEMU | `zig build run-qemu` | **Blocked**: `qemu-system-aarch64` not installed (command reports this clearly) |

All command output and logs are saved under `artifacts/` (`inspect.txt`,
`vm-serial.log`, `vm-screen-*.png`, `efi-vars.bin`, `context.md`).

### Observed behavior

- `zig build`/`image`/`inspect`/`run` all complete successfully on this host.
- The Virtualization.framework VM boots the GPT+FAT image: configuration
  validates, the EFI variable store is created, the VM starts and runs, and
  after boot the guest-written marker file `\BOOTED.TXT` exists on the ESP
  with the exact expected content. **This is direct evidence that the Zig
  UEFI application executed under Apple's firmware.**
- Apple's VZ EFI firmware does **not** route UEFI text to the virtio serial
  console (`vm-serial.log` is empty) nor render it to the virtio-gpu
  framebuffer (captured PNGs are blank; OCR finds no text). Hence the
  marker-file mechanism — no claim is made that serial output works on VZ.

### Inferred / not yet observed

- Apple's VZ EFI firmware loads `EFI/BOOT/BOOTAA64.EFI` from the ESP per the
  UEFI removable-media rule (consistent with the observed marker write, but
  the firmware's internal behavior is not directly observable).
- The QEMU path (edk2, `-nographic -serial stdio`) will show the same text
  on the serial console — **not yet observed** because QEMU is not
  installed. Install it with `brew install qemu` and run
  `zig build run-qemu`.

## Next milestone

> Load a separate AArch64 kernel image and transfer control to its entry
> point.

Not implemented. See `docs/roadmap.md`.
