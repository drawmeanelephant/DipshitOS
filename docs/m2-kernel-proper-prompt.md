# Milestone two: the kernel proper — ExitBootServices, identity-map MMU, serial console

Planning-first agent prompt for DipshitOS milestone two. Feed this file to
the implementing agent. It must produce a written design covering all six
mandated sections **before** writing any implementation code.

- Branch: `m2-kernel-proper` (suggested)
- Date: 2026-08-05
- Inputs (read first; they are binding): `AGENTS.md`, `docs/roadmap.md`,
  `docs/architecture.md`, `docs/hardware-contract.md`,
  `docs/decisions/0001-arm64-uefi-zig.md`,
  `docs/decisions/0002-kernel-handoff.md`,
  `docs/decisions/0004-kernel-proper.md`

---

You are working on DipshitOS (repo root `dipshitos/`), a from-scratch
AArch64 operating system. Before doing anything else, read `AGENTS.md`,
`docs/roadmap.md`, `docs/architecture.md`, `docs/hardware-contract.md`,
`docs/decisions/0001-arm64-uefi-zig.md`,
`docs/decisions/0002-kernel-handoff.md`, and
`docs/decisions/0004-kernel-proper.md`. They are binding.

## Scope

Implement exactly one milestone: **milestone two, the kernel proper** — the
kernel calls `ExitBootServices` itself, replaces the firmware's page tables
with its own identity-map tables, and drives a minimal MMIO serial console,
printing the banner `DipshitOS kernel has seized control.`. ADR 0004 is the
binding design; this prompt turns it into code and verification. Still
forbidden: libc, POSIX, an allocator beyond fixed carve-outs, interrupts/
GIC, timers, UART RX/FIFO/DMA, ELF loading, processes, filesystems,
graphics, networking, SMP, a scheduler, syscalls. Apple
Virtualization.framework is the **only** supported host; there is no QEMU
path.

## Process rule: planning-first (hard gate)

Do NOT write implementation code until the design is written and
reviewed. Deliver in this order:

1. A written design.
2. A review of the design against the checklist below.
3. Only then: implementation, then verification.

## The design must decide and justify, explicitly

### 1. ExitBootServices — exact sequence and failure modes

ADR 0004 D1/D2 fix the *what*; elaborate the *how*:

- The full takeover sequence and where each step lives in code: switch SP
  to the kernel stack → size and allocate the memory-map buffer →
  `GetMemoryMap` → `ExitBootServices(image_handle, map_key)` → build and
  install the page tables → serial console → banner. State the ordering
  invariant (exit happens before any MMU or device work) and why it is
  non-negotiable.
- `GetMemoryMap`: the two-call size-then-allocate pattern, the buffer's
  allocation type (`EfiLoaderData` via `AllocatePool`), who owns the
  buffer after exit, and how descriptor size/version are preserved for the
  kernel's own map walk.
- The retry loop: exact structure, the bound of 8 attempts (ADR 0004 D1),
  the failure text printed via `ConOut` and where the halt sits, and why
  the kernel must never continue past the bound.
- The auditable "no longer allowed after exit" list (ADR 0004 D2) must
  appear verbatim in code comments next to the `ExitBootServices` call.
- Where the stub's image handle comes from and how the kernel receives it
  (handoff struct, section 5).

### 2. Memory ownership across the exit

- A table of who allocates what, when, with which type and alignment: the
  stub (kernel stack, 16 KiB `EfiLoaderData`, 4K-aligned via
  `AllocatePages`; handoff struct v2, `EfiLoaderData`, 4K-aligned), and
  the kernel (memory-map buffer via `AllocatePool`).
- What the kernel adopts after exit (its own image allocation, the stack,
  the handoff struct, the map buffer) and what stays reserved
  (`EfiRuntimeServices`, ACPI/MMIO, reserved types → mapped Device or left
  unmapped, never used as RAM).
