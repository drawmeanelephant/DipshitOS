# Milestone one: separate kernel image + control transfer

> **ARCHIVED (2026-08-07).** Milestone one is implemented and merged to
> `main` — see `docs/decisions/0002-kernel-handoff.md` and
> `docs/status.md`. This prompt is retained as a historical record; do not
> feed it to an implementing agent.

Planning-first agent prompt for DipshitOS milestone one (historical
record). At the time it was active, the implementing agent had to produce
a written design covering all five mandated sections **before** writing
any implementation code.

- Branch: `m1-kernel-handoff`
- Date: 2026-08-05
- Inputs (read first; they are binding): `AGENTS.md`, `docs/roadmap.md`,
  `docs/architecture.md`, `docs/hardware-contract.md`,
  `docs/decisions/0001-arm64-uefi-zig.md`

---

You are working on DipshitOS (repo root `dipshitos/`), a from-scratch
AArch64 operating system. Before doing anything else, read `AGENTS.md`,
`docs/roadmap.md`, `docs/architecture.md`, `docs/hardware-contract.md`,
and `docs/decisions/0001-arm64-uefi-zig.md`. They are binding.

## Scope

Implement exactly one milestone: **load a separate AArch64 ELF kernel
image and transfer control to its entry point.** Still forbidden: libc,
POSIX, allocators beyond UEFI `AllocatePages`, MMU reconfiguration,
interrupts/GIC, timers, drivers beyond the single evidence channel below,
processes, filesystems, graphics, networking, SMP.

## Process rule: planning-first (hard gate)

Do NOT write implementation code until the design is written and
reviewed. Deliver in this order:

1. A written design.
2. A review of the design against the checklist below.
3. Only then: implementation, then verification.

## The design must decide and justify, explicitly

### 1. Boot ABI (the handoff contract)

- Where the kernel image lives on the ESP, who allocates its pages, and
  alignment/load-address policy.
- The entry state at the moment of transfer: which registers carry what
  (e.g. x0 = handoff struct pointer), stack location/size/alignment and
  who set it up, MMU/paging state at entry (do you preserve the
  firmware's identity map? state it), caches, live vs dead registers.
- Exact handoff-struct layout (fields, offsets, alignment), and who owns
  the memory it lives in.
- What the kernel may touch at entry vs after.

### 2. ELF validation rules

- Exact accept/reject rules: ELF magic, class, endianness, e_machine
  (AArch64), e_type, header sanity, required program headers.
- PT_LOAD rules: bounds vs file size, overlap policy, alignment handling,
  and entry point must lie inside a loaded segment.
- Rejection behavior: loud, observable failure on the firmware console
  *before* any services are exited, with a specific message. Never a
  silent or partial transfer.

### 3. Memory ownership

- Who allocates the kernel's memory, the stack, and the handoff struct;
  how each is tagged in the EFI memory map so the kernel's own map walks
  see them correctly.
- Who owns the memory map after handoff, and who owns every region the
  firmware used for itself.
- The exact point where the firmware stops being the landlord.

### 4. ExitBootServices retry behavior

- EBS may return EFI_INVALID_PARAMETER on a stale map key. Specify the
  re-fetch + retry loop, the maximum retry count, and the abort behavior.
- What must be captured from Boot Services *before* exit and how it
  survives (the memory map and anything else the kernel needs) — and the
  explicit list of things you may no longer do after exit.
- Ordering: EBS before or after the jump, and why.

### 5. Observable success criteria

- The kernel's banner is exactly: `DipshitOS kernel has seized control.`
- Define how the host observes that line after EBS, when ConOut, the
  Simple File System protocol, and `\BOOTED.TXT` are all gone. Choose and
  justify the evidence channel (e.g. direct UART MMIO on the chosen host,
  or a fixed memory marker the host dumps). If this introduces new
  hardware assumptions, update `docs/hardware-contract.md` FIRST — that
  is the documented rule.
- The exact commands a human runs and the artifacts produced, matching
  AGENTS.md evidence rules: observed vs inferred, no fabricated output,
  logs saved under `artifacts/`.

## Definition of done

- Design written and reviewed, all five sections decided.
- Kernel image loads, validates, transfers control; host shows
  `DipshitOS kernel has seized control.` from a real boot on Apple silicon
  (VZ — the only supported host), logs saved.
- Docs updated: roadmap (M1 complete), architecture, hardware contract,
  an ADR for the boot ABI (ADR 0002), README status.
- Nothing from later milestones snuck in.
