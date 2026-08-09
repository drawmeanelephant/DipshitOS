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
- **EFI runtime services survive `ExitBootServices` on VZ**: the kernel's
  post-exit `SetVariable` calls are persisted into the file-backed store.
  **[observed]** — after every VZ run, `artifacts/efi-vars.bin` holds the
  `DipshitM2` variable whose final instance names the kernel's last takeover
  stage (`artifacts/m2-marker-gate.txt`, claim 0009, 2026-08-07).
- **Guest RAM is NOT mapped into the host runner process.**
  **[observed]** — a full submap-aware walk of the VMRunner process's own
  address space finds no 256 MiB region and every `M2_*` constant hit is
  the runner's own rodata/heap array (claim 0009). The ADR 0004 D4
  memory-dump fallback is therefore impossible on VZ; the NVRAM ladder is
  the working form.
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

## Milestone two: the kernel proper (implemented, ADR 0004 — MMU/serial findings are **[observed]** per claims 0010/0013/0020/0021/1517/6684; the remaining items below stay **[inferred]**)

Milestone two is implemented in the guest; the MMU and serial findings
below are **[observed]** (claims 0010/0013/0020/0021/1517/6684 on a real Apple M4 /
macOS 27 VZ host), and the remaining items stay **[inferred]** until a
console is actually driven and serial output proves them. Code/build
success alone is not hardware evidence. The concrete numbers are
deliberately isolated so one observed probe can correct them without
redesign.

### MMU

- The kernel runs at EL1 with the MMU **enabled** and the firmware's
  identity map in effect at kernel entry; the firmware does not disable
  the MMU when jumping. **[inferred]** — standard UEFI AArch64 behavior;
  consistent with milestone-one runs but not directly observed.
- **The MMU takeover completes on VZ (fixed 2026-08-07, claim 0010).** The
  kernel's own identity map installs and the first post-switch runtime call
  succeeds; the NVRAM marker ladder runs `M2_MAPD! → M2_MMUP! → M2_SERIA`
  (`artifacts/m2-marker-gate.txt`, claim 0009). The prior claim-0009
  finding (kernel dies in the MMU-takeover window, ladder ending at
  `M2_MAPD!`) is superseded: three ladder-gated experiments discriminated
  the death site, and the fix has three parts — (a) a pre-switch register
  capture proved the guest implements the ARMv8.1+ TCR_EL1 layout (TG0 at
  bits [15:14] = 0b00 = 4 KB granule, 36-bit IPS; re-captured by claim
  0021, `artifacts/fw-mmu-capture-lines.txt` — the claim-0010 raw
  artifact `m2-firmware-regs.txt` is not in this checkout); (b) the
  identity map now covers the low 4 GiB with declared RAM as Normal
  Write-Back and **every other address (including undeclared firmware MMIO
  such as the NVRAM controller)** as Device nGnRnE, so no post-switch
  access can fault on an unmapped address or hang on a cacheable access to
  an emulated device; (c) **the `tlbi vmalle1` is dropped at the switch**
  — see the TLBI bullets below. The D-cache over the 512 KiB table
  carve-out is cleaned before the switch (architectural hardening;
  independently verified not the fix).
- **The TLBI at the switch is now executed with a corrected start level.
  **[observed]** (claims 6460/7896/1517, supersedes claim 0010)** — the
  claim-0010 finding (a TLBI-forced re-walk faults; omitting it survives)
  was the start-level mismatch in disguise: production T0SZ=25/W=39 started
  the 4 KiB stage-1 walk at level 1 over the L0-rooted tables, so every
  fresh walk faulted, and the no-TLBI crutch only survived by riding stale
  firmware TLB entries (ADR 0006). Claims 6460/7896 separated the two on
  real VZ hardware (4-cell matrix: empty-TLB T0SZ=25 dies deterministically
  at the first re-walk; empty-TLB T0SZ=16 completes the whole console path
  9/9), and  claim 1517 landed the production fix: T0SZ=16 + `tlbi vmalle1`
  at the switch. The ADR-0006 no-TLBI validity window is closed; the
  invalidation list for later re-mapping milestones remains binding (see
  **ADR 0006**).
- **Post-switch MMIO access to the virtio-pci BAR window hangs on VZ.
  **[observed, superseded by claim 1517]** (claim 0020, transition matrix)**
  — under the legacy start level (T0SZ=25) the same flush works pre-EBS
  (phase A) and post-EBS on the firmware translation (phase B), and hangs
  at the first common-cfg read immediately after the DipshitOS identity-map
  install (phases C/D); `vm-serial.log` stayed 0 B. The transition that
  destroyed access was the MMU switch — because the first post-switch read
  of the BAR window was the first access whose firmware TLB entry was
  evicted, and its fresh walk faulted (claims 0018/0020/6460/7896).  With the claim-1517 production fix (T0SZ=16 + TLBI at the switch) the
  post-MMU virtio TX completes: the exact banner + memory-map print +
  terminal state land in `vm-serial.log` (`zig build run` gate passes;
  claim 1517).