- Where the BSS-resident page-table region lives inside the kernel image
  and how large it is; how the fixed carve-outs are chosen with no
  allocator in play.

### 3. Identity-map MMU setup

- Where and how the tables are built (BSS region, level-parameterized
  builder, 4K granule, block mappings where alignment permits).
- `T0SZ` and table levels chosen for the *observed* address space, and how
  the EFI memory map drives region → attribute (which descriptor types map
  Normal Write-Back, which map Device `nGnRnE`, which stay unmapped).
- MAIR/TCR decisions; IPS read from `ID_AA64MMFR0_EL1` at runtime.
- The TTBR0_EL1 switch: the invariant that the currently executing region
  and the stack are mapped by the new tables **before** `msr ttbr0_el1`;
  then `isb` / `tlbi vmalle1` / `isb`; the MMU is never disabled; a
  synchronous abort during the transition halts at a distinctive marker.

### 4. Serial console driver and the device probe (mandatory first step)

- The probe runs **before** the driver's register table is trusted: what
  the kernel dumps (candidate MMIO regions, register reads and trial
  writes), what output proves the base address and register layout, and
  the explicit rule that the `[inferred]` entries in
  `docs/hardware-contract.md` flip to `[observed]` only with probe log
  evidence. The probe must discriminate the three candidate layouts from
  ADR 0004 D4: PL011-style (primary), 16550-style, and the VZ
  virtio-console register file.
- The driver API: `putc` (poll the TX-ready bit), `puts`, a hex/u64
  printer; where base/offsets live (one table, corrected from the probe);
  no interrupts, no FIFO/DMA, no RX.
- The evidence contingency (fixed physical memory marker, ADR 0004 D4) and
  the exact condition that triggers it.

### 5. Handoff contract v2 and boot-stub changes

- The struct layout in ADR 0004 D5 is binding. The design specifies
  stub-side work: when the stub allocates the stack and the struct, the
  exact register state at the jump (x0–x3), and the kernel-side
  magic/version validation with the loud pre-exit failure path (return a
  non-zero status → the stub writes `RC.TXT` and returns to firmware).
- The "kernel never returns after a successful exit" contract: what the
  kernel does at the end (documented wait/halt), and how the stub and the
  host distinguish success from failure.

### 6. Observable success criteria and verification gates

- The banner is exactly `DipshitOS kernel has seized control.`, followed
  by a hex print of the kernel's own memory-map view.
- Why the host sees it: `vm-serial.log` is empty in every milestone-one
  run (observed); its first real content is the milestone-two proof.
- The roadmap's verification gates, restated as acceptance tests: `zig
  build` / `zig build image` / `zig build run` complete on Apple M4 /
  macOS 27; the banner and hex print appear in `vm-serial.log`; the kernel
  does **not** return (VM reaches its terminal state); a deliberately
  broken handoff (bad magic) produces `RC.TXT` with a non-zero status; and
  each `[inferred]` hardware-contract entry flips to `[observed]` only
  with matching log evidence.
- The exact commands a human runs and the artifacts produced, matching
  AGENTS.md evidence rules: observed vs inferred, no fabricated output,
  logs saved under `artifacts/`.

## Definition of done

- Design written and reviewed, all six sections decided, zero
  contradictions with ADR 0004.
- Kernel boots on Apple M4 / macOS 27 under Virtualization.framework:
  `vm-serial.log` contains the exact banner and the memory-map hex print;
  the VM reaches its terminal state (the kernel did not return to the
  stub).
- Failure path proven: a broken handoff yields `RC.TXT` with a non-zero
  status.
- Hardware contract: every milestone-two `[inferred]` entry flipped to
  `[observed]` with log evidence, or the precise blocked step reported per
  AGENTS.md.
- Docs updated: roadmap M2 marked implemented, architecture current state,
  README status; ADR 0004 stays accepted.
- Nothing from milestone three snuck in.
