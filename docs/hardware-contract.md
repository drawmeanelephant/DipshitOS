# DipshitOS hardware contract

This file records every hardware and firmware assumption the project makes.
Anything listed here is a commitment: code in later milestones must either
honor it or update this file first. Entries are tagged **[observed]** when we
have log/command evidence on a real machine and **[inferred]** when the
assumption comes from documentation or reasoning only.

> **Trimmed 2026-08-21 (issue #270):** this file keeps the device summary
> table and the actionable facts only. The full per-device discovery
> narratives (the claim-by-claim histories behind each fact) are preserved
> verbatim in [`archive/hardware-contract-detail.md`](archive/hardware-contract-detail.md).

## Device summary (Apple Virtualization.framework, macOS 27+, Apple silicon)

| Device | PCI ID | Reset at ExitBootServices | Actionable quirks |
|--------|--------|---------------------------|-------------------|
| Disk (virtio-blk) | `0x1af4/0x1042` cls `0x018000` | **YES** (`st=00`) | Re-arm the queue post-MMU via common-config **MMIO** writes; PCI config-space reads must stay pre-exit. Image = 128 MiB, TWO FAT32 partitions found by GPT type-GUID scan (ESP `C12A7328-…`, DATA `0FC63DAF-…`). **[observed]** claims 6420/3678 |
| Console (virtio-console) | `0x1af4/0x1043` cls `0x078000` | Armed pre-exit; post-switch access needs the T0SZ=16+TLBI fix | UEFI `ConOut` is NOT routed here (firmware log stays empty) — the kernel drives it itself. BAR0 is a 64-bit BAR whose assignment **varies per boot** — map in place, never rebase. TX **and** RX queues driven. **[observed]** claims 1517/6684 |
| GPU (virtio-gpu) | `0x1af4/0x1050` cls `0x038000` | **YES** (`st=00`) | Accepts `VIRTIO_F_VERSION_1` alone (split rings, 16-bit notify). Scanout is **B8G8R8X8_UNORM with OPAQUE alpha** (X/A=0 renders transparent). Device is **virtio-gpu 1.2** (24-byte `display_one`; the 1.0 shape wedges the queue). Tail descriptor's `next` must be 0. Spec 2D command path only. **[observed]** claims 6053/3868 |
| USB XHCI | `0x106b/0x1a06` cls `0x0c0330` | **NO** (VZ leaves it halted: USBCMD=0, USBSTS=0x9 — the driver HCRSTs) | Input devices are USB HID behind XHCI, **not** virtio-input. Interrupter set *i* lives at `RTSOFF+0x20+(0x20×i)` — writing ERSTSZ into the MFINDEX region (`RTSOFF+0x00…`) wedges the emulation. Keyboard = port 9, pointer = port 10. **[observed]** claims 4272/4116 |
| USB HID keyboard (port 9) | `0x05ac/0x8105` | n/a | Full speed, boot protocol ACCEPTED, interrupt-IN EP1 maxpkt=8. Delivery cadence ≈ one report per full-frame gpu present — type ≥ 2 s/keystroke and arm ONE transfer TRB (multi-TRB depth wraps the ring and drops reports). Synthesized keyDowns translate to HID reports **only while the runner's window can become key** (idle machine — see Activation wall). Plain-key chords (a–z, 0–9, punctuation, up/down/left/right/home/end/delete/pageup/pagedown/escape — the `macChord` token set) reach the guest keymap; **modifier chords never reach the report**. **[observed]** claims 4116/6050/0935/4769/5093 |
| USB HID pointer (port 10) | `0x05ac/0x8106` | n/a | Full speed, absolute screen-coordinate pointer; `Set_Protocol(boot)` REFUSED — the raw report is ground truth. **NO synthesized route delivers pointer events** (the activation wall); the real-mouse class-C gate is the only live proof. **[observed]** claims 4993/4769 |
| Entropy (virtio-rng) | `0x1af4/0x1044` | **YES** (`st=00`) | Re-arm post-MMU before the first read. Delivers genuine non-deterministic entropy (two boots → different sequences). **[observed]** claim 2665 |
| Network (virtio-net) | `0x1af4/0x1041` cls `0x020000` | **NO** (`st=0f`, DRIVER_OK intact) | Feature ladder must include **`VIRTIO_NET_F_MTU`** (landed mask VER1\|MTU\|MAC = `0x28/0x1`; VER1-only is rejected). Host-set MAC comes from device-config offset 0 under `VIRTIO_NET_F_MAC`. A zeroed **12-byte virtio_net_hdr** is consumed on EVERY TX buffer and WRITTEN into every RX buffer (`rx_hdr_len=12`). RX buffers < **1530 B wedge the device** (production buffer 4096). Sub-60-byte frames travel UNPADDED both directions. Used-buffer IRQ unobserved — drain polled. MAC filter accepts own+broadcast, drops rest with a counter. **[observed]** claims 1373/6076/7293/0148 |
| NAT attachment | (same net device) | n/a | Serves **no DHCP** (DISCOVER goes unanswered — static fallback still reaches the gateway). Closed TCP port → **RST**, not silent drop. Subnet observed 192.168.64.0/24, gateway .1 (no prefix API). Router MAC **varies per boot** — assert learned-line prefixes, never literal MACs. Sends IPv6 RA multicast at boot (dropped by the MAC filter — not a regression). No proxy-ARP off-subnet. No capture file — evidence is guest-observed counters. **[observed]** claims 4678/0351/7026 |
| Sound (virtio-snd) | `0x1af4/0x1059` cls `0x040100` | **NO** (`st=0f`) | Device config counts read **0/0/0** (jacks/streams/chmaps) — enumerate topology via CONTROL-queue JACK_INFO/PCM_INFO queries. VZ speaks the **virtio-1.3 control renumbering** (OK=`0x8000`; PCM_INFO `0x0100` … STOP `0x0105`). Control replies are `[status hdr][entries]` (status FIRST — Linux reads the reverse). Playback TX queue = **queue 2**. Formats S16\|S32\|FLOAT, rates 48k\|96k, 1–2 ch, OUTPUT. **[observed]** claims 6140/5877/7636/3206 |
| Custom virtio | `0x1af4/0x1082` (vendor-defined) | n/a | Firmware boots it with the PCI command register **disabled** (`0x10`) — write `command=0x16` in init before any BAR access. Used-buffer IRQ is a real SPI (69) but **coalesced per burst** — drain the whole used ring. **[observed]** claims 5844/0828/9737 |

Non-PCI platform facts:

- **EFI variable store**: file-backed (`VZEFIVariableStore`); create with
  `init(creatingVariableStoreAt:options:)` on first boot. **EFI runtime
  services survive `ExitBootServices`** — post-exit `SetVariable` persists
  (the NVRAM marker/fallback channel). **[observed]** claim 0009.
- **Guest RAM is NOT mapped into the host runner process** — a host-side
  memory-dump fallback is impossible on VZ. **[observed]** claim 0009.
- Config used: 256 MiB RAM, 2 vCPUs, optional virtio-gpu/sound/net devices
  (flag-gated; the default VM stays byte-identical without flags).
- The project targets Apple silicon / Virtualization.framework only; there
  is no QEMU path.

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
- UEFI firmware: Apple's Virtualization EFI. Vendor and revision are
  unknown/undocumented by Apple. **[inferred]**

## Boot & handoff invariants

- The loader may place the kernel image at any free 4K-aligned address
  (`AllocatePages`, `EfiLoaderCode`) — the kernel must be
  position-independent. **[observed]**
- The loader cleans D-cache + invalidates I-cache over the image
  (`dc cvau` / `ic ivau` / `dsb` / `isb`) before the jump — without it the
  kernel never executes. **[observed]**
- **Image content sits at `base+0`** (the loader parses the DSK1 header but
  does not load it into RAM): ELF VMA `V` lives at RAM `base+V`. This is the
  addressing invariant the kernel's PC-relative references depend on
  (`adr` rides the content offset inside the PC; `adrp`+`add` resolves only
  with content at `base+0`). ADR 0002. **[observed]**
- From milestone two on, the boot stub **never exits** (it keeps UEFI Boot
  Services forever) while the kernel proper calls `ExitBootServices` and may
  then touch MMU and device MMIO (ADR 0004). **[observed]**

## CPU / MMU (actionable facts)

- The kernel runs at EL1 with the MMU enabled and the firmware's identity
  map in effect at entry; it builds its own TTBR0_EL1 tables (4K granule,
  identity map for RAM/kernel/MMIO) and never uses firmware tables.
  **[inferred/design]**
- The guest implements the ARMv8.1+ TCR_EL1 layout (TG0 bits [15:14]=0b00 =
  4 KB granule, 36-bit IPS). **[observed]** claims 0010/0021.
- **The MMU takeover requires T0SZ=16 + `tlbi vmalle1` at the switch.**
  Under the legacy start level (T0SZ=25/W=39 over L0-rooted tables) every
  fresh TLB walk faults after the switch — the first post-switch BAR read
  hung (claims 0013/0018/0020); the start-level mismatch was isolated
  (claims 6460/7896) and the production fix landed (claim 1517). With the
  fix, **post-MMU virtio TX is [observed]** end to end on real VZ: the
  takeover banner + memory-map print + `dipshit>` prompt land in
  `vm-serial.log`. The invalidation list in **ADR 0006**
  (`docs/decisions/0006-mmu-debt-boundary.md`) remains binding for every
  later re-mapping milestone.
- The identity map covers the low 4 GiB as Normal Write-Back and **every
  other address (including undeclared firmware MMIO)** as Device nGnRnE, so
  no post-switch access faults or hangs on an unmapped address.
  **[observed]** claim 0010.
- **TTBR1 translation is incompatible with this kernel's tables on VZ**
  [measured, claim 5804]: 4 KiB-aligned tables fault at the first descent
  level in every configuration; 64 KiB-aligned tables resolve but Normal-WB
  data accesses abort (TLB conflict / external abort DFSC=0x21). The kernel
  therefore stays identity-mapped in TTBR0 (T0SZ=16, TTBR1=0) and every task
  gets a per-task TTBR0 root (EL1-only kernel overlay + own EL0 leaves;
  AP bits enforce EL1-only, UXN/PXN enforce W^X). Never re-adopt a TTBR1 KVA
  shadow without re-validating live.
- Firmware translation state at the switch: `SCTLR_EL1.M=1`,
  `TCR_EL1=0x18080351c` (T0SZ=28, TG0=4K, 36-bit IPS),
  `MAIR_EL1=0xffbb4400` (Attr0 Device-nGnRnE, Attr3 Normal WB),
  `TTBR1_EL1=0`. The firmware maps the virtio BAR window as a 1 GiB L1
  identity block (Device-nGnRnE, XN=1) and RAM as L3 pages Normal WB
  inner-shareable — attributes match the kernel's choices; the structural
  differences were granularity/XN/T0SZ/start-level. **[observed]** claim 0021.
- MAIR_EL1 uses two attributes: Device `nGnRnE` for MMIO and Normal
  Write-Back for RAM. IPS is read from `ID_AA64MMFR0_EL1` at runtime.
  **[inferred]**

## Serial console (actionable facts)

- **The declared MMIO windows are not the console**: `0x01000000..0x01010000`
  is Apple's EFI variable-store region (post-exit reads hang);
  `0x20050000..0x20051000` is a PL011-family PrimeCell UART that is Apple's
  internal EFI debug UART — writes produce zero bytes. **[observed]** claim 0013.
- The console is a **modern virtio-pci console**: bus 0 device 5,
  discovered by pre-exit ECAM (`0x40000000`, MCFG) enumeration. BAR0 is a
  64-bit BAR firmware-assigned above the 4 GiB identity blanket; the
  assignment varies across boots — map in place. **[observed]** claim 0013.
- **Config-space access discipline: aligned-u32 reads only** — VZ returns
  garbage for byte reads of config space; unaligned reads alignment-fault.
  Transport layout: common cfg @ BAR0+`0x0000`, ISR @ `+0x1000`, notify @
  `+0x4000` (multiplier 4), device cfg @ `+0x8000`; the 16-bit kick writes
  the queue index as the value. **[observed]** claims 0013/6684.
- Both queues are driven and observed (TX + RX): host input bytes reach the
  kernel's polled `readByte` end to end through queue 0. **[observed]** claim 6684.
- ACPI names no console: no SPCR/DBG2 in the XSDT; DSDT declares only
  `PCI0` + `efivars`. **[observed]** claim 0013.

## Interrupts & timer (actionable facts)

- **GICv3**: distributor `GICD` @ `0x10000000`, redistributor `GICR` @
  `0x10010000` (the boot CPU's active frame is the same address);
  `GICD_CTLR=0x50` (ARE_NS → v3). VZ's MADT does not yield a usable
  GICD/GICR tuple — use the live-probed fixed-layout fallback. **[observed]**
  claims 7948/9187.
- **SGI/PPI register accesses MUST target the SGI frame at `GICR+0x10000`**
  (e.g. `GICR_IGROUPR0=0x10080`, `ISENABLER0=0x10100`, `ICFGR1=0x10c04`):
  RD-frame offsets silently never enable PPIs — this was the observed timer
  delivery blocker. **[observed]** claim 9187 (+ Xcode 27 SDK audit,
  `artifacts/vz-irq-api-audit.txt`).
- The ARM generic timer runs at `CNTFRQ_EL0=24 MHz`; the GTDT supplies EL1
  physical-timer GSIV **30**, level-triggered. A real CNTP PPI 30 interrupt
  is delivered, acknowledged (`ICC_IAR1_EL1`), EOI'd (`ICC_EOIR1_EL1`), and
  re-armed — the production idle loop does not poll the comparator.
  **[observed]** claim 9187.
- The one-second timer PPI is the kernel's preemption clock (tick-driven
  round-robin scheduler). **[observed]** claim 5275.
- Xcode 27's public Virtualization.framework SDK exposes no
  `VZGICConfiguration` or host interrupt-injection API (Hypervisor.framework
  separately exposes `hv_gic_create`/`hv_gic_set_spi`/`hv_gic_send_msi`);
  none is needed for the timer PPI path. **[observed]** claim 9187.
- Interrupts are masked at kernel entry (firmware behavior) and explicitly
  unmasked only after vectors, GIC, dispatcher, and timer are armed.

## Input (actionable facts)

- Screen-side input is **USB XHCI + HID, not virtio-input** — no 0x1052
  device exists on the bus. **[observed]** claim 3868.
- **The activation wall**: VZ only translates host input for its KEY window,
  and macOS 14+ refuses programmatic focus-stealing from a background
  process while another app holds focus. Synthesized keyboard keyDowns work
  only while the machine is idle; modifier chords never reach the HID
  report; **every synthesized pointer route fails** (five routes probed with
  responder tracing, claim 4769). Live proof routes: the class-C real-mouse
  gate (`tools/verify-pointer-manual.sh`) and the trust-self-gating CG gate
  (`tools/verify-live-pointer-cg.sh`). **[observed]** claims 0935/4993/4769.
- The input drain must run BEFORE the framebuffer present in the shell idle
  loop so a report is never starved behind a slow full-frame present.
  **[observed]** claim 6050.

## What milestone zero does NOT assume (and does not touch)

- No direct MMIO. No UART programming. No DMA. No interrupts. No GIC.
- No memory map assumptions beyond what the firmware provides.
- No timer services. (The "wait" in the boot application is a plain busy
  loop with no hardware access.)
- No platform clock, no RTC, no power management.
