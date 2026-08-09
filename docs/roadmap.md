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

## Milestone two — the kernel proper (implemented; VZ serial gate passed 2026-08-08)

> The kernel seizes the machine: it ends UEFI Boot Services, takes over the
> MMU with its own identity-map page tables, and drives a minimal MMIO
> serial console. No firmware services remain in use.

Design: `docs/decisions/0004-kernel-proper.md` (ADR 0004), with the
implementation design and review in `docs/m2-kernel-proper-design.md`.
Apple Virtualization.framework is the only supported host; there is no QEMU
path. The guest stays freestanding Zig — no libc, no POSIX.

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
[`docs/status.md`](status.md).


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

## Milestone 1.5 — interactive kernel monitor (implemented 2026-08-09)

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

**Progress as of 2026-08-08:** the host plumbing (duplex serial attachment,
terminal handling, `zig build console`), console & shell core (RX abstraction,
line editor, tokenizer, `dipshit>` prompt loop), command registry (20 commands,
mock-tested), and transcript test gate (`zig build test-console`) are all
✅ done and gate-passing in CI. The MMU-takeover death is fixed (claim 0010),
the console is identified (virtio-pci, claim 0013), the NVRAM console
channel carries post-exit bytes (claim 0015), and — since claim 1517 — the
**VZ serial gate passes** (`zig build run`: post-MMU virtio TX lands the
banner + `dipshit>` prompt in `vm-serial.log`), and **live RX is wired**
(claim 6684: the polled virtio receive queue delivers host keystrokes end
to end — `verify-live-transcript.sh` asserts the live `dipshit>`
transcript in `vm-serial.log`), and the **live reboot/shutdown
observation is done** (claim 0527: `reboot` resets the machine, `shutdown`
powers it off — 4/4 boots via `verify-live-reboot.sh`), and the
**filesystem gate is closed** (claim 3475, 2026-08-09: `ls`/`cat`/`write`
persist through reboot via the pre-exit ESP snapshot + NVRAM-persisted
writes, `verify-live-fs.sh` — the ESP file window, registry now 20
commands). **Closed 2026-08-09: all 7 hard gates pass; the milestone is
tagged `m1.5-interactive-monitor`.** Current gate
state: [`docs/status.md`](status.md).

The M1.5 hard gates, target screen, and milestone status live in
**`docs/status.md`** (the living status document); the twenty-step plan,
agent split, and per-step progress tracker live in **`docs/march-m15.md`**
(update it as work lands). The monitor itself is implemented and
host-tested (console abstraction, line editor, tokenizer, 20 commands,
banner, mock-level transcript gate), and the host-side `--console`
plumbing landed (steps 4–7); the VZ serial gate **passes** (claim 1517 —
post-MMU virtio TX fixed with T0SZ=16 + TLBI at the switch), the **RX
path is live** (claim 6684 — the polled virtio receive queue delivers
host keystrokes; the live `dipshit>` transcript is asserted in
`vm-serial.log` by `verify-live-transcript.sh`), a **live
reboot/shutdown is observed end to end** (claim 0527:
`verify-live-reboot.sh` — `reboot` resets the machine, `shutdown` powers
it off), and the **filesystem gate is closed** (claim 3475, 2026-08-09:
`ls`/`cat`/`write` persist through reboot via the pre-exit ESP snapshot +
NVRAM-persisted writes, `verify-live-fs.sh`, 1/1 pair). **The milestone
is closed 2026-08-09: all 7 M1.5 hard gates pass; tagged
`m1.5-interactive-monitor`** (see
[`docs/status.md`](status.md)).

## Later milestones (sketches only, not commitments)

- ~~**M1.5 close-out: milestone tag (all hard gates now pass).**~~ **DONE
  2026-08-09 (tag `m1.5-interactive-monitor`)** — the transport layer is
  **done**: post-MMU TX (claim 1517: T0SZ=16 + TLBI at the switch),
  **live RX** (claim 6684: the polled virtio receive queue delivers host
  keystrokes end to end — `verify-live-transcript.sh` asserts the live
  `dipshit>` transcript in `vm-serial.log`), the **live reboot/shutdown
  observation** (claim 0527: `verify-live-reboot.sh` — `reboot` resets
  the machine, `shutdown` powers it off, 4/4 boots; `ResetSystem`
  unit-proven in claim 0011), and the **filesystem gate** (claim 3475:
  `ls`/`cat`/`write` persist through reboot via the pre-exit ESP snapshot
  + NVRAM-persisted writes, `verify-live-fs.sh`, 1/1 pair — the last
  previously-deferred hard gate). **All 7 hard gates pass; milestone
  closed.** The next milestone is a physical page allocator over the
  captured EFI map (canonical ordering: `docs/status.md`).
- ~~A physical page allocator over the captured EFI map.~~ **First step
  DONE 2026-08-08 (claim 3972):** first-fit bitmap allocator over the
  captured map's ConventionalMemory (fixed 128 KiB BSS bitmap over the
  4 GiB identity-map span), wired post-exit; `pages`/`pages selftest`
  monitor commands; 18 unit tests; live-observed on VZ. Still open from
  this sketch: pooling loader/boot-services regions (needs kernel-image +
  map-buffer exclusion ranges), and the boot-time map walk is already
  served by `memmap.MapView` + `mem`/`pages`.
- ~~Exception vectors (VBAR_EL1 + basic synchronous/IRQ handlers).~~
  **DONE 2026-08-08 (claim 9746)** — a real vector table + sync/IRQ
  handlers installed post-MMU; `dipshit> fault` triggers a synchronous
  exception that is reported and resumed live on VZ (class B gate
  `tools/verify-live-exceptions.sh`).
- Interrupt setup (GIC) and a timer — **attempted 2026-08-08 (claim
  7948):** the GICv3 (GICD @ `0x10000000` / GICR @ `0x10010000`, live-
  probed) and the generic timer (CNTP, 24 MHz, GTDT PPI 30) are
  programmed and read-back verified on VZ, and a poll-driven heartbeat is
  live-gate-tested — but **VZ never delivers an interrupt to the guest**
  (GICR is RAZ/WI; PPI/SGI/SPI all inert; full evidence in the claim), so
  IRQ delivery into the claim-9746 vectors stays open for a platform that
  actually signals. The GIC is now `[observed]` in the hardware contract.
- Eventually: a process abstraction, a filesystem, a network stack — each
  only when the ones below it are demonstrably working.

Each milestone must state what was **observed** versus **inferred** and must
record new hardware assumptions in `docs/hardware-contract.md`.
