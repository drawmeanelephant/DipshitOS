# DipshitOS roadmap

## Milestone zero (implemented) — boot pipeline proof

A tiny AArch64 UEFI application, written in Zig, is built, placed at
`EFI/BOOT/BOOTAA64.EFI` on a FAT32 ESP inside a GPT image, and booted under
UEFI by the Swift Virtualization.framework launcher (Apple silicon only;
there is no QEMU path in this project). The application prints

```
DIPSHITOS BOOTLOADER
firmware has agreed to cooperate
```

and returns control to the firmware.

Deliverables: `boot/`, `host/vm-runner/`, `image/`, `tools/`, `docs/`,
`build.zig`, `build.zig.zon`, `AGENTS.md`, `README.md`.

**No kernel, loader, allocator, scheduler, filesystem, graphics, networking,
SMP, or userspace exists at the end of this milestone.**

## Milestone one — separate kernel image (implemented)

> Load a separate AArch64 kernel image and transfer control to its entry
> point.

**Implemented** on branch `m1-kernel-handoff` (see
`docs/decisions/0002-kernel-handoff.md`): the boot UEFI app loads
`\KERNEL.BIN` (flat format v1, magic "DSK1") from the ESP via the Simple
File System protocol, allocates `EfiLoaderCode` pages with Boot Services,
copies the image, performs D/I-cache maintenance, and jumps to the kernel
entry (handoff ABI: x0 = base, x1 = size, x2 = System Table, x3 = open
root directory; the kernel returns a u64 status). The kernel is a few
hundred bytes of freestanding Zig and returns 0.

Observed evidence on Apple M4 / macOS 27: `BOOTED.TXT` (loader ran),
`LOADER.TXT` (loader-observed placement, byte-perfect copy), `RC.TXT`
(`kernel_rc=0x0` — the kernel ran and returned), `MEMMAP.TXT`.

**Known issue (observed):** the kernel's own `\KERNEL.TXT` write lands
scrambled on Apple VZ firmware (shifted slices of the kernel image's
.rodata) while the loader's identical writes are byte-perfect. Root cause
not yet determined; investigation state is recorded in ADR 0002 and
`artifacts/m1-run*.txt`. The milestone gates on `RC.TXT`, not `KERNEL.TXT`.

Next steps for this milestone's loose ends:
- Root-cause the VZ `KERNEL.TXT` corruption (ADR 0002 "Known issue").

## Milestone two — the kernel proper (next phase)

> The kernel seizes the machine: it ends UEFI Boot Services, takes over the
> MMU with its own identity-map page tables, and drives a minimal MMIO
> serial console. No firmware services remain in use.

Design: `docs/decisions/0004-kernel-proper.md` (ADR 0004). Apple
Virtualization.framework is the only supported host; there is no QEMU
path. The guest stays freestanding Zig — no libc, no POSIX.

### Goal

Turn the milestone-one kernel stub (runs on UEFI services, prints, returns)
into a kernel that **keeps** the machine:

1. Call `ExitBootServices` itself (stub never does), with a documented
   retry-and-abort behavior, after capturing the EFI memory map.
2. Replace the firmware's page tables with the kernel's own identity-map
   tables (TTBR0_EL1, 4K granule, Device/WB attributes from the memory
   map, MMU never disabled).
3. Drive a minimal MMIO serial console (polled TX, no interrupts/DMA/RX)
   and print the banner `DipshitOS kernel has seized control.` — the first
   real content in the long-empty `vm-serial.log`.
4. Hand off to the kernel through the versioned contract v2 (handoff
   struct: image handle, kernel stack, bounds; x3 repurposed from the ESP
   root directory).

### Deliverables

- `kernel/` — the kernel proper: `ExitBootServices` call + retry loop,
  memory-map capture, static BSS-resident identity-map tables and the
  TTBR0_EL1 switch, the `uart` console module, banner + memory-map hex
  print.
- `boot/` — stub updates only: allocate the kernel stack and handoff
  struct (`EfiLoaderData`), pass the struct in x3, keep everything else
  (evidence writes, failure return) exactly as milestone one.
- `host/` — only if the fixed-memory-marker fallback is needed (see
  evidence contingency in ADR 0004 D4): a dump of the marker address.
  The serial path needs no runner change — `vm-serial.log` is already
  captured.
- `docs/` — this roadmap section, ADR 0004, architecture update, and the
  new `[inferred]` hardware-contract assumptions.

### Verification gates (must be observed, saved under `artifacts/`)

1. `zig build`, `zig build image`, `zig build run` complete on Apple M4 /
   macOS 27.
2. **Primary:** `vm-serial.log` contains the exact banner
   `DipshitOS kernel has seized control.` and the memory-map hex print
   after a VZ boot. (Milestone-one logs are empty; first content = proof.)
3. The kernel does **not** return: the VM reaches its terminal state
   (wait loop or clean halt) as the runner observes it.
4. Failure path still works: a broken handoff (bad magic) yields `RC.TXT`
   with a non-zero status via the pre-exit return path.
5. Every `[inferred]` hardware assumption (UART base/layout, MMU behavior,
   GIC presence) is flipped to `[observed]` in
   `docs/hardware-contract.md` only with matching log evidence.

### Non-goals (explicit exclusions for this milestone)

- Allocator beyond fixed carve-outs, scheduler, processes, filesystems,
  graphics, networking, SMP, syscalls, ELF loading.
- Interrupts/GIC and timers — the contract records the GIC as an
  assumption now, but nothing programs it until milestone three.
- UART RX, FIFO/DMA/interrupt-driven I/O, any QEMU path.

### Loose end carried forward

The milestone-one `KERNEL.TXT` scrambling (ADR 0002 known issue) is on the
UEFI storage path; `ExitBootServices` removes that path entirely, so it no
longer gates milestone-two evidence (which moves to the serial console).
The root-cause investigation remains open as a separate thread for anyone
who wants to close it.

## Later milestones (sketches only, not commitments)

- A memory allocator and boot-time memory map walk (the EFI memory map
  the kernel captured at exit, walked by the kernel itself).
- Interrupt setup (GIC) and a timer — the GIC is already recorded as an
  `[inferred]` hardware assumption.
- Eventually: a process abstraction, a filesystem, a network stack — each
  only when the ones below it are demonstrably working.

Each milestone must state what was **observed** versus **inferred** and must
record new hardware assumptions in `docs/hardware-contract.md`.
