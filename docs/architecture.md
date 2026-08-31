# VirelaiOS architecture

**Host identity:** this project is Apple silicon running macOS 27 or newer
only — the guest runs under Apple's Virtualization.framework UEFI firmware
on macOS. It is **not Linux, not Unix, and not QEMU**: no emulator, no
libc/POSIX, no existing guest OS in the boot path. (Canonical, always-current
status:
[`docs/status.md`](status.md).)

## Current state

Milestones zero and one are verified end to end (boot pipeline proof;
separate freestanding kernel image with a versioned handoff — see
`docs/decisions/0002-kernel-handoff.md`). Milestone two (the kernel proper,
ADR 0004) is implemented: the stub allocates handoff v2, the kernel calls
`ExitBootServices`, installs identity-map TTBR0_EL1 tables, probes declared
MMIO windows, and drives a polled serial console before a terminal WFE loop.
Its VZ serial gate **passes since 2026-08-08** (claim 1517): the
bad-handoff failure gate passes since 2026-08-06 (root cause: the naked
`_start` shim clobbered the link register, so a pre-exit failure never
returned to the loader), the ADR 0004 D4 marker-fallback gate passes, the
MMU-takeover death the marker ladder exposed (claim 0009) was root-caused
and fixed (claim 0010, 2026-08-07), claim 0013 found the real console (a
virtio-pci device outside the declared windows), and claims 6460/7896
root-caused the post-MMU transport hang (translation start-level mismatch
+ stale-TLB crutch) which claim 1517 fixed in production (T0SZ=16 +
`tlbi vmalle1` at the switch) — `zig build run` puts the banner +
memory-map + terminal state in `vm-serial.log`. **Milestone 1.5
(implemented 2026-08-09) adds the interactive monitor on top of this
kernel:** console abstraction, line editor, tokenizer, a 20-command
registry (`kernel/src/{console,lineedit,tokenizer,shell,monitor,handoff,memmap,esp}.zig`),
host-tested with a mock console and a byte-exact transcript gate; its live
serial channel is up for TX (claim 1517) and **RX** (claim 6684: the
polled virtio receive queue delivers host keystrokes end to end, asserted
in `vm-serial.log` by `verify-live-transcript.sh`), **live
reboot/shutdown** is observed (claim 0527), and **a real FAT32 storage
driver** (claim 6420: `kernel/src/fat.zig` over the virtio-blk transport
`kernel/src/virtio_blk.zig`) gives `ls`/`cat`/`write` with persistence
through reboot **on the disk itself** — replacing claim 3475's pre-exit
EFI Simple File System snapshot + NVRAM-persisted writes. All
7 M1.5 hard gates pass; milestone tagged `m1.5-interactive-monitor`.
The canonical, always-current status lives in
[`docs/status.md`](status.md); this file documents the architecture that
status refers to. The project targets Apple silicon /
Virtualization.framework only; there is no QEMU path.

## Components

| Component | Where | Role |
|-----------|-------|------|
| Guest boot loader | `boot/src/main.zig` | AArch64 UEFI application; prints via Simple Text Output, loads `\KERNEL.BIN` from the ESP, jumps to the kernel entry, writes host-readable evidence (`\BOOTED.TXT`, `\LOADER.TXT`, `\RC.TXT`) |
| Guest kernel | `kernel/src/*.zig` | Freestanding kernel proper: `ExitBootServices`, identity-map MMU (mmu.zig, ADR 0006), PCI/ACPI discovery (pci.zig), virtio-pci console transport (virtio_console.zig), NVRAM evidence + fallback console (evidence.zig / nvram_console.zig), machine controls (machine.zig); M1.5 adds the interactive monitor (console, lineedit, tokenizer, shell, monitor modules) |
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
             │  post-exit evidence channel: NVRAM ladder (EFI var VirelaiM2) ──▶ artifacts/efi-vars.bin  [observed: ladder reaches M2_READY; NVRAM console channel (claim 0015) carries post-exit console bytes — shell + commands observed]
             └── serial probe ──▶ declared windows decoded (efivars store + debug UART, claim 0013); real console = virtio-pci @ BAR 0x100010000 ──▶ post-MMU TX fixed (claim 1517: T0SZ=16 + TLBI at the switch) ──▶ vm-serial.log has banner + memory-map + terminal state
             └── M1.5 monitor loop (console/lineedit/tokenizer/shell) ──▶ live on VZ: TX post-MMU (claim 1517) + RX via the polled virtio receive queue (claim 6684) — host keystrokes reach the virelai> shell
