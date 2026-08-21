# Roadmap archive — Milestone two — the kernel proper

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).

---

## Milestone two — the kernel proper (implemented; VZ serial gate passed 2026-08-08)

> The kernel seizes the machine: it ends UEFI Boot Services, takes over the
> MMU with its own identity-map page tables, and drives a minimal MMIO
> serial console. No firmware services remain in use.

Design: `docs/decisions/0004-kernel-proper.md` (ADR 0004), with the
implementation design and review in `docs/archive/m2-kernel-proper-design.md`.
Apple Virtualization.framework is the only supported host (Apple silicon,
macOS 27+); there is no QEMU path. The guest stays freestanding Zig — no
libc, no POSIX.

**Implemented; all milestone-two gates pass (2026-08-08, claim 1517):**
build gates, the bad-handoff failure gate, the ADR 0004 D4 marker-fallback
gate, and — since claim 1517 — the **VZ serial gate** (`zig build run`:
post-MMU virtio TX puts the exact banner, memory-map print, and terminal
state in `vm-serial.log`). The boot stub allocates the v2 stack/handoff
contract; the kernel captures the map, retries ExitBootServices up to eight
times, builds/installs identity TTBR0_EL1 tables, probes declared MMIO
windows, and enters a terminal WFE loop after serial evidence. The MMU-
takeover death the marker ladder first exposed (claim 0009, `M2_MAPD!`) was
root-caused and **fixed** (claim 0010, 2026-08-07): the identity-map switch
now completes on VZ and the ladder reaches `M2_SERIA`. Claim 0013 decoded
the declared windows (Apple's efivars store + an internal debug UART) and
found the real console — a virtio-pci device outside them; claims 6460/7896
root-caused the post-MMU transport hang (translation start-level mismatch +
stale-TLB crutch) and claim 1517 fixed it in production (T0SZ=16 + TLBI at
the switch). The canonical, always-current gate table lives in
[`docs/status.md`](../status.md).


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
   **passing since 2026-08-07**; the ladder discriminated the death site
   (`M2_MAPD!`, claim 0009), which claim 0010 then root-caused and fixed
   (ladder now reaches `M2_MMUP! → M2_SERIA`; see `docs/status.md`).

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

Historical: every VZ run observed an empty `vm-serial.log` until claim 1517;
the **NVRAM marker ladder** (ADR 0004 D4, claims 0009/0010,
`artifacts/m2-mmu-takeover-gate.txt`) was the working evidence channel, and
claim 0013 observed the actual console — a modern virtio-pci device
(`VID=0x1af4 DID=0x1043`) outside the declared windows (Apple's efivars
store + an internal debug UART). Post-exit access to the virtio transport
hung on VZ (claims 0013/0020) until claims 6460/7896 root-caused it (the
start-level mismatch + stale-TLB crutch) and claim 1517 fixed it in
production: the VZ serial gate now passes (banner + memory-map + terminal
state in `vm-serial.log`). The NVRAM console channel (claim 0015) remains
for nvram-console builds. The declared-window and virtio-pci findings are
`[observed]` in `docs/hardware-contract.md`; the device register layout
stays `[inferred]` where RX is concerned until the RX path is driven.