- **Firmware translation state at the switch. **[observed]** (claim 0021,
  `artifacts/fw-mmu-capture-lines.txt`)** — `SCTLR_EL1.M=1` (MMU on),
  `TCR_EL1=0x18080351c` (T0SZ=28 → 2^36 VA space, TG0 bits [15:14]=0b00 =
  4 KB granule, 36-bit IPS), `MAIR_EL1=0xffbb4400` (Attr0=0x00
  Device-nGnRnE, Attr3=0xff Normal WB), `TTBR1_EL1=0` (no high-half
  tables). The firmware maps the virtio BAR0 window (VA `0x100010000`) as a
  **1 GiB identity block at L1, Device-nGnRnE, XN=1, AF=1, non-shareable**
  and RAM as L3 pages **Normal WB (0xff), inner-shareable** — memory
  attributes byte-identical to the kernel's choices (Device 0x00 / Normal
  0xff), so the post-switch hang is not an attribute mismatch; the
  structural differences are granularity (1 GiB block vs 4 K pages),
  XN/PXN, T0SZ, and MAIR index numbering.
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

- **The declared MMIO windows are not the console (decoded, claim 0013,
  2026-08-07).** **[observed]** — `0x01000000..0x01010000` is Apple's EFI
  variable-store region (raw bytes spell `efivars\0`; post-exit reads hang
  on the efivars controller); `0x20050000..0x20051000` is a PL011-family
  PrimeCell UART (CID0-3 `0x0d 0xf0 0x05 0xb1`, PID1=0x10, PID2=0x04,
  PID3=0x00, PID0=0x31) — but writing DR after full PL011 init yields zero
  bytes in `vm-serial.log`, so it is Apple's internal EFI debug UART, not
  the guest console. Evidence in `artifacts/efi-vars.bin` (probe-dump
  variables `DipshitP*`) and claim 0013.
- **The VZ serial attachment is a modern virtio-pci console.** **[observed]**
  — bus 0 device 5, `VID=0x1af4 DID=0x1043 class=0x078000` (virtio
  communications controller), discovered by pre-exit PCI enumeration over
  ECAM `0x40000000` (MCFG). BAR0 is a 64-bit BAR firmware-assigned at
  `0x100010000` — *above* the 4 GiB identity-map blanket; the assignment
  varies across boots and the device moves with the BAR, which is why the
  old fixed-window probe never saw it.
- **Transport layout decoded via aligned-u32 config reads** (VZ returns
  garbage for byte reads of config space; unaligned reads alignment-fault):
  common cfg @ BAR0+`0x0000` (len 0x38), ISR @ `+0x1000`, notify @ `+0x4000`
  (multiplier 4), device cfg @ `+0x8000`. Pre-exit the transport arms fully
  (features `0x30000000`/`0x5`, queues 0 + 1 configured, DRIVER_OK).
- **Both virtio-console queues are driven and observed (claim 6684):**
  queue 1 (transmit) and **queue 0 (receive)**. The receive queue's
  register path (queue_select/size/enable/notify_off, the ring GPA
  registers written as 32-bit halves, the 16-bit notify with the queue
  index as the value) is **[observed]** — host input bytes written into the
  guest's 256-byte RX buffer arrive at the kernel's polled `readByte` end
  to end, and the shell's echo proves the exact bytes (`vm-serial.log`,
  claim 6684, 3/3 boots).
- **Post-exit access to the transport hangs on VZ. **[observed, superseded
  by claim 1517]** (claim 0013; refined by claims 0018/0020)** — under the
  legacy start level the first banner TX died somewhere in the first flush;
  `vm-serial.log` stayed 0 B. Claim 0018 bisected the death to the first
  post-switch BAR/common-config read (`M2_TXBR!` written, `M2_TXAR!`
  absent, 10/12 boots), and claim 0020 attributed it to the MMU switch
  (the start-level mismatch making the first fresh walk fault, claims
  6460/7896). Rebasing the BAR below the blanket was tried and abandoned:
  the BAR write *does* move the transport, but to an address the firmware
  never mapped pre-exit, and post-exit config writes aren't reliable — so
  the firmware-assigned base is mapped in place. **With the claim-1517 fix
  (T0SZ=16 + TLBI at the switch) post-exit TX works end-to-end on real VZ
  hardware**: banner + memory-map + `dipshit>` prompt observed in
  `vm-serial.log` (claim 1517). The NVRAM channel (runtime `SetVariable`,
  claim 0015) remains the fallback channel for nvram-console builds.
- ACPI names no console: no SPCR/DBG2 in the XSDT (FACP/GTDT/APIC/MCFG
  only); DSDT (Apple's own, `Apple Vz`) declares only `PCI0` + `efivars`.
  **[observed]**

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
