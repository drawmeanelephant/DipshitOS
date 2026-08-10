# DipshitOS

[![CI](https://github.com/drawmeanelephant/DipshitOS/actions/workflows/ci.yml/badge.svg)](https://github.com/drawmeanelephant/DipshitOS/actions/workflows/ci.yml)

A from-scratch AArch64 operating system that boots under real UEFI firmware
on **Apple silicon**, hosted by **Apple's Virtualization.framework**
(macOS **27 or newer** — the project's required host). It is **not Linux,
not Unix, and not QEMU-based**: no libc, no
POSIX, no existing guest OS, and no emulator anywhere in the boot path.
Guest code is written in Zig; the host launcher is Swift. See `AGENTS.md`
for the project rules.

**Status at a glance** (canonical, always-current:
[`docs/status.md`](docs/status.md)):

- **Done:** milestone zero (boot pipeline), milestone one (kernel
  handoff).
- **Done (all milestone-two gates pass 2026-08-08):** milestone two
  (kernel proper: `ExitBootServices`, identity-map MMU, polled serial
  console) — the MMU-takeover death is root-caused and **fixed** (claim
  0010); claim 0013 found the real console is a virtio-pci device outside
  the declared MMIO windows; claims 6460/7896 root-caused the post-MMU
  transport hang (translation start-level mismatch + stale-TLB crutch)
  and **claim 1517 fixed it in production** (T0SZ=16 + `tlbi vmalle1` at
  the switch) — the VZ serial gate now passes (banner + memory-map +
  terminal state in `vm-serial.log`). The bad-handoff, marker-fallback,
  and NVRAM-console gates pass. Current VZ gate state: see
  [`docs/status.md`](docs/status.md).
- **Done 2026-08-09 (all 7 M1.5 hard gates pass; tagged
  `m1.5-interactive-monitor`):** milestone 1.5 — the interactive `dipshit>`
  kernel monitor (live shell, RX, reboot/shutdown, ESP file window).
- The milestone-one `KERNEL.TXT` corruption is fixed (ADR 0002).

Milestone two adds the kernel proper: the stub allocates handoff contract v2,
the kernel captures the EFI map, calls `ExitBootServices` with the required
retry bound, installs identity-map TTBR0_EL1 tables, probes declared MMIO
windows, and drives a polled serial console before entering a terminal WFE
loop. Design: `docs/archive/m2-kernel-proper-design.md` and ADR 0004.

The milestone-one `KERNEL.TXT` corruption (kernel writes landing as
shifted slices of the kernel image's `.rodata` on Apple VZ firmware) is
**fixed**: the loader now places the image content at `base+0` (ADR
0002), and `\KERNEL.TXT` is byte-perfect and gated by `zig build run`
alongside `\BOOTED.TXT`, `\LOADER.TXT`, and `\RC.TXT`.

**Milestone 1.5, the interactive kernel monitor, is done (2026-08-09).**
A live command monitor (`dipshit>` prompt) served by the kernel's polled
serial console: identity commands, memory-map inspection, shell utilities,
machine controls, and an ESP file window. The host plumbing (duplex
serial, terminal handling, `zig build console`), console & shell core (RX
abstraction, line editor, tokenizer, prompt loop), and command registry
(30 commands, mock-tested) are built; the transcript test gate passes
(`zig build test-console`, byte-identical fixture). The **VZ serial gate
passes** (claim 1517 — post-MMU virtio TX fixed with T0SZ=16 + `tlbi
vmalle1` at the switch), **live RX** delivers host keystrokes end to end
(claim 6684 — `verify-live-transcript.sh` asserts the live transcript),
**live reboot/shutdown** is observed (claim 0527 — `verify-live-reboot.sh`:
`reboot` resets the machine, `shutdown` powers it off), and **`ls`/`cat`/
`write` persist through reboot on the disk itself** via a real FAT32
storage driver (claim 6420 — `verify-live-fs.sh`; `fat.zig` over a
virtio-blk transport, replacing claim 3475's pre-exit snapshot + NVRAM
persistence). **All 7 hard gates pass; the milestone is tagged
`m1.5-interactive-monitor`.** Canonical
state: [`docs/status.md`](docs/status.md).
The goal, hard gates, and per-step progress live in
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
and prints the takeover banner and enters a terminal WFE loop (**observed
on VZ since claim 1517** — post-MMU virtio TX fixed with T0SZ=16 + TLBI
at the switch; see `docs/status.md`). Its fixed page tables and virtio queue storage are BSS
carve-outs; there is no general allocator or libc/POSIX. Milestone 1.5 adds
the interactive monitor (`kernel/src/{console,lineedit,tokenizer,shell,monitor}.zig`).

## Toolchain

Pinned in `.zigversion`: **Zig 0.16.0**. The build system is written against
that release (see `docs/decisions/0001-arm64-uefi-zig.md` for the API
adjustments). Other tools used at build/run time: Swift (macOS 27+, Apple silicon, for the Virtualization path), Python 3
(disk image tooling), `bash`. The project targets Apple silicon / macOS 27+ /
Virtualization.framework only — there is no QEMU path.

## Quickstart

```bash
zig build          # compile the AArch64 UEFI application -> zig-out/bin/BOOTAA64.EFI
zig build image    # build the GPT+FAT32 boot image -> artifacts/disk.img
zig build run      # boot it with Swift + Virtualization.framework (Apple silicon)
zig build console  # boot an interactive dipshit> console (Apple silicon)
zig build test-console  # M1.5 transcript test (mock console, no VM)
zig build marker    # boot and save the NVRAM marker ladder (ADR 0004 D4)
zig build nvram-console  # boot and reconstruct the NVRAM fallback console stream (claim 0015)
zig build inspect  # inspect the EFI binary and the disk image
zig build context  # regenerate artifacts/context.md (deterministic project snapshot)
```

`just` aliases exist for the same commands (`just build`, `just image`, ...).

## Repository layout

```
dipshitos/
├── AGENTS.md                  project rules (read this first)
├── LICENSE                    proprietary source-available license
├── README.md
├── build.zig / build.zig.zon  root build system (Zig 0.16)
├── justfile                   command aliases
├── .zigversion                pinned Zig version (0.16.0)
├── boot/src/main.zig          the AArch64 UEFI boot loader (handoff v2)
├── kernel/                    freestanding AArch64 kernel proper + M1.5 shell
│   ├── src/main.zig           kernel entry: handoff, capture map, EBS, probe, shell seam
│   ├── src/mmio.zig           volatile MMIO accessors (shared by all drivers)
│   ├── src/mmu.zig            identity-map TTBR0_EL1 tables + install (ADR 0006)
│   ├── src/pci.zig            PCI ECAM config-space + bus-0 discovery + ACPI/MCFG walk
│   ├── src/evidence.zig       NVRAM marker ladder + probe dumps (post-exit evidence)
│   ├── src/virtio_console.zig virtio-pci console transport (TX; RX is a stub)
│   ├── src/nvram_console.zig  NVRAM fallback console channel (claim 0015)
│   ├── src/machine.zig        machine controls (ResetSystem, claim 0011)
│   ├── src/console.zig        Console abstraction + mock (write/flush/readByte)
│   ├── src/memmap.zig         Dense-stride EFI memory-map view
│   ├── src/handoff.zig        Handoff v2 struct validation
│   ├── src/lineedit.zig       Fixed-buffer line editor (no allocator)
│   ├── src/tokenizer.zig      Command-line tokenizer (no allocator)
│   ├── src/monitor.zig        Comptime command registry (30 commands)
│   ├── src/shell.zig          Prompt loop: banner → lineedit → tokenize → exec
│   ├── src/esp.zig            ESP file window over the live FAT32 volume (ls/cat/write)
│   ├── src/fat.zig            GPT + FAT32 mount/list/read/write (injected sector I/O)
│   ├── src/virtio_blk.zig     virtio-blk transport (DID 0x1042 on VZ, post-exit re-arm)
│   ├── src/virtio_entropy.zig virtio entropy transport (DID 0x1044, post-exit re-arm; claim 2665)
│   ├── src/csprng.zig         ChaCha20 CSPRNG (RFC 7539, KAT-pinned; claim 2665)
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
│   ├── status/                coordination index generator (refresh-indexes.sh)
│   ├── verify-*.sh            gate scripts (marker, bad-handoff, console, …)
│   └── ragshit/               local Git-aware context engine (Python, stdlib only)
├── docs/                      status.md (canonical living status & coordination
│                              hub), claims/ (per-claim files), logs/ (per-branch
│                              append-only changelogs), architecture, branch
│                              protection, hardware contract, roadmap, testing,
│                              decisions (ADRs 0001–0006)
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

The milestone-two VZ takeover gate **passes (2026-08-08, claim 1517)**:
`zig build run` puts the banner, memory-map print, and `kernel terminal
state` in `artifacts/vm-serial.log` (post-MMU virtio TX fixed — T0SZ=16 +
TLBI at the switch). The bad-handoff failure gate **is passed**
(as of 2026-08-06: `RC.TXT` → `kernel_rc=0x2`, root cause was the naked
`_start` shim clobbering the link register). The **ADR 0004 D4 marker
fallback gate is passed** (2026-08-07): the kernel persists each takeover
stage as the EFI variable `DipshitM2`, and the MMU-takeover death it first
discriminated (`M2_MAPD!` ladder end, claim 0009) is **root-caused and
fixed** (claim 0010) — the ladder now runs `M2_MAPD! → M2_MMUP! →
M2_SERIA`, the switch completes, and the declared-window probe runs to
completion without a hit (claim 0013 later decoded those windows as Apple's
efivars store + an internal debug UART, and found the real console is a
virtio-pci device outside them). The post-MMU transport hang was
root-caused (claims 6460/7896) and fixed in production (claim 1517:
T0SZ=16 + TLBI at the switch) — the VZ serial gate passes. Current gate
state: [`docs/status.md`](docs/status.md). The implementation and build
checks below must not be read as hardware evidence.

Host: Apple M4, macOS 27.0 (arm64), Zig 0.16.0, Swift 6.2.3 (arm64).

| Step | Command | Result |
|------|---------|--------|
| Build EFI app | `zig build` | **Observed**: `zig-out/bin/BOOTAA64.EFI` — `PE32+ executable (EFI application) Aarch64` |
| Inspect binary | `zig build inspect` | **Observed**: `file format coff-arm64`, subsystem `0x0a (EFI application)`, `.text/.data/.pdata/.reloc` sections, real AArch64 disassembly |
| Build image | `zig build image` | **Observed**: 64 MiB GPT+FAT32 image; `EFI/BOOT/BOOTAA64.EFI` (139264 B) present; volume label `DIPSHITOS` |
| Inspect image | `zig build inspect` | **Observed**: `DOS/MBR boot sector` (protective), GPT header crc valid, ESP `LBA 2048..131038` |
| Build Swift runner | `swift build --package-path host/vm-runner` | **Observed**: SwiftPM build succeeds |
| Boot via Virtualization.framework | `zig build run` | **Observed (2026-08-08, claim 1517)**: VM boots; loader writes `\BOOTED.TXT` + `\LOADER.TXT` byte-perfect; **M2 serial gate PASSES** — banner + `memory-map descriptors=0x…` + `kernel terminal state` in `vm-serial.log` (post-MMU virtio TX fixed: T0SZ=16 + TLBI at the switch) |
| Kernel image | `zig build` + `elf2bin.py` | **Observed**: `KERNEL.BIN` (format v1: magic `DSK1`, `entry_offset=0x18`, ~2 KiB) |
| Kernel marker `\KERNEL.TXT` | M1 regression only | **Observed**: byte-perfect and byte-identical across runs (ADR 0002 corruption fixed); not written post-`ExitBootServices` |
| Marker fallback gate | `bash tools/verify-marker.sh` | **Observed** (2026-08-07): NVRAM ladder `M2_ENTRY → M2_CMAP! → M2_PREX! → M2_EXIT! → M2_MAPD!` (claim 0009); **fixed 2026-08-07 (claim 0010)**: ladder now reaches `M2_MMUP! → M2_SERIA → M2_READY` — MMU takeover completes; declared-window probe finds no device (windows later decoded as efivars store + debug UART, claim 0013) (`artifacts/m2-mmu-takeover-gate.txt`) |
| NVRAM console gate | `bash tools/verify-nvram-console.sh` | **Observed** (2026-08-07): **first post-exit console bytes from a real VZ run** — 69–70 chunks reconstructed from `efi-vars.bin` (takeover banner, memory map, probe record, shell banner, real `version`/`mem`/`echo`/`help` output); found + fixed the ADR 0005 flat-loader relocation bug (claim 0015, `artifacts/nvram-console-gate.txt`) |
| Host console gate | `bash tools/verify-host-console.sh` | **Observed** (2026-08-06/07): stdin-backed serial attachment, live tee to terminal + log, termios restore (claim 0003, `artifacts/m15-host-console-gate.txt`) |
| Bad-handoff failure gate | `bash tools/verify-bad-handoff.sh` | **Observed** (2026-08-06): `RC.TXT` → `kernel_rc=0x2`; gate passes (shim LR clobber fixed) |

All command output and logs are saved under `artifacts/` (`inspect.txt`,
`vm-serial.log`, `vm-screen-*.png`, `efi-vars.bin`, `context.md`).

### Observed behavior

- `zig build`, `image`, and `inspect` complete on this host. The
  milestone-two `run` gate **passes** (claim 1517, 2026-08-08 — post-MMU
  virtio TX fixed with T0SZ=16 + `tlbi vmalle1` at the switch), and the
  gates around it pass: `bash tools/verify-bad-handoff.sh` (failure path,
  `kernel_rc=0x2`), `bash tools/verify-marker.sh` (NVRAM marker ladder),
  `zig build test-console` (M1.5 transcript gate, mock console),
  `bash tools/verify-host-console.sh` (M1.5 host plumbing), and
  `bash tools/verify-nvram-console.sh` (M1.5 NVRAM fallback console), and
  `bash tools/verify-live-transcript.sh` (M1.5 live RX — host keystrokes
  reach the kernel end to end, claim 6684), and
  `bash tools/verify-live-reboot.sh` (M1.5 live reboot/shutdown — a real
  EFI `ResetSystem` from a live `dipshit>` shell: `reboot` resets the
  machine, `shutdown` powers it off, claim 0527). The M1.5 monitor (14
  commands) is implemented, host-tested, and gate-complete (see
  `docs/status.md`). Milestone-four card 1 (2026-08-10, claim 2665) adds a
  REAL randomness source: `bash tools/verify-live-entropy.sh` boots the VM
  twice and proves the virtio entropy device (DID 0x1044) seeds the
  ChaCha20 CSPRNG (`entropy: seeded n=64`), `random 32` emits 64 hex
  chars, and two boots produce DIFFERENT sequences and exec stack   placements (the exec-path ASLR consumer). Milestone-four card 2
   (2026-08-10, claim 3678) generalizes the FAT32 driver into a general
   (non-ESP) filesystem — the disk image carries a second FAT32 DATA
   partition (36 MiB, Linux-FS type GUID) mounted by the new `mount
   <esp|data>` command, directories and `/`-paths are reachable (`ls
   [<dir>]`, `cat <file|path>`), and `bash tools/verify-live-gfs.sh`
   proves the DATA volume persists a written file across a real reboot on
   the disk itself. Milestone-four card 3 (2026-08-10, claim 3848) adds
   the **process abstraction**: a bounded registry (`kernel/src/
   process.zig`) where each Process owns the loaded image, the address
   space, the lifecycle, and the exit status (which now survives the
   executor task's reap); exec and the boot-time static EL0 payload are
   real processes, and `bash tools/verify-live-procs.sh` proves it live —
   `procs` shows the exec'd USER.BIN running with its stack and the boot
   payload exited (status 7 kept past the reap), plus the process exit
   report `procs USER.BIN exited status=43`. The milestone-four follow-on
   (claim 0826) relaxes the last single-program constraint: every process
   owns its own TTBR0 root + allocator-backed text/stack/EL1-stack pages,
   so `exec USER.BIN` runs twice with BOTH programs live at once
   (`tools/verify-live-concurrent.sh` — two `state=running` rows with
   distinct task ids + stack VAs). The follow-on 2 (claim 4613) proves
   the machinery against DISTINCT programs and a permanent occupant: a
   second image COUNTER.BIN (`user/src/counter.zig`) never exits — it
   loops writing its own `counter: alive` marker (sys_write + sys_yield
   only, no sys_exit) while USER.BIN is exec'd, runs, exits, is reaped
   (its pages return to the allocator), and is re-exec'd into the freed
   slot, and a further exec with both live hits the capacity gate
   (`pool_full`) — `tools/verify-live-long-lived.sh`, which drives the
   re-exec via the runner's new `--script2`/`--script2-after` second
   scripted phase after the first reap. The follow-on 3 card 3c (claim
   7786) proves the OS, not the program, owns process lifetime: the
   `kill <pid|name>` monitor command force-terminates a never-exiting
   program with the reserved status 137 — no `counter: alive` marker
   lands after the kill line, the pages return at the reap (exact +5
   free-count recovery), and a re-exec lands in the freed slot
   (`tools/verify-live-kill.sh`, with the runner's `--script3` third
   phase for the post-reap snapshot).
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

## Next steps

The gate-by-gate plan and active work claims live in
[`docs/status.md`](docs/status.md); the milestone plan is in
[`docs/roadmap.md`](docs/roadmap.md).

1. ~~**Close the M1.5 serial gap: post-MMU console transport + RX.**~~
   **DONE 2026-08-09 — milestone 1.5 closed (tag
   `m1.5-interactive-monitor`).** The monitor itself is implemented and
   host-tested (console abstraction, line editor, tokenizer, 20 commands,
   `zig build test-console` transcript gate at the mock level; the
   host-side `--console` plumbing is gated by `bash tools/verify-host-console.sh`).
   The console device is found (a virtio-pci console, claim 0013), the
   NVRAM channel carries post-exit console bytes (claim 0015), the
   post-MMU transport layer is **fixed** (claim 1517: T0SZ=16 + TLBI at
   the switch), **live RX is wired** (claim 6684: the polled virtio
   receive queue delivers host keystrokes end to end —
   `verify-live-transcript.sh` asserts the live `dipshit>` transcript in
   `vm-serial.log`), the **live reboot/shutdown observation** is done
   (claim 0527 — `reboot` resets the machine, `shutdown` powers it off,
   4/4 boots via `verify-live-reboot.sh`), and the **filesystem gate is
   closed** (claim 3475 — `ls`/`cat`/`write` persist through reboot via
   the pre-exit ESP snapshot + NVRAM-persisted writes,
   `verify-live-fs.sh` — **upgraded the same day to a real FAT32 storage
   driver, claim 6420**, so files persist on the disk itself). **All 7
   M1.5 hard gates pass; milestone tagged.**
   Tracked step-by-step in `docs/status.md` / `docs/march-m3.md` (M1.5's
   tracker is archived at `docs/archive/march-m15.md`).
2. ~~Resolve the milestone-two VZ serial gate itself.~~ **DONE 2026-08-08
   (claim 1517):** the post-MMU transport blocker (start-level mismatch +
   stale-TLB crutch, claims 6460/7896) is fixed in production (T0SZ=16 +
   `tlbi vmalle1` at the switch); `zig build run` passes with evidence
   saved under `artifacts/`, and the matching MMIO/serial assumptions are
   flipped in `docs/hardware-contract.md`. (The bad-handoff failure gate
   — formerly the other unpassed gate — is closed since 2026-08-06.)
3. **Milestone three is active; tasks, EL0/SVC, and the syscall ABI are
   complete, and so is the fault-safe uaccess layer.** The physical
   allocator is done (claims 3972/5162), exception vectors are live (claim
   9746), a real periodic CNTP PPI reaches the guest's EL1 IRQ vector on VZ
   (claim 9187; strict `irq=5 poll=0` gate passes 3/3), round-robin kernel
   tasks are done (claim 5275), the EL0/SVC boundary (claim 8215) and the
   frozen syscall ABI (claim 3594) pass their live gates, and fault-safe
   uaccess (claim 6120), per-task user address spaces (claim 5804), the
   user task lifecycle (claim 6729 — explicit states, bounded spawn,
   exit→zombie, idle-task reaper, plus the callee-saved vector-frame fix
   that made preemption of compiled tasks safe), and **loading and execing
   a real user program from the ESP (claim 6783 — `exec USER.BIN` reads a
   DSK1 flat image through the FAT path, rebuilds the EL0 user root around
   its page, and the loaded program runs at EL0, writes via sys_write,
   round-trips pings, and exits through the lifecycle) are done.**
   **Blocking syscalls (sleep/yield/wakeup) is the next milestone-three
   card.** Canonical ordering and evidence live in `docs/status.md`.
4. Keep later task/process work and graphics/networking/SMP out of scope;
   those remain future roadmap cards.
