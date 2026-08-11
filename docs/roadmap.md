# DipshitOS roadmap

> Live gate-by-gate status is tracked in [`docs/status.md`](status.md). This
> roadmap is the milestone plan; it does not track day-to-day gate progress.

## Milestone zero (implemented) — boot pipeline proof

A tiny AArch64 UEFI application, written in Zig, is built, placed at
`EFI/BOOT/BOOTAA64.EFI` on a FAT32 ESP inside a GPT image, and booted under
UEFI by the Swift Virtualization.framework launcher (Apple silicon running
macOS 27 or newer only; there is no QEMU path in this project). The application prints

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
allocator, MMU work, interrupts, scheduler, or userspace. *(Post-tag, the
allocator, exception vectors, and — claim 6420 — a guest-side FAT32
storage driver on the ESP landed anyway; the milestone's promise list is
historical.)*

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
commands) **and upgraded the same day to a real FAT32 storage driver**
(claim 6420: `ls`/`cat`/`write` read and write the live ESP's FAT volume
through a virtio-blk transport; files persist on the disk itself;
NVRAM variables are no longer the persistence medium). **Closed
2026-08-09: all 7 hard gates pass; the milestone is tagged
`m1.5-interactive-monitor`.** Current gate
state: [`docs/status.md`](status.md).

The M1.5 hard gates, target screen, and milestone status live in
**`docs/status.md`** (the living status document); the twenty-step plan,
agent split, and per-step progress tracker lived in
**`docs/archive/march-m15.md`** (M1.5 closed 2026-08-09, tagged
`m1.5-interactive-monitor`; the active per-milestone tracker is
**`docs/march-m3.md`**). The monitor itself is implemented and
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
NVRAM-persisted writes, `verify-live-fs.sh`, 1/1 pair) **and upgraded to
a real FAT32 storage driver** (claim 6420: the ESP's FAT volume is
mounted and written through a virtio-blk transport, files persist on the
disk itself). **The milestone is closed 2026-08-09: all 7 M1.5 hard
gates pass; tagged `m1.5-interactive-monitor`** (see
[`docs/status.md`](status.md)).

## Milestone three — allocator, interrupts, tasks, EL0/SVC, syscalls, uaccess, and userspace (**CLOSED 2026-08-10, tagged `m3-userspace`**)

> The milestone-three plan, in canonical order (mirroring
> `docs/status.md`'s "What comes immediately afterward" and the per-card
> tracker [`docs/march-m3.md`](march-m3.md)): physical allocator →
> exception vectors → GIC + timer → kernel tasks → EL0/SVC boundary →
> syscall ABI → uaccess → per-task address spaces → user lifecycle → ESP
> exec → blocking syscalls. **All cards are done** (claims 3972/5162/9746/
> 9187/5275/8215/3594/6120/5804/6729/6783/3200; see the tracker for
> per-card evidence), the full class A + class B gate set re-ran green at
> the candidate (claim 0707), and the milestone is **tagged
> `m3-userspace`** (2026-08-10).

- ~~A physical page allocator over the captured EFI map.~~ **First step
  DONE 2026-08-08 (claim 3972):** first-fit bitmap allocator over the
  captured map's ConventionalMemory (fixed 128 KiB BSS bitmap over the
  4 GiB identity-map span), wired post-exit; `pages`/`pages selftest`
  monitor commands; 18 unit tests; live-observed on VZ. **Loader/boot-
  services pooling DONE 2026-08-09 (claim 5162):** the pool now covers
  conventional + loader + boot-services RAM, with explicit exclusion
  ranges protecting the live kernel image, stack, handoff page, and
  captured-map buffer (25 unit tests, class-A green, `pages` reports
  `excluded=`). The boot-time map walk is already served by
  `memmap.MapView` + `mem`/`pages`.
- ~~Exception vectors (VBAR_EL1 + basic synchronous/IRQ handlers).~~
  **DONE 2026-08-08 (claim 9746)** — a real vector table + sync/IRQ
  handlers installed post-MMU; `dipshit> fault` triggers a synchronous
  exception that is reported and resumed live on VZ (class B gate
  `tools/verify-live-exceptions.sh`).
