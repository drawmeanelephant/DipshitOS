# DipshitOS

[![CI](https://github.com/drawmeanelephant/DipshitOS/actions/workflows/ci.yml/badge.svg)](https://github.com/drawmeanelephant/DipshitOS/actions/workflows/ci.yml)

A from-scratch AArch64 operating system. Not Linux-based. No libc, no POSIX,
no existing guest OS. Guest code is written in Zig; the host launcher is
Swift. See `AGENTS.md` for the project rules.

**Status: milestone one implemented** on branch `m1-kernel-handoff`.
Milestone zero proved the smallest reliable boot pipeline (a
Zig-compiled AArch64 UEFI application on a FAT boot medium, executed by
real firmware, with its output observed on the host). Milestone one adds a
separate freestanding kernel image: the boot app loads `\KERNEL.BIN` from
the ESP, copies it to Boot Services memory, and jumps to its entry point;
the kernel runs and returns. **No allocator, MMU setup, interrupts,
scheduler, filesystem, graphics, networking, SMP, or userspace exists
yet.** See `docs/roadmap.md` and `docs/decisions/0002-kernel-handoff.md`.

Known issue: on Apple Virtualization firmware the kernel's own marker
file (`\KERNEL.TXT`) lands scrambled (observed firmware quirk, ADR 0002);
the milestone proof is `\RC.TXT` (`kernel_rc=0x0`), which is clean.

## The guest

`boot/src/main.zig` is an AArch64 UEFI application — now a tiny boot
**loader**. It prints via the UEFI Simple Text Output protocol, writes its
evidence to `\BOOTED.TXT` on the ESP (Apple silicon exposes no visible text
channel, see *Observed behavior*), then loads the separate kernel image
`\KERNEL.BIN` (flat format v1, see `docs/decisions/0002-kernel-handoff.md`)
from the ESP, allocates `EfiLoaderCode` pages, copies the image, performs
D/I-cache maintenance, and jumps to the kernel entry. It writes
`\LOADER.TXT` (observed placement), `\MEMMAP.TXT` (EFI memory map), and
`\RC.TXT` (the kernel's return code) as host-readable evidence.

`kernel/src/main.zig` is the milestone-one kernel stub: a few hundred bytes
of `aarch64-freestanding` Zig (no libc/POSIX) that writes its own
best-effort marker `\KERNEL.TXT`, prints via ConOut, and returns 0. It is
converted to the flat image by `tools/elf2bin.py`. Still pure UEFI
services throughout — no `ExitBootServices` yet (documented decision).

## Toolchain

Pinned in `.zigversion`: **Zig 0.16.0**. The build system is written against
that release (see `docs/decisions/0001-arm64-uefi-zig.md` for the API
adjustments). Other tools used at build/run time: Swift (macOS 13+, Apple silicon, for the Virtualization path), Python 3
(disk image tooling), `bash`. The project targets Apple silicon /
Virtualization.framework only — there is no QEMU path.

## Quickstart

```bash
zig build          # compile the AArch64 UEFI application -> zig-out/bin/BOOTAA64.EFI
zig build image    # build the GPT+FAT32 boot image -> artifacts/disk.img
zig build run      # boot it with Swift + Virtualization.framework (Apple silicon)
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
├── boot/src/main.zig          the AArch64 UEFI boot loader (milestone one)
├── kernel/                    freestanding AArch64 kernel stub
│   ├── src/main.zig           kernel entry (writes \\KERNEL.TXT, returns 0)
│   └── linker.ld              dense layout (avoids 64 KiB lld padding)
├── tools/elf2bin.py           ELF → flat KERNEL.BIN (format v1) converter
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
├── docs/                      architecture, branch protection, hardware contract,
│                              roadmap, testing, decisions (ADRs 0001–0003)
└── artifacts/                 build evidence (gitignored)
```

## Verification results (observed on this development host)

Host: Apple M4, macOS 27.0 (arm64), Zig 0.16.0, Swift 6.2.3 (arm64).

| Step | Command | Result |
|------|---------|--------|
| Build EFI app | `zig build` | **Observed**: `zig-out/bin/BOOTAA64.EFI` — `PE32+ executable (EFI application) Aarch64` |
| Inspect binary | `zig build inspect` | **Observed**: `file format coff-arm64`, subsystem `0x0a (EFI application)`, `.text/.data/.pdata/.reloc` sections, real AArch64 disassembly |
| Build image | `zig build image` | **Observed**: 64 MiB GPT+FAT32 image; `EFI/BOOT/BOOTAA64.EFI` (139264 B) present; volume label `DIPSHITOS` |
| Inspect image | `zig build inspect` | **Observed**: `DOS/MBR boot sector` (protective), GPT header crc valid, ESP `LBA 2048..131038` |
| Build Swift runner | `zig build run` | **Observed**: SwiftPM build succeeds |
| Boot via Virtualization.framework | `zig build run` | **Observed**: VM boots; guest wrote `\BOOTED.TXT` (exact content), `\LOADER.TXT` (base/size/entry + first16 bytes), and `\RC.TXT` (`kernel_rc=0x0`) — the kernel loaded, ran, and returned |
| Kernel image | `zig build` + `elf2bin.py` | **Observed**: `KERNEL.BIN` (format v1: magic `DSK1`, `entry_offset=0x18`, ~2 KiB) |
| Kernel marker `\KERNEL.TXT` | kernel write | **Observed**: file created, but content scrambled on VZ firmware (known issue, ADR 0002) |

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

## Next steps (see `docs/roadmap.md`)

1. Root-cause the observed VZ `KERNEL.TXT` scrambling (ADR 0002 known
   issue; all investigation logs in `artifacts/m1-run*.txt`).
2. Then milestone two: a real kernel proper (identity-map MMU, a UART
   console driver, a hand-off contract from the boot stub) — described in
   the roadmap, not implemented.
