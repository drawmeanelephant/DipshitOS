# DipshitOS roadmap

> Live gate-by-gate status is tracked in [`docs/status.md`](status.md). This
> roadmap is the milestone plan; it does not track day-to-day gate progress.

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
SMP, or userspace existed at the end of milestone zero** *(historical
statement of the M0 end state)*.

## Milestone one — separate kernel image (implemented)

> Load a separate AArch64 kernel image and transfer control to its entry
> point.

**Implemented** (2026-08-05; branch `m1-kernel-handoff`, merged to `main`;
see `docs/decisions/0002-kernel-handoff.md`): the boot UEFI app loads
`\KERNEL.BIN` (flat format v1, magic "DSK1") from the ESP via the Simple
File System protocol, allocates `EfiLoaderCode` pages with Boot Services,
copies the image, performs D/I-cache maintenance, and jumps to the kernel
entry (handoff ABI: x0 = base, x1 = size, x2 = System Table, x3 = open
root directory; the kernel returns a u64 status). The kernel was then a
few hundred bytes of freestanding Zig that returned 0 *(historical
description of the M1 stub — superseded by the milestone-two kernel
proper)*.

Observed evidence on Apple M4 / macOS 27: `BOOTED.TXT` (loader ran),
`LOADER.TXT` (loader-observed placement, byte-perfect copy), `RC.TXT`
(`kernel_rc=0x0` — the kernel ran and returned), `MEMMAP.TXT`.

