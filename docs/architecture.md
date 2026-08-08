# DipshitOS architecture

**Host identity:** this project is Apple silicon only — the guest runs
under Apple's Virtualization.framework UEFI firmware on macOS. It is **not
Linux, not Unix, and not QEMU**: no emulator, no libc/POSIX, no existing
guest OS in the boot path. (Canonical, always-current status:
[`docs/status.md`](status.md).)

## Current state

Milestones zero and one are verified end to end (boot pipeline proof;
separate freestanding kernel image with a versioned handoff — see
`docs/decisions/0002-kernel-handoff.md`). Milestone two (the kernel proper,
ADR 0004) is implemented: the stub allocates handoff v2, the kernel calls
`ExitBootServices`, installs identity-map TTBR0_EL1 tables, probes declared
MMIO windows, and drives a polled serial console before a terminal WFE loop.
Its VZ serial gate is **not passed**, but the gates around it are: the
bad-handoff failure gate passes since 2026-08-06 (root cause: the naked
`_start` shim clobbered the link register, so a pre-exit failure never
returned to the loader), the ADR 0004 D4 marker-fallback gate passes, and
the MMU-takeover death the marker ladder exposed (claim 0009) was
root-caused and fixed (claim 0010, 2026-08-07) — the identity-map switch
now completes on VZ; claim 0013 found the real console (a virtio-pci
device outside the declared windows) and the VZ serial gate's remaining
blocker is post-MMU access to its transport (claims 0018/0020), not a
crash. Milestone 1.5
adds the interactive monitor on top of this kernel:
console abstraction, line editor, tokenizer, a 14-command registry
(`kernel/src/{console,lineedit,tokenizer,shell,monitor,handoff,memmap}.zig`),
host-tested with a mock console and a byte-exact transcript gate; its live
serial channel is still blocked on post-MMU console transport access / RX.
The canonical, always-current status lives in
[`docs/status.md`](status.md); this file documents the architecture that
status refers to. The project targets Apple silicon /
Virtualization.framework only; there is no QEMU path.

## Components

| Component | Where | Role |
|-----------|-------|------|
| Guest boot loader | `boot/src/main.zig` | AArch64 UEFI application; prints via Simple Text Output, loads `\KERNEL.BIN` from the ESP, jumps to the kernel entry, writes host-readable evidence (`\BOOTED.TXT`, `\LOADER.TXT`, `\RC.TXT`) |
| Guest kernel | `kernel/src/*.zig` | Freestanding kernel proper: `ExitBootServices`, identity-map MMU, polled serial console; M1.5 adds the interactive monitor (console, lineedit, tokenizer, shell, monitor modules) |
| Boot medium | `image/mkfat32.py` + `image/make-image.sh` | GPT disk with a FAT32 EFI System Partition containing `EFI/BOOT/BOOTAA64.EFI` |
| macOS host launcher | `host/vm-runner/` (Swift + Virtualization.framework) | Boots the image under UEFI on Apple silicon, captures the guest serial console and framebuffer |
| Build system | `build.zig`, `build.zig.zon`, `justfile` | Compile, kernel, image, run, inspect, context |
| Evidence tooling | `tools/inspect.sh`, `tools/context/`, `tools/status/`, `tools/verify-*.sh` | Binary/image inspection, deterministic project snapshot, coordination indexes and gate scripts |

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
             │  post-exit evidence channel: NVRAM ladder (EFI var DipshitM2) ──▶ artifacts/efi-vars.bin  [observed: reaches M2_MMUP! → M2_SERIA]
             └── serial probe ──▶ declared windows decoded (efivars store + debug UART, claim 0013); real console = virtio-pci @ BAR 0x100010000 ──▶ post-MMU transport access hangs ──▶ vm-serial.log empty
             └── M1.5 monitor loop (console/lineedit/tokenizer/shell) ──▶ exists, host-tested via MockConsole; parks in WFE on the real kernel (RX not wired — readByte is a no-RX stub)
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
  and one; the  firmware reads `EFI/BOOT/BOOTAA64.EFI` from it, and the boot stub writes
  pre-exit evidence files through the UEFI Simple File System protocol. The
  kernel proper never uses storage after `ExitBootServices`.

- **Guest → host console:** a virtio console serial port. Observed on Apple
  silicon: the VZ firmware does not route `ConOut` there (empty log) and
  renders no text to the virtio-gpu framebuffer (blank captures).
  Milestone two drives the console via MMIO (the polled console driver,
  ADR 0004 D4). The declared windows are not the console — claim 0013
  decoded them as Apple's efivars store + an internal debug UART and
  found the real console is a modern virtio-pci device (BAR
  `0x100010000`) whose post-MMU transport access hangs on VZ (claims
  0018/0020), so no console is driven on VZ yet and the register layout
  stays `[inferred]` (see `docs/hardware-contract.md`). The M1.5 monitor
  therefore runs against a mock console in tests; the live channel awaits
  reliable post-MMU console transport access + RX.
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