- ~~Interrupt setup (GIC) and a timer.~~ **DONE 2026-08-09 (claim 9187,
  superseding claim 7948's blocker conclusion):** corrected ACPI MADT GIC
  type IDs, GICv3 redistributor SGI-frame offsets, and ICFGR trigger-bit
  programming. A real periodic CNTP PPI 30 now enters the claim-9746 EL1
  IRQ vector on VZ, is acknowledged/EOI’d and re-armed; the strict live
  gate requires `ticks=5 irq=5 poll=0` and passes 3/3 boots.
- ~~Tasks (kernel tasks first).~~ **DONE 2026-08-09 (claim 5275)** — a
  tick-driven round-robin scheduler between two kernel tasks: the
  shell/main task and a demo worker on its own static BSS stack preempt
  at every timer PPI, with a minimal save/restore (the claim-9746 stubs
  already keep the register file on the stack, so the scheduler only
  saves the vector-frame pointer + ELR/SPSR per task). `dipshit> tasks`
  reports per-task saves/resumes/advances; host tests cover the switch
  logic; the class-B live gate `tools/verify-live-tasks.sh` proves both
  tasks advance across ticks on VZ (worker report line after ≥ 2 real
  context switches + a responsive shell), and the strict live-timer gate
  still passes under preemption. No userspace, no MMU changes — a later
  card adds userspace.
- ~~First EL0t task + SVC kernel boundary.~~ **DONE 2026-08-09 (claim
  8215, PR #60)** — a statically linked EL0 task with page-local user
  text/stack apertures, x8-selected `svc #0`, SP_EL0-preserving
  scheduling, and the strict live gate `tools/verify-live-userspace.sh`
  (two sequenced pings prove return to EL0 under timer preemption).
- ~~Frozen syscall ABI + runtime dispatch table.~~ **DONE 2026-08-10
  (claim 3594, PR #64)** — ADR 0007
  ([`docs/decisions/0007-syscall-abi.md`](decisions/0007-syscall-abi.md))
  freezes x8 number, x0–x5 arguments, x0 result; the runtime-built
  64-slot table implements slots 0–4 (`ping`/`write`/`yield`/`exit`/`sleep`) and
  returns `ENOSYS` for reserved 5–63; `sys_write` is bounded to the
  kernel-known EL0 apertures and the low-4-GiB identity blanket;
  scheduler yield/exit/sleep hooks and deterministic `syscalls` counters land
  with the live gate `tools/verify-live-svc.sh` passing 1/1 (evidence:
  `artifacts/syscall-abi-3594/verification-summary.txt`).
- ~~**uaccess: fault-safe copy-in/copy-out.**~~ **DONE 2026-08-10 (claim
  6120)** — `kernel/src/uaccess.zig` adds bounded `copy_in`/`copy_out`
  over the EL0 text (read) + stack (read/write) apertures with the
  ADR-0007 `EFAULT` (`-3`) contract (out-of-region, overflow, unmapped,
  permission), and a masked fault-recovery window: a real EL1 data abort
  during a copy is latched and ELR advanced past the faulting instruction,
  so the copy returns EFAULT instead of crashing EL1 (an
  optimizer-reordering hazard that parked on the first live run was
  root-caused and fixed with volatile window state). `sys_write` migrates
  onto uaccess; the `uaccess` monitor command and the EL0 payload prove
  the contract and the recovery live on VZ (gate
  `tools/verify-live-uaccess.sh`, 1/1: `valid=1 fault=1 recovered=1`,
  `uaccess: efault ok n=8`, no `[EXC] parking`).

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
  previously-deferred hard gate) **upgraded to a real FAT32 storage
  driver** (claim 6420: the ESP's FAT volume is mounted + written through
  a virtio-blk transport; files persist on the disk; NVRAM is no longer
  the persistence medium). **All 7 hard gates pass; milestone closed.**
  *(The milestone-three cards continue in the Milestone three section
  above; canonical ordering: `docs/status.md`.)*
- A guest-side filesystem — **the ESP FAT32 driver landed 2026-08-09
  (claim 6420):** `kernel/src/fat.zig` (GPT + FAT32 mount/list/read/write
  with injected sector I/O) over `kernel/src/virtio_blk.zig` (the
  runner's disk as a modern virtio-blk transport, DID 0x1042 on VZ,
  re-armed post-exit after VZ resets the device at ExitBootServices).
  `ls`/`cat`/`write` serve the live ESP volume; files persist on the
  disk itself. **A general (non-ESP) filesystem is DONE 2026-08-10
  (claim 3678, milestone four card 2)** — the driver now mounts ANY FAT32
  volume at ANY disk offset (`fat.mount_partition`), walks arbitrary
  directory cluster chains with `/`-path resolution (the image's
  EFI/BOOT tree is reachable: `ls [<dir>]`, `cat <file|path>`), and the
  disk image carries a second 36 MiB DATA FAT32 partition (Linux-FS type
  GUID) mounted by the new `mount <esp|data>` command with a re-
  snapshotted, honestly-labeled window. Live gate
  `tools/verify-live-gfs.sh` PASS 1/1 — the DATA volume is mounted by
  GUID, listed, read, written, and the file persists across a reboot on
  the disk itself.
- ~~**Entropy/CSPRNG (sketch).**~~ **DONE 2026-08-10 (claim 2665, milestone
  four card 1)** — the kernel has a REAL randomness source: a modern
  virtio-pci entropy driver (`kernel/src/virtio_entropy.zig`, DID 0x1044)
  with the claim-6420 post-MMU re-arm lesson (**observed: VZ resets the
  device at ExitBootServices — `entropy: pre-rearm st=00`**), a
  freestanding ChaCha20 CSPRNG (`kernel/src/csprng.zig`, RFC 7539,
  KAT-pinned in `zig test`) seeded from a 64-byte boot-time device read
  (`entropy: seeded n=64`), the `random [n]` monitor command (registry
  27→28), and a real ASLR consumer (the exec path randomizes the loaded
  EL0 program's user stack VA per boot). Live gate
  `tools/verify-live-entropy.sh` PASS 2/2 — two boots produce different
  `random` sequences and stack placements; see
  `docs/hardware-contract.md` (entropy bullet now `[observed]`).
- **A process abstraction is DONE 2026-08-10 (claim 3848, milestone four
  card 3)** — a bounded process registry (`kernel/src/process.zig`) where
  each Process owns the loaded image, the address space, the lifecycle
  state, and the exit status (which now survives the executor task's
  reap); exec and the boot-time static EL0 payload register as real
  processes, `exit_current` feeds the registry, the `procs` monitor
  command (registry 29→30) prints the table, and the new class-B gate
  `tools/verify-live-procs.sh` PASS 1/1 shows the exec'd program running
  as a process with the boot payload's exited status kept past the reap.
- **Concurrent processes is DONE 2026-08-10 (claim 0826, milestone four
  follow-on)** — the exec gate (`scheduler.user_root_in_use`, one user
  program at a time) is gone: every process owns its own TTBR0 user root
  and allocator-backed text/user-stack/EL1-exception-stack pages, the
  syscall/uaccess regions arm per task at SVC entry, and exec gates on
  capacity (pool slot, table carve-out, registry) instead. Two programs
  now load and run CONCURRENTLY — the class-B gate
  `tools/verify-live-concurrent.sh` PASS 1/1 on VZ shows a `procs` table
  with TWO `state=running` USER.BIN rows (distinct task ids + stack VAs)
  and both programs' markers interleaving; the full shared-seam live
  sweep (exec/procs/addrspaces/tasks/userspace/svc/uaccess/lifecycle/
  sleep/entropy) is green against the relaxed gate.
- **A long-lived process among live peers is DONE 2026-08-10 (claim 4613,
  milestone-four follow-on 2)** — claim 0826's two processes were copies
  of the SAME program that both exited; this card adds a SECOND DSK1
  image (COUNTER.BIN from `user/src/counter.zig`, embedded by the same
  build/image pipeline) that NEVER exits (sys_write + sys_yield only, no
  sys_exit) with DISTINCT `counter: alive` markers, and returns an exited
  program's allocator pages at the same reap that frees its executor slot
  (the exited descriptor stays in `procs`). The class-B gate
  `tools/verify-live-long-lived.sh` PASS 1/1 on VZ — the counter stays
  `state=running` across the whole session while USER.BIN exits, is
  reaped, and is re-exec'd into the freed slot (the runner's new
  `--script2`/`--script2-after` second phase forwards the re-exec after
  the first reap), the `pages` free count recovers, and a further exec
  with both live reports `pool_full` — the capacity gate with one spare
  slot; the full shared-seam live sweep is green against the second
  program.
- **Kill — the kernel owns process lifetime — is DONE 2026-08-10 (claim
  7786, milestone-four follow-on 3, card 3c)** — claim 4613 proved a
  process can REFUSE to exit (COUNTER.BIN loops forever) but nothing
  could END it; the new `kill <pid|name>` monitor command (registry
  30→31) arms the target's TCB (`scheduler.request_kill`) and the ring
  converts its NEXT selection into the existing exit path with the
  reserved status 137 (no syscall, ADR 0007 frozen; the switching core
  is untouched). The killed process flows through the REAL lifecycle —
  exit → zombie → idle-reap → page return (`procs` shows
  `state=exited task=reaped exit=137`) — and the class-B gate
  `tools/verify-live-kill.sh` PASS 1/1 on VZ: NO `counter: alive` marker
  lands after the `kill:` line (only one task runs at a time, so the
  killed task never executes again), the `pages` free count recovers by
  EXACTLY 5 at the reap, and a phase-3 re-exec lands in the freed slot
  (the runner gains the `--script3`/`--script3-after` third phase); the
  full 12-gate shared-seam live sweep is green.
- **Per-process exit reports — exact counts — is DONE 2026-08-10 (claim
  1014, milestone-four follow-on 3, card 3d)** — the exit/reap report
  machinery was a single first-wins-while-undrained flag (documented
  debt from claims 0826/4613), so N exits in one idle-loop window
  collapsed to ONE report line and the concurrent/long-lived gates had to
  assert ≥1. The three single-slot report flags become bounded 4-slot
  name+status FIFOs (pushed from exception context — pure BSS writes —
  and drained IN ORDER by the shell idle loop and the monitor, no
  double-print; drop-oldest overflow, documented + host-tested; ADR 0007,
  the switching core, and the lifecycle states untouched — reporting
  machinery only). The concurrent + long-lived gates tighten to EXACT
  counts and both PASS 1/1 on VZ: two exits in one window print exactly
  two `tasks user-exec exited status=43` / two `procs USER.BIN exited
  status=43` / two `tasks user-exec reaped` lines, in order, with the
  boot payload's `tasks user-el0 exited status=7` staying its own
  distinct line; the full 12-gate shared-seam live sweep is green.
- **Exec context block — arguments to EL0 — is DONE 2026-08-10 (claim
  4636, milestone-four follow-on 3, card 3e)** — the tokenizer already
  split `exec <file> [arg...]` but `monitor.exec` ignored the extras, so
  a program's identity was its image only and the SAME binary could not
  distinguish itself per exec. Card 3e packs a bounded argv block (8
  args × 32 B, NUL-terminated, per-arg 31-byte truncation; >8 args is an
  honest refusal) into the process's OWN text page right after the
  loaded content — the text leaf is already EL0 read-only (W^X, AP=
  read-only), so the block is a READ-ONLY leaf with ZERO extra pages
  (the per-program 5-page budget and every exact-count page gate stay
  untouched) — and extends the ENTRY contract (NOT a syscall; ADR 0007
  frozen): `_start` receives `argc` in x0 and the block VA in x1 via the
  claim-9746 frame slots. The text aperture extends over the block, so
  uaccess copy_in reads it and copy_out faults (host-tested both
  directions). The class-B gate `tools/verify-live-args.sh` PASS 1/1 on
  VZ — `exec USER.BIN alpha` + `exec USER.BIN beta`: the SAME binary
  loads twice, the procs snapshot shows two `state=running` rows with
  distinct task ids + stack VAs, the DISTINCT markers (`user:
  arg=alpha` / `user: arg=beta`) prove which invocation is which, both
  programs complete (status 43 — EXACT FIFO counts), and a third exec is
  `pool_full` (5/5, no spare); the full 12-gate shared-seam live sweep
  is green.
- **IPC — distinct processes exchange data (claim 5965, milestone-four
  follow-on 3, card 3f)** — coexistence is proven (claims 0826/4613) but
  two live processes cannot COMMUNICATE; the strongest proof of "real
  processes" is end-to-end data flow between them. The card lands the
  FIRST inter-process data path: a bounded per-process kernel mailbox
  (4 × 64 B BSS ring per process id, no allocation —
  `kernel/src/mailbox.zig`) behind TWO new syscalls (the card's ONE ABI
  change, following the `sys_sleep` slot-4 precedent): `sys_ipc_send`
  (slot 5) copies the caller's bytes through uaccess into the TARGET's
  ring (full → `ENOSPC` -5), `sys_ipc_recv` (slot 6) copies the caller's
  OWN ring out (empty → 0; peek → copy_out → drop, so an EFAULT never
  loses a message) — cross-process isolation (a process reaches only its
  own mailbox via recv and a live target's via send), the ring reset on
  process create/recycle. `mbox [<pid>]` monitor command (registry
  31→32) dumps per-process pending/sent/recv + the queued bytes.
  COUNTER.BIN gains a periodic send (`ipc: ping <d>` every 3 iterations,
  target pid parsed from its argv — card 3e's entry contract) and a
  THIRD image PEER.BIN (`user/src/peer.zig` through the parameterized
  build pipeline) recv-loops forever and echoes `peer: got ping <d>` —
  TWO never-exiting programs exchanging bytes, byte-exact in the serial
  log. Pool math at 5 slots: counter + peer + shell + worker + idle =
  5/5, NO spare (a third exec is `pool_full`; the 3g capstone raises the
  budget). The class-B gate `tools/verify-live-ipc.sh` PASS 1/1 on VZ:
  `exec PEER.BIN` + `exec COUNTER.BIN 1` back to back, the counter's
  `ipc: ping N` sends and the peer's `peer: got ping N` echoes
  interleaved across the whole log (every send echoed byte-for-byte),
  `mbox` shows the peer's ring drained (pending ≤ 1, sent − recv ==
  pending) and the counter's ring empty, both processes still
  `state=running` at the final `procs` and neither ever exits, a third
  exec is `exec: no free scheduler pool slot`, and the shell stays
  responsive; the full 12-gate shared-seam live sweep + the args + kill
  gates are green.
- **[Claim 5795, milestone-four follow-on 3, card 3g — the pool-scale
  capstone]** — every prior card documented the 5-slot budget (3b/3c/3f:
  "5/5, NO spare"; 3a/3e: one spare). This card DELIBERATELY raises the
  scheduler pool `max_tasks` 5 → 7 (`idle_id` stays `max_tasks - 1`) and
  re-derives the gates: shell + worker + FOUR EL0t user slots + idle
  (the 4th user slot is the "spare" while only three are live). A BUDGET
  change only — ADR 0007, the switching core, the lifecycle states, and
  the ring mechanics untouched; the pool is a BSS array (no allocation).
  The page-table carve-out survey (kernel root + 4 user roots,
  `addrspaces: tables=NN/256`) keeps the roots well inside the 256-page
  budget (observed 150/256). Every capacity assertion re-derives: the
  exec/scheduler host tests (`pool_full` at the new budget, exact
  free-counts on the refused path), the transcript fixture (`tasks:
  pool=4/5` → `pool=4/7`), and the live gates (args/ipc's `pool_full`
  moves to the FIFTH exec at 7/7; long-lived's ending becomes the
  one-spare scenario — counter + two users + spare — with the page
  counts differing by exactly the second program's 5 pages). The new
  class-B gate `tools/verify-live-scale.sh` PASS 1/1 on VZ: `exec
  COUNTER.BIN` + `exec USER.BIN` ×3 back to back — FOUR `state=running`
  user rows with distinct task ids + stack VAs, the programs' markers
  interleaving with the worker's advances across the whole log, a FIFTH
  exec `pool_full` (7/7 — shell + worker + 4 users + idle),
  `addrspaces: tables=150/256`, the counter still running at the final
  procs; the full shared-seam sweep re-derived against the 7-slot pool:
  12-gate sweep + args + kill + ipc all PASS 1/1.
- **[Claim 5799, milestone-four follow-on 4, card 4a — process
  observability]** — the process registry exists (claim 3848) but only
  the EL1h monitor can read it; this card gives EL0 a READ-ONLY view:
  `sys_procs(buf, max)` = slot 7 (ADR 0007 amendment — the card's ONE
  ABI change, `implemented_count` 7 → 8, `syscalls` rows 0–7) copies a
  bounded snapshot of the process table (one fixed 40-byte row per
  non-free descriptor: u64 pid, u64 state code, u64 exit status,
  name[16] NUL-padded) out into the caller's region through uaccess,
  `max` truncating to whole rows (a documented truncation result like
  the ipc recv path), marshaled into a fixed BSS scratch — no
  allocation. PEER.BIN (reused — the pool stays 7/7) polls `sys_procs`
  once per quantum until it sees a running peer, then prints
  `peer: sees <pid> <name> <state>` per row (including the exited boot
  payload's row) and falls into its existing recv loop. The new class-B
  gate `tools/verify-live-procs-syscall.sh` PASS 1/1 on VZ: the peer's
  `peer: sees 2 COUNTER.BIN running` row proves the counter is visible
  FROM EL0 — distinct from the monitor's `procs` read — the IPC flow
  still echoes, both processes never exit; the full 12-gate shared-seam
  sweep + the args/kill/ipc/scale gates all PASS 1/1.
- **[Claim 3179, milestone-four follow-on 4, card 4b — IPC depth]** —
  the card-3f mailbox is 4 × 64 B per process, so a bursty flow (more
  than 4 sends before the peer drains) would refuse with ENOSPC. This
  card raises `mailbox.max_messages` 4 → 8 (the per-process ring grows
  256 → 512 B of fixed BSS) as a DATA-PATH CONSTANT — NOT a syscall
  number (ADR 0007 documents the choice; the follow-on-4 set's ABI
  amendments are ONLY slots 7/8, on cards 4a/4c). The truncation
  contract is unchanged: a message > 64 B still truncates at the slot
  bound, a full ring still refuses with the same `ENOSPC` -5 (now at the
  9th send), the same empty → 0 recv, the same drain invariant
  `sent − recv == pending ≤ capacity`, the same cross-process isolation.
  COUNTER.BIN's send cadence becomes a BURST: every 6th iteration it
  sends 6 messages back-to-back in ONE quantum, then 5 quiet iterations
  (the peer drains 1 per round — the ring peaks at 6 of the 8 slots and
  drains to 0 before the next burst: NO ENOSPC, deterministically); each
  send checks its return and prints a distinct `ipc: enospc` marker on
  failure. The re-derived class-B gate `tools/verify-live-ipc.sh` PASS
  1/1 on VZ: the counter's 6-message bursts (`ipc: ping N` … `ipc: ping
  N+5` back-to-back) interleave with the peer's byte-exact echoes, ZERO
  `ipc: enospc` lines, the log's peak (sends − echoes) = 6 (> 4
  messages queued at once, never over the re-derived 8-slot bound), the
  `mbox` snapshot shows the peer's ring drained at the new capacity
  (pending ≤ 8, sent − recv == pending) and the counter's empty, both
  never exit, a fifth exec is `pool_full` at 7/7; the full 12-gate
  shared-seam sweep + the args/kill/scale/procs-syscall gates all PASS
  1/1.
- **[Claim 9946, milestone-four follow-on 4, card 4c — exit-status
  propagation]** — the process table is observable FROM EL0 (4a) and
  the mailbox flows deeper (4b), but a process still cannot WAIT on a
  peer: the exit status of another process is visible only through the
  EL1h monitor. This card lands `sys_wait(target)` = slot 8 (ADR 0007
  amendment — the follow-on-4 set's explicit slots 7/8 change,
  `implemented_count` 8 → 9, `syscalls` rows 0–8): the caller blocks
  until the target process exits and returns its status — bounded,
  kernel-owned, NOT POSIX wait (no zombies, no fds). A running target
  parks the caller through the claim-0635 sleep seam
  (`scheduler.wait_current` — the SVC frame stays on the caller's
  kernel stack), and the exit path's `wake_waiters` flips the task back
  to `ready` while patching the observed status into the saved frame's
  x0, so the syscall return lands when the ring resumes it; an
  already-exited target returns its stored status immediately; EINVAL
  for a non-process caller, a free/out-of-range target, a `created`
  (loaded, not yet running) target, or a self-wait (the refused
  deadlock). The block is event-driven — the tick clock never wakes a
  waiter. A THIRD program STATUS43.BIN (`user/src/status43.zig`, a
  fourth ESP image through the same build pipeline) prints its alive
  marker, sleeps 6 scheduler ticks (a deterministic window), then exits
  43; COUNTER.BIN exec'd with the wait target in its argv (slot 8)
  prints `ipc: waiting pid=<n>`, blocks, and prints `ipc: saw pid=<n>
  status=<s>` on wake — the EL0-side proof of the propagation. The new
  class-B gate `tools/verify-live-wait.sh` PASS 1/1 on VZ: the
  phase-2 `tasks` snapshot shows TWO `state=blocked` user-exec rows
  (the sleeping STATUS43 + the waiting counter) while `procs` still
  shows STATUS43 `state=running` — the target ALIVE while the waiter is
  blocked — then `ipc: saw pid=1 status=43` agreeing with the kernel's
  `tasks user-exec exited status=43` / `procs STATUS43.BIN exited
  status=43` records; the full 12-gate shared-seam sweep + the
  args/kill/ipc/scale/procs-syscall gates all PASS 1/1.
- **Network stack (in progress — N1 + N2 + N3 + N4 landed 2026-08-11, claims 1373/6076/7293/0148).** The
  last "Eventually" item, and the one the virtio surface table below maps
  to. The transport it needs was already proven (virtio
  console/blk/entropy/custom drivers: discovery, queues, IRQ delivery,
  post-exit re-arm), the runner change was one config line
  (`config.networkDevices`, now flag-gated behind `--net <capture>`),
  and **N1 — the virtio-net TRANSPORT + TX — is DONE** (claim 1373,
  branch `agent/buffy/m5-net-tx`): the guest's `kernel/src/virtio_net.zig`
  discovers the device (DID 0x1041 — the modern spec DID confirmed on
  VZ), negotiates features (claim-time finding: the device NEEDS
  `VIRTIO_NET_F_MTU` accepted — VER1-only and VER1\|MAC masks are
  rejected with FEATURES_OK cleared), reads the host-set MAC via the
  feature path, arms queues 0 (RX) + 1 (TX), re-arms post-exit
  (claim-time finding: the net device does NOT reset at
  ExitBootServices, unlike blk/entropy), prepends the 12-byte
  virtio_net_hdr the device consumes on every TX buffer (observed
  contract), and `netsend` drives TX end to end with bounded BSS staging
  and polled used-ring drain. `net`/`netsend` monitor commands; live
  gate `tools/verify-live-net-tx.sh` PASS 2/2 (byte-exact host
  captures: 46-byte known frame, ring reuse, honest truncation). Card
  order:
  - ~~**N1 — virtio-net transport + TX.**~~ **DONE 2026-08-11 (claim
    1373).** Runner attaches `VZVirtioNetworkDeviceConfiguration` under
    the flag-gated `--net <capture-file>` mode;
    `VZFileHandleNetworkDeviceAttachment` gives the deterministic gates
    (host reads exact Ethernet frames, like the custom-virtio spike),
    with a FIXED host MAC (02:00:00:00:00:01) the guest reads via the
    feature path; `VZNATNetworkDeviceAttachment` for real outbound
    connectivity stays a later card's option. Guest
    `kernel/src/virtio_net.zig`: discover the device (modern virtio-net
    DID 0x1041 — confirmed at claim time), post-exit re-arm (the
    claim-6420/2665 lesson; the net device does not reset — observed
    st=0f), MAC via VIRTIO_NET_F_MAC negotiation (worked — the fallback
    is the fixed BSS MAC), TX + RX queues, bounded frame staging (no
    heap), 12-byte virtio_net_hdr prepended (observed contract). `net`
    monitor command (device/DID/MAC/queues/features); `netsend` proving
    the host receives known frames byte-exact. Live gate
    `tools/verify-live-net-tx.sh` PASS 2/2.
  - ~~**N2 — raw Ethernet RX.**~~ **DONE 2026-08-11 (claim 6076).**
    Queue 0 supplied with one fixed BSS buffer, used-ring drain into a
    bounded 4-slot frame FIFO (card-3d push/drain pattern), MAC filtering
    (own MAC + broadcast, drop the rest with a counter), `net recv`
    prints the frame byte-exact. The host injects a known frame via the
    runner's `--net-inject <file>` (a serial trigger, not a sleep) and
    the guest receives it and re-sends the SAME bytes — raw Ethernet
    frames back and forth. Live gate `tools/verify-live-net-rx.sh` PASS
    3/3 (broadcast round trip + byte-exact capture, own-MAC receive,
    foreign-MAC drop); claim-time observations pinned in the hardware
    contract: the device writes a 12-byte virtio_net_hdr into RX buffers
    (num_buffers=1, the RX-header question answered) and REFUSES an RX
    buffer under 1530 bytes; the used-buffer IRQ line is not yet
    observed — drain is polled.
  - **N3 — ARP.** Resolve peers (send requests, parse replies) and answer
    requests for our protocol address. Static IP first (`net ip
    <a.b.c.d>`, bounded, no config heap); DHCP is a later card. Live
    gate: the host ARPs for the guest IP and the reply carries the right
    MAC; the guest resolves the host's MAC from a crafted reply. **LIVE
    2026-08-11 (claim 7293)** — `kernel/src/arp.zig` (pure RFC 826 logic:
    static IP, build request/reply, bounded 4-slot table, counters) wired
    into the RX drain (answer requests for our IP, learn replies, drop
    the rest) + `net ip`/`net arp` subcommands + the runner's
    `--net-arp-respond <host-ip>` (deterministic host-side answer, OFF by
    default). Live gate `tools/verify-live-net-arp.sh` PASS 3/3 (answer
    a request for our IP — 42-byte reply byte-exact in the capture;
    resolve a peer — request byte-exact in the capture + the host answer
    lands in the table; a foreign-address request is dropped with a
    counter while still observable via `net recv`). Observed: the device
    delivers/transmits the 42-byte ARP frames unpadded (below the
    Ethernet 60-byte minimum).
  - **N4 — IPv4.** Minimal IPv4 TX/RX with ones-complement checksums
    (host-testable); ICMP echo as the proof — the guest answers echo
    requests and can send its own; honest bounds: no fragmentation, no
    reassembly (drop fragments, documented). Live gate: the file-handle
    host sends an ICMP echo request to the guest IP and the reply is
    byte-exact; with NAT attached, the guest pings an outbound address.
    **LIVE 2026-08-11 (claim 0148)** — `kernel/src/ipv4.zig` (pure RFC
    791/792 logic: RFC 1071 checksums, parse/build, ICMP echo
    request/reply byte-exact, fragments dropped counted — no
    reassembly) wired into the RX drain BESIDE the ARP dispatch (answer
    an echo for our static IP, observe echo replies — pong + seq, drop
    the rest counted) + `net ping <a.b.c.d>` subcommand + the runner's
    `--net-icmp-respond <host-ip>` (deterministic host-side echo
    answer, OFF by default). Live gate
    `tools/verify-live-net-icmp.sh` PASS 3/3 (answer an injected echo
    request — the 46-byte reply is byte-exact in the capture with the
    identification + id/seq/payload echoed; ping a peer — resolve +
    echo request byte-exact in the capture and the host's answer lands
    as pong=1 with seq=1; a foreign-address echo request is dropped
    with a counter while still observable via `net recv`).
  - **Later, sketched only:** UDP datagrams behind a bounded syscall seam
    (an ADR 0007 amendment), DHCP, loopback, then TCP — far future, and
    the "only when the ones below it are demonstrably working" rule
    applies at every rung. The driver starts single-CPU (boot CPU, the
    claim-9187/0828 IRQ pattern); SMP is a separate future card.

**The virtio device surface — where the OS meets the host.** Every virtio
device VZ can attach maps to a host configuration class in
`host/vm-runner/Sources/VMRunner/main.swift` and, where driven, a guest
driver under `kernel/src/`. Five of the seven are done and live-gated; the
remaining two (graphics, balloon) are the open milestones.

| Device (guest-observed DID) | VZ host surface | Guest driver | Status | Claims / evidence |
|---|---|---|---|---|
| Console (0x1043) | `VZVirtioConsoleDeviceSerialPortConfiguration` (serial attachment) | `virtio_console.zig` — queue 1 TX + queue 0 RX | ✅ done | 0013 (device identity), 1517 (post-MMU TX), 6684 (live RX transcript) |
| Block (0x1042) | `VZVirtioBlockDeviceConfiguration` (disk image attachment) | `virtio_blk.zig` — modern virtio-blk, post-exit re-arm | ✅ done | 6420 (FAT32 storage driver), 3678 (general non-ESP FS on top) |
| Entropy (0x1044) | `VZVirtioEntropyDeviceConfiguration` | `virtio_entropy.zig` (boot-time 64-byte seed) + `csprng.zig` (ChaCha20, RFC 7539) | ✅ done | 2665 (driver + CSPRNG + `random`), 3693 (EL0 stack ASLR consumer) |
| Custom virtio (0x1082, macOS 27) | `VZCustomVirtioDeviceConfiguration` (`--custom-virtio` / `zig build spike-virtio`) | `virtio_custom.zig` — queue transport + used-ring IRQ | ✅ done | 5844 (host spike + `pci` command), 0828 (bidirectional queue + SPI IRQ), 4374 (ring allocator / multi-queue), 9492 (multi-descriptor payloads), 9737 (feature negotiation), 4837 (log transport) |
| Network (0x1041) | `VZVirtioNetworkDeviceConfiguration` + `VZFileHandleNetworkDeviceAttachment` (`--net <capture-file>`, `--net-inject <file>`, `--net-arp-respond <host-ip>`, `--net-icmp-respond <host-ip>`, flag-gated; fixed host MAC) | `virtio_net.zig` — TX + RX + ARP + ICMP (N1 + N2 + N3 + N4); `arp.zig`; `ipv4.zig` | ✅ TX + RX + ARP + ICMP (claims 1373/6076/7293/0148) | 1373 (transport + TX live — DID 0x1041, VER1\|MTU\|MAC, feature-path MAC, queues 0/1, 12-byte TX-hdr contract, byte-exact host capture; `verify-live-net-tx.sh` PASS 2/2); 6076 (RX live — queue-0 buffer supply, polled used-ring drain, bounded FIFO, MAC filter, `net recv`; host→guest injection + the round trip; 12-byte RX-hdr observed, min RX buffer 1530 observed; `verify-live-net-rx.sh` PASS 3/3 + 29-gate aggregate green); 7293 (ARP live — static IP, answer/resolve over the RX seam, bounded table, `--net-arp-respond`; 42-byte frames unpadded observed; `verify-live-net-arp.sh` PASS 3/3 + 31-gate aggregate green); 0148 (IPv4/ICMP live — RFC 1071 checksums, echo answer/observe over the RX seam, `net ping`, `--net-icmp-respond`; the 46-byte frames travel unpadded, consistent with the N3 observation; `verify-live-net-icmp.sh` PASS 3/3 + 32-gate aggregate green) |
| Graphics | `VZVirtioGraphicsDeviceConfiguration` — attached only for screenshots (`--screenshot`) | none | ⬜ not started — the future GUI milestone | — |
| Balloon | `VZMemoryBalloonDeviceConfiguration` — nothing attached | none | ⬜ not started — low priority (fixed 256 MiB guest, no demand paging) | — |

Each milestone must state what was **observed** versus **inferred** and must
record new hardware assumptions in `docs/hardware-contract.md`.