```

## Interfaces

- **Guest ↔ firmware:** the UEFI System Table only, and only until
  milestone two's `ExitBootServices`. Milestone zero calls
  `SimpleTextOutput.OutputString` (`ConOut`) and then returns, which is the
  UEFI-defined way to give control back to firmware. In milestone two the
  kernel calls `ExitBootServices` itself (per ADR 0004) and no UEFI
  protocol is usable afterwards.
- **Guest ↔ host network (milestone five, card N1 — claim 1373):** under
  the runner's flag-gated `--net <capture-file>` mode the VM gains a
  virtio-net device (`VZVirtioNetworkDeviceConfiguration` +
  `VZFileHandleNetworkDeviceAttachment`, fixed host MAC). The guest's
  `kernel/src/virtio_net.zig` (injectable transport ops — the fat.zig
  pattern) discovers the modern virtio-net device (DID 0x1041) pre-exit,
  negotiates features (the device needs `VIRTIO_NET_F_MTU` accepted),
  reads the host-set MAC via the feature path, arms queue 0 (RX) +
  queue 1 (TX), re-arms post-exit (the net device does not reset at
  ExitBootServices — observed st=0f), and `netsend` drives TX end to end:
  a zeroed 12-byte virtio_net_hdr (the device consumes one on every TX
  buffer — observed) + the raw Ethernet frame, built in fixed BSS staging
  (no heap), submitted on queue 1, and drained from the used ring polled;
  the host capture holds the exact frames byte-for-byte (gate
  `tools/verify-live-net-tx.sh` PASS 2/2). **RX landed 2026-08-11 (claim
  6076, card N2):** the runner's `--net-inject <file>` writes the
  attachment's socket end ONCE on the guest's rx-armed serial trigger;
  queue 0 is supplied with one fixed BSS buffer, the used ring is drained
  POLLED (the N1/blk shape — the net device's used-buffer IRQ is not yet
  observed), each delivered buffer is MAC-filtered (own + broadcast,
  drop the rest) and pushed into a bounded 4-slot frame FIFO (pure BSS,
  drop-oldest, drained by the shell idle loop and the `net recv`
  subcommand — the card-3d pattern); `net recv` prints the received
  frame(s) byte-exact with the observed 12-byte virtio_net_hdr headroom
  (the RX-header question answered at claim time: the device writes a
  virtio_net_hdr — `num_buffers=1` — before every raw frame; the device
  also REFUSES an RX buffer under 1530 bytes). Gate
  `tools/verify-live-net-rx.sh` PASS 3/3 (broadcast round trip,
  own-MAC, foreign-MAC drop). **ARP landed 2026-08-11 (claim 7293, card
  N3):** a pure protocol layer `kernel/src/arp.zig` (RFC 826 — static IP
  via `net ip <a.b.c.d>`, byte-exact request/reply builds, a bounded
  4-slot BSS table, counters) wired into the RX drain: a request whose
  target protocol address equals our static IP is answered (the 42-byte
  reply built in `tx_staging` with the zeroed virtio_net_hdr prefix and
  transmitted on the N1 one-request-at-a-time TX path), a reply is
  learned into the table, everything else dropped with a counter; `net
  ip`/`net arp [<ip>]` are `net` subcommands (registry stays 34) and the
  runner's `--net-arp-respond <host-ip>` answers the guest's ARP
  requests from the host side (deterministic, request-driven, OFF by
  default). Gate `tools/verify-live-net-arp.sh` PASS 3/3 (answer for
  our address, resolve a peer, foreign-address scope check); the
  42-byte frames are delivered/transmitted unpadded (observed). **IPv4
  landed 2026-08-11 (claim 0148, card N4):** a pure protocol layer
  `kernel/src/ipv4.zig` (RFC 791/792 — RFC 1071 one's-complement
  checksums, byte-exact ICMP echo request/reply builders, fragments
  dropped COUNTED — no reassembly, honest bound) wired into the RX
  drain BESIDE the ARP dispatch: an echo request whose destination
  equals our static IP (the ONE copy stays `arp.own_ip`) is answered
  byte-exact (the reply built in `tx_staging` with the zeroed header
  prefix on the N1 TX path), an echo reply is observed
  (`pongs_observed` + the echoed sequence), everything else dropped
  with a counter; `net ping <a.b.c.d>` is a `net` subcommand (an echo
  needs a unicast dst — the peer must be in the ARP table first,
  refused honestly otherwise; `SendResult` gains `.no_peer`) and the
  runner's `--net-icmp-respond <host-ip>` answers the guest's echo
  requests from the host side (id/seq/payload echoed byte-exact, both
  checksums recomputed; deterministic, request-driven, OFF by
  default). Gate `tools/verify-live-net-icmp.sh` PASS 3/3 (answer an
  echo for our address, ping a resolved peer, foreign-address scope
  check); the 46-byte frames are delivered/transmitted unpadded,
  consistent with the N3 observation. **UDP landed 2026-08-11 (claim
  8552, card N5):** a pure protocol layer `kernel/src/udp.zig` (RFC 768
  — the 8-byte header, the checksum over the IPv4 PSEUDO-HEADER (src/dst
  IP, zero, protocol 17, UDP length) computed ALWAYS, a bounded 4-slot
  LISTEN table, bounded per-listener datagram rings (drop-oldest), and
  LOOPBACK — a send to OUR OWN IP builds the datagram with src == dst ==
  own_ip and delivers DIRECTLY into the local receive path, no device
  round trip) wired into ipv4.zig's protocol dispatch: protocol 17 is
  handed to `udp.handle_rx` on ALREADY-VALIDATED frames (the IPv4
  checksum/fragment/dst checks stay in ipv4, never duplicated; TCP and
  other protocols still count `dropped_proto`). `net udp
  [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]`
  are `net` subcommands (fixed src port 7000, the deterministic payload
  01 02 03 04…, honest refusals — `.no_peer` on an unresolved MAC, `net
  arp <ip>` first) and the runner's `--net-udp-respond
  <host-ip>:<host-port>` answers the guest's datagrams from the host
  side (same payload byte-exact, both checksums recomputed;
  deterministic, request-driven, OFF by default). Gate
  `tools/verify-live-net-udp.sh` PASS 4/4 (loopback with an empty
  capture, host→guest delivery, guest→host round trip, closed-port
  drop); the 46-byte datagrams travel unpadded, consistent with the
  N3/N4 observation. Claim-time fix recorded: the pseudo-header's
  zero/protocol word was initially reversed (0x1100 vs 0x0011) — the
  byte-exact fixtures caught it, fixed, re-run green.
- **The UDP syscall seam landed 2026-08-12 (claim 1384, card N6):**
  the ADR 0007 amendment slots 9/10/11 — `sys_udp_listen(port)`
  (`handle_udp_listen`: binds the SAME bounded kernel table the
  monitor's `net udp listen` uses — kernel-global, no per-process
  ownership, the honest bound), `sys_udp_send(ip, port, buf, len)`
  (`handle_udp_send`: ONE datagram from the fixed src port 7000,
  network-byte-order IP extracted byte-explicitly, uaccess staging
  into fixed BSS, own-IP → the N5 LOOPBACK path, a peer → the
  ARP-resolved TX path with `.no_peer`/`.not_ready`/`.timeout` →
  `EINVAL` — the seam does NOT resolve ARP, the caller resolves via
  `net arp` and retries, bounded), and `sys_udp_recv(port, buf, max)`
  (`handle_udp_recv`: the oldest datagram copied OUT through uaccess —
  PEEK → copy_out → pop, so a bad recv buffer (`EFAULT`) never loses
  the datagram (the claim-5965 contract); the device is DRAINED FIRST
  (`virtio_net.net_rx_drain`, the claim-6076 polled-drain contract) so
  an EL0 polling loop is self-sufficient without the shell idle loop —
  observed live: without the drain the answer sat in the device queue
  until a `net` command drained it). `implemented_count` 9 → 12.
  UDP.BIN (`user/src/udp.zig` — the first network-syscall user
  program, naked-asm EL0) drives the whole surface: `sys_udp_listen(7000)`,
  the LOOPBACK send+recv to its own IP (the 12-byte datagram
  byte-exact), the peer send to 10.0.0.2:9999 + poll `sys_udp_recv`
  for the host's `--net-udp-respond` answer (`udp: got ping` — the
  cooperative `sys_yield` between polls), the `EINVAL` mapping from
  EL0 (unbound-port recv + unresolved-peer send), and `sys_exit(17)`.
  Gate `tools/verify-live-net-udp-syscall.sh` PASS 4/4. One
  schedule-truth this gate first proves live: a user task RESUMES
  after `sys_yield` (the ring returns to it; no earlier gate observed
  the boot payload's post-yield resume because it yields as its LAST
  act before exiting).
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
  `0x100010000`). Post-MMU transport access hung on VZ (claims
  0018/0020) until claim 1517 fixed it in production (T0SZ=16 + TLBI at
  the switch); the console is now driven post-MMU — TX is observed
  (banner + `virelai>` prompt in `vm-serial.log`) and **RX is live**
  (claim 6684: the polled virtio receive queue delivers host keystrokes;
  the RX register layout is `[observed]` for the receive queue — see
  `docs/hardware-contract.md`). The M1.5 monitor runs against a mock
  console in tests and live on VZ; the remaining live-gate gap is a live
  reboot/shutdown observation (`docs/status.md`).
- **Guest → host display (milestone six, card G1 — claim 6053):** under
  the runner's flag-gated `--display`/`--screenshot` mode the VM gains a
  virtio-gpu device (`VZVirtioGraphicsDeviceConfiguration`, 1280×720
  scanout) rendered into a `VZVirtualMachineView`. The guest's
  `kernel/src/virtio_gpu.zig` discovers the modern virtio-pci gpu (DID
  0x1050 — the spec DID observed), negotiates VIRTIO_F_VERSION_1 only,
  arms the control queue (+ the cursor queue for device compatibility),
  re-arms post-exit (VZ resets the gpu at ExitBootServices — observed
  `st=00`), and drives the spec 2D path to a writable BSS framebuffer
  (GET_DISPLAY_INFO → RESOURCE_CREATE_2D (B8G8R8X8) →
  RESOURCE_ATTACH_BACKING → SET_SCANOUT → TRANSFER_TO_HOST_2D →
  RESOURCE_FLUSH; one command outstanding at a time, polled used-ring
  drain, cache cleans before every device-read). The `screen` /
  `screen fill <rrggbb>` / `screen peek` monitor commands report the
  transport and push a solid fill; the host's `--screenshot` captures
  are decoded and asserted by `tools/verify-live-screen.sh` — **the
  first non-blank guest framebuffer** (0x00ff00 renders ~(117,251,76)
  through the color-managed pipeline).
- **Framebuffer text (milestone six, card G2 — claim 3194):**
  `kernel/src/text.zig` — a public-domain 8×8 bitmap font (ASCII
  0x20–0x7e, fixed BSS glyph table) plus a pure raster layer (putc/puts,
  cursor, line wrap, a bounded 128-line scrollback ring, `clear`)
  host-tested against an injectable mock canvas (golden glyphs). At boot
  the kernel paints the SAME banner + `virelai>` prompt the serial log
  carries onto G1's framebuffer (fg 0x00ff00 on bg 0x101418) and pushes
  it through G1's transfer/flush unchanged (`text: boot banner
  presented`); the `text` / `text put <string>` / `text clear` monitor
  commands (registry 35→36) render + flush on demand. The host's
  captures are decoded and asserted by `tools/verify-live-text.sh` — the
  banner region shows green-family glyphs over the dark background (the
  screen is no longer monochrome; byte-exact glyphs are the class A
  mock's domain, the live pixels are color-managed + retina-scaled).
- **Road Pops — the boot terminal goes graphical (milestone six, card
  G3 — claim 1574):** `kernel/src/road_pops.zig` is a TEE console. The
  M1.5 console (line editor, tokenizer, command registry, shell idle
  loop) is untouched: its `console.Console` is the Road Pops tee, whose
  `write` forwards every byte to the serial console FIRST (the shared
  seam — the transcript gates stay byte-identical) and, when the
  virtio-gpu transport is ready, to G2's text layer (cheap ring writes)
  with a dirty flag; the shell idle loop drains ONE full-frame present
  per output batch (`road_pops.drain()`, the card-3d pattern). The G2
  one-shot boot paint is replaced by the tee rendering the shell's OWN
  banner + prompt + every reply — the boot terminal IS the screen — and
  the tee's first present emits the G2 `text: boot banner presented`
  evidence on serial. No target armed (default VM) → serial-only,
  byte-identical. `roadpops` command (registry 36→37: armed/dirty/
  presents). Claim-time fix (claim-0015 redux): the injectable `Target`
  struct literal was folded into `.rodata` with link-time `&fn`
  addresses and faulted on the tee's first write — it is built in RAM
  like the console vtable. `tools/verify-live-roadpops.sh` decodes the
  captures: the boot banner AND the live session glyphs below it (a
  working terminal).
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