**Known issue (observed, RESOLVED 2026-08-05):** the kernel's own
`\KERNEL.TXT` write previously landed corrupted on Apple VZ firmware
(shifted slices of the kernel image's .rodata) while the loader's
identical writes were byte-perfect. Root cause: the loader loaded the
file verbatim, putting the 24-byte DSK1 header at `base+0` and the
content at `base+24`; LLVM's `adrp`+`add` references to `.rodata`
silently dropped the +24 header offset and read every literal 24 bytes
early. Fix: the loader now parses the header but places the content at
`base+0` (ELF VMA `V` at RAM `base+V`) and jumps to
`base + (entry_offset - 24)`. `KERNEL.TXT` is now byte-perfect and
byte-identical across runs, and `zig build run` **gates** on its content
(`DIPSHITOS KERNEL`, `entry reached via handoff`) in addition to
`BOOTED.TXT` and `RC.TXT`. Full investigation: ADR 0002 and
`artifacts/m1-run*.txt` / `m1-fix-*.txt`.

## Milestone two — the kernel proper (implemented; VZ serial gate blocked)

> The kernel seizes the machine: it ends UEFI Boot Services, takes over the
> MMU with its own identity-map page tables, and drives a minimal MMIO
> serial console. No firmware services remain in use.

Design: `docs/decisions/0004-kernel-proper.md` (ADR 0004), with the
implementation design and review in `docs/m2-kernel-proper-design.md`.
Apple Virtualization.framework is the only supported host; there is no QEMU
path. The guest stays freestanding Zig — no libc, no POSIX.

**Implemented; build gates, the bad-handoff failure gate, and the ADR 0004
D4 marker-fallback gate pass; the VZ serial gate is blocked.** The boot
stub allocates the v2 stack/handoff contract; the kernel captures the map,
retries `ExitBootServices` up to eight times, builds/installs identity
TTBR0_EL1 tables, probes declared MMIO windows, and is designed to enter a
terminal WFE loop after serial evidence. The saved VZ runs produced no
serial output or RC.TXT; the NVRAM marker ladder (claim 0009) shows the
kernel dies in the MMU-takeover window (`M2_MAPD!`) before the serial probe
runs (with the switch skipped it reaches `M2_SERIA` and finds no usable
MMIO serial device). UART/MMIO and MMU hardware assumptions remain
`[inferred]`. Live gate-by-gate status: `docs/status.md`.


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

### Verification gates (observed or precisely blocked; saved under `artifacts/`)

1. `zig fmt --check`, `zig build`, `zig build image`, `zig build inspect`,
   and `swift build --package-path host/vm-runner` complete; outputs are
   saved as `artifacts/m2-*.txt`.
2. **Primary:** a successful VZ run must put the exact banner
   `DipshitOS kernel has seized control.` and the memory-map hex print in
   `vm-serial.log`. The log must also contain `kernel terminal state`.
3. The kernel does **not** return: the runner requires the terminal marker
   emitted immediately before the WFE loop.
4. Failure path still works: the bad-handoff fixture must yield non-zero
   `RC.TXT` before exit. **Passing since 2026-08-06** (`kernel_rc=0x2`).
5. Every `[inferred]` hardware assumption (UART base/layout, MMU behavior,
   GIC presence) is flipped to `[observed]` only with matching probe/serial
   evidence. A blocked host run leaves the entries inferred and is reported.
6. Marker fallback (ADR 0004 D4): `bash tools/verify-marker.sh` —
   **passing since 2026-08-07**; the NVRAM ladder ends `M2_MAPD!`, naming
   the MMU-takeover window as the death site (claim 0009).

### Non-goals (explicit exclusions for this milestone)

- Allocator beyond fixed carve-outs, scheduler, processes, filesystems,
  graphics, networking, SMP, syscalls, ELF loading.
- Interrupts/GIC and timers — the contract records the GIC as an
  assumption now, but nothing programs it until milestone three.
- UART RX, FIFO/DMA/interrupt-driven I/O, any QEMU path.

### Loose end carried forward

The milestone-one `KERNEL.TXT` corruption (ADR 0002 known issue) is
**closed**: the loader's content-at-`base+0` fix made the kernel's write
byte-perfect, and `zig build run` now gates on it. The issue sat on the
UEFI storage path; `ExitBootServices` removes that path entirely, so it
would not have gated milestone-two evidence (which moves to the serial
console) either way.

### Milestone-two evidence status

Every VZ run so far observed an empty `vm-serial.log`. The VZ serial gate
is the decisive hardware probe: until it passes on Apple M4 / macOS 27,
the project makes no observed claim about the VZ guest MMIO address,
register layout, or the post-switch MMU; those remain explicitly
`[inferred]` in `docs/hardware-contract.md` (the NVRAM marker ladder
narrows where the kernel dies, but is not device evidence).

## Milestone 1.5 — interactive kernel monitor (current)

> **Scope frozen 2026-08-06.** The next deliverable is an interactive
> command monitor served by the kernel's own polled serial console — not
> further kernel-proper plumbing first.

Named **Milestone 1.5, the "Dipshit Monitor"**: boot into a terminal,
display a banner, accept commands at `dipshit>`, and execute at least ten
useful commands (identity, memory-map inspection, shell utilities, and
machine controls). Milestone two's kernel already owns the console and
never returns; the monitor is its terminal-loop payload. It promises no new
allocator, MMU work, interrupts, scheduler, userspace, or guest-side
storage drivers.

The M1.5 hard gates, target screen, and milestone status live in
**`docs/status.md`** (the living status document); the twenty-step plan,
agent split, and per-step progress tracker live in **`docs/march-m15.md`**
(update it as work lands). The immediate blocker is the guest RX path: the
kernel console is polled TX-only (ADR 0004) with a no-RX stub until the VZ
serial gate proves a device — the host side already has an interactive
`--console` / `zig build console` input path since 2026-08-06.

## Later milestones (sketches only, not commitments)

- A memory allocator and boot-time memory map walk (the EFI memory map
  the kernel captured at exit, walked by the kernel itself).
- A serial RX path (the milestone-two console is polled TX-only) and
  interrupt setup (GIC) and a timer — the GIC is already recorded as an
  `[inferred]` hardware assumption.
- Eventually: a process abstraction, a filesystem, a network stack — each
  only when the ones below it are demonstrably working.

Each milestone must state what was **observed** versus **inferred** and must
record new hardware assumptions in `docs/hardware-contract.md`.
