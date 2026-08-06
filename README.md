# DipshitOS

[![CI](https://github.com/drawmeanelephant/DipshitOS/actions/workflows/ci.yml/badge.svg)](https://github.com/drawmeanelephant/DipshitOS/actions/workflows/ci.yml)

A from-scratch AArch64 operating system. Not Linux-based. No libc, no POSIX,
no existing guest OS. Guest code is written in Zig; the host launcher is
Swift. See `AGENTS.md` for the project rules.

**Status: milestone two implemented; build gates pass; the VZ serial and
bad-handoff failure gates are unpassed — the canonical, always-current status
is [`docs/status.md`](docs/status.md).**

Milestone two adds the kernel proper: the stub allocates handoff contract v2,
the kernel captures the EFI map, calls `ExitBootServices` with the required
retry bound, installs identity-map TTBR0_EL1 tables, probes declared MMIO
windows, and drives a polled serial console before entering a terminal WFE
loop. Design: `docs/m2-kernel-proper-design.md` and ADR 0004.

The milestone-one `KERNEL.TXT` corruption (kernel writes landing as
shifted slices of the kernel image's `.rodata` on Apple VZ firmware) is
**fixed**: the loader now places the image content at `base+0` (ADR
0002), and `\KERNEL.TXT` is byte-perfect and gated by `zig build run`
alongside `\BOOTED.TXT`, `\LOADER.TXT`, and `\RC.TXT`.

**Next target: milestone 1.5, the interactive kernel monitor** — a live
command monitor (`dipshit>` prompt) served by the kernel's polled serial
console (the milestone-two terminal loop becomes its payload): identity
commands, memory-map inspection, shell utilities, and machine controls.
The goal, twenty-step plan, hard gates, and per-step progress live in
**`docs/status.md`** (the living status & goals tracker).

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

`kernel/src/main.zig` is the milestone-two freestanding kernel proper. It
validates handoff v2, captures the map, exits Boot Services, builds and
installs identity TTBR0_EL1 tables, probes PL011/16550/virtio-MMIO candidates,
prints the exact takeover banner and hexadecimal map view, and then never
returns. Its fixed page tables and virtio queue storage are BSS carve-outs;
there is no general allocator or libc/POSIX.

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
├── boot/src/main.zig          the AArch64 UEFI boot loader (handoff v2)
├── kernel/                    freestanding AArch64 kernel proper
│   ├── src/main.zig           ExitBootServices, MMU, probe, serial, terminal loop
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
│   ├── context/               project-context generator + review prompt
│   └── ragshit/               local Git-aware context engine (Python, stdlib only)
├── docs/                      status.md (canonical living status & changelog),
│                              architecture, branch protection, hardware contract,
│                              roadmap, testing, decisions (ADRs 0001–0004)
└── artifacts/                 build evidence (gitignored)
```

## Local context engine (`tools/ragshit/`)

`tools/ragshit/` is **ragshit** — a local, Git-aware retrieval engine that
builds a SQLite+FTS5 index of this repository and emits deterministic
context bundles for LLM reviewers. Every source chunk in a bundle is
addressable by path, line range, commit, and score, so agents and
reviewers can cite exactly where a claim came from. Python 3.12+, standard
library only, no network calls, no embeddings yet.

```bash
./tools/ragshit/ragshit index .
./tools/ragshit/ragshit query . "kernel handoff ABI"
./tools/ragshit/ragshit bundle . "review milestone two" --output artifacts/review-context.md
./tools/ragshit/ragshit doctor .
```

`just ragshit <subcommand> <args>` aliases the launcher. See
`tools/ragshit/README.md` for the full command set, ranking formula, and
configuration.

## Verification results (observed on this development host)

The milestone-two VZ takeover and bad-handoff gates are **not passed**: the
saved run has an empty `artifacts/vm-serial.log`, and the bad-handoff run has
no `RC.TXT`. The implementation and build checks below must not be read as
hardware evidence.

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
| Kernel marker `\KERNEL.TXT` | kernel write | **Observed**: byte-perfect and byte-identical across runs (ADR 0002 corruption fixed); `zig build run` gates on its content |

All command output and logs are saved under `artifacts/` (`inspect.txt`,
`vm-serial.log`, `vm-screen-*.png`, `efi-vars.bin`, `context.md`).

### Observed behavior

- `zig build`, `image`, and `inspect` complete on this host; the milestone-two `run` gate is blocked by missing serial evidence.
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
  the firmware's internal behavior is not directly observable). ## Next steps
 
 The gate-by-gate plan and active work claims live in
 [`docs/status.md`](docs/status.md); the milestone plan is in
 [`docs/roadmap.md`](docs/roadmap.md).
 
 1. **Milestone 1.5, the interactive kernel monitor**: the kernel console is
    polled TX-only (ADR 0004, no RX path) and the VM runner's serial
    attachment has no host-to-guest input handle (`fileHandleForReading:
    nil`) — close the RX gap, then build the console abstraction, line
    editor, command registry, and commands. Tracked step-by-step in
    `docs/status.md`.
 2. Resolve the milestone-two VZ serial/MMIO discovery gate: run the complete
    Apple M4 / macOS 27 VZ gate and save output under `artifacts/`. Only
    then may the matching MMIO/MMU assumptions change from `[inferred]` to
    `[observed]` in `docs/hardware-contract.md`.
 3. Keep later interrupt/GIC, timer, allocator, and process work out of
    scope; those remain future milestones.
