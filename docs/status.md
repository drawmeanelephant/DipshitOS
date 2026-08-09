# DipshitOS living status, goals & changelog

> **Host identity:** Apple silicon only — hosted by Apple's
> Virtualization.framework; **not Linux, not Unix, not QEMU** (see
> `AGENTS.md`).

> This file is the project's **living status tracker** and its **multiagent
> coordination surface**: where we are, what we are trying to build next, how
> far along each step is, **who currently claims which piece of work**, and
> pointers to the append-only per-branch changelog. Claims and logs are
> sharded (see [Multiagent coordination](#multiagent-coordination)) so
> parallel agents never collide on one file. Update it as work lands —
> flip the checkboxes, fill in the notes, and **append** to your branch's
> log under `docs/logs/`.
> Claims stay honest per `AGENTS.md`: **observed** (log evidence under
> `artifacts/`) versus **inferred** (reasoning/docs only).

> **Premise check (2026-08-06):** this tracker was first frozen against the
> milestone-one-era `main`. On the same day, PRs #6/#7 merged the
> **milestone-two kernel proper** (ADR 0004), which changed the premises
> below: the kernel now calls `ExitBootServices`, owns an identity-map MMU,
> drives a polled TX-only MMIO serial console, and never returns. This file
> was refreshed accordingly — the plan's shape is kept, its factual anchors
> are reconciled with the merged state. PR #10 later unified this tracker
> with the milestone-two gate evidence and added the multiagent changelog
> (now sharded per branch under [docs/logs/](logs/README.md); see the
> [Changelog](#changelog-append-only-per-branch)).

## Current position

| Milestone | What it proved / is | Status |
|-----------|---------------------|--------|
| Zero — boot pipeline | A Zig AArch64 UEFI app on a FAT32 ESP boots under real firmware; output observed on host (`\BOOTED.TXT`) | ✅ done |
| One — kernel handoff | Separate freestanding `KERNEL.BIN` loaded, cache-maintained, jumped to, and returned (`\RC.TXT` = `kernel_rc=0x0`); ADR 0002 | ✅ done |
| Two — kernel proper | ExitBootServices, captured EFI map, identity TTBR0_EL1 tables, MMIO serial probe + polled TX console (ADR 0004) | ✅ **gates passed 2026-08-08** (claim 1517): bad-handoff failure gate passing since 2026-08-06, VZ serial gate now **passing** (post-MMU virtio TX fixed) |
| **1.5 — Interactive Kernel Monitor ("Dipshit Monitor")** | A live, interactive command monitor served by the kernel's serial console (the milestone-two terminal loop becomes its payload) | ✅ **done 2026-08-09** — all 7 hard gates pass; the last (filesystem, claim 3475) closed 2026-08-09 and upgraded to a real FAT32 storage driver (claim 6420); tagged `m1.5-interactive-monitor` |
| Three — allocator, interrupts, tasks | Physical allocator, GIC + timer, then tasks | 🚧 **active** — allocator done (claims 3972/5162); a real periodic timer PPI now reaches the EL1 IRQ vector on VZ (claim 9187, 3/3); tasks are next |

Resolved loose end: the milestone-one `KERNEL.TXT` corruption is **fixed**
(ADR 0002 — the loader now places image content at `base+0`; the write is
byte-perfect and gated by `zig build run`).

## Gate status

Every gate below is backed by evidence re-verified
2026-08-07 (full suite re-run on merged `main` 4702548,
`artifacts/status-reverify-20260807.txt`) and re-run again at HEAD
`5160eef` on 2026-08-08 (claim 8592 preflight, `artifacts/status-preflight-*.txt`),
and re-run at the newest HEAD `076ddf1` on 2026-08-08 (claim 8073,
`artifacts/gates-reverify-20260808-076ddf1.txt` — all class A gates plus
the primary VZ serial gate), **and re-run in full at the
`m1.5-interactive-monitor` tag (`74a51f3`) on 2026-08-09 (claim 7873,
`artifacts/gates-reverify-20260809-m15-tag.txt` — the complete class A
set plus the complete class B set: serial takeover, bad-handoff, marker,
nvram-console, host-console, live-transcript, live-fs, live-timer,
live-reboot, live-exceptions); all green** — **and re-run again at the
newest HEAD `706712c` on 2026-08-09 (claim 2233,
`artifacts/gates-reverify-20260809-706712c.txt` — class A 11/11, class B
10/10: serial takeover, bad-handoff `kernel_rc=0x2`, marker ladder to
`M2_TXOK!`, nvram-console, host-console, live-transcript RX 1/1, live-fs
persistence pair 1/1, live-timer 1/1, live-reboot 2/2, live-exceptions
1/1; all green)**; files under `artifacts/`.

| Gate | Command | Result | Last evidence |
|------|---------|--------|---------------|
| Format | `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` | ✅ pass | re-run 2026-08-08 (preflight); re-verified at `076ddf1` (claim 8073) |
| Guest build | `zig build` | ✅ pass | re-run 2026-08-08 (preflight); re-verified at `076ddf1` (claim 8073) |
| Disk image | `zig build image` | ✅ pass | re-run 2026-08-08 (preflight); re-verified at `076ddf1` (claim 8073) |
| Binary + image inspect | `zig build inspect` | ✅ pass | re-run 2026-08-08 (preflight); re-verified at `076ddf1` (claim 8073) |
| Swift runner build | `swift build --package-path host/vm-runner` | ✅ pass | re-run 2026-08-08 (preflight); re-verified at `076ddf1` (claim 8073) |
| Context snapshot | `zig build context` | ✅ pass | re-run 2026-08-08 (preflight); re-verified at `076ddf1` (claim 8073) |
| **VZ serial gate** | `zig build run` | ✅ **PASS 2026-08-08** | banner `DipshitOS kernel has seized control.` + `memory-map descriptors=0x…` + `kernel terminal state` in `vm-serial.log` (claim 1517; artifacts under `artifacts/`). **Re-verified live at `076ddf1` (claim 8073):** banner + 27-descriptor map (`key=0x2c4`) + `dipshit>` prompt in `artifacts/vm-serial.log`, runner exit 0. **Re-verified live at `706712c` (claim 2233):** banner + 27-descriptor map (`key=0x2d4`) + `dipshit>` prompt, runner exit 0. Root cause was the translation start-level mismatch (claims 6460/7896); fixed in production with T0SZ=16 + `tlbi vmalle1` at the switch. Historical blocker detail (claims 0013/0018/0020): console is a virtio-pci device (bus 0 D5 `0x1af4/0x1043`), transport armed pre-exit, first post-switch BAR/common-config read did not return |
| **Live transcript / RX gate** | `bash tools/verify-live-transcript.sh` | ✅ **PASS 2026-08-08** | host scripted keystrokes reach the kernel end to end through the polled virtio receive queue and the live `dipshit>` transcript is asserted in `vm-serial.log` (claim 6684, 3/3 boots; artifacts `live-transcript-*`) |
| **Live exception-vector gate** | `bash tools/verify-live-exceptions.sh` | ✅ **PASS 2026-08-08** | VBAR_EL1 vectors installed; `dipshit> fault` triggers a real synchronous exception (`udf`) that the handler reports (`[EXC] sync from EL1t`, `ec=0x00 unknown-reason`, ESR/FAR/ELR/SPSR) and resumes — shell continues (`fault: handled, resumed after faulting instruction` → follow-up `echo` reply), 2/2 boots (claim 9746; artifacts `live-exceptions-*`) |
| **Live timer IRQ gate** | `bash tools/verify-live-timer.sh` | ✅ **PASS 2026-08-09** | **Real IRQ delivery observed, 3/3 boots (claim 9187):** GICv3 (`GICD` @ `0x10000000`, `GICR`/active frame @ `0x10010000`) + CNTP (24 MHz, GTDT level-triggered PPI 30); each serial log contains `timer irq delivered ppi=0x1e irq_ticks=1` and `timer heartbeat ticks=5 irq=5 poll=0`, with a follow-up shell reply. Claim 7948's platform-blocker conclusion was invalidated by a delivery-blocking guest bug: SGI/PPI MMIO aimed at the RD frame instead of its `+0x10000` SGI frame. The audit also corrected shifted MADT GIC IDs and the wrong ICFGR field bit. Artifacts: `live-timer-*`; Xcode 27 host-surface audit: `vz-irq-api-audit.txt` |
| **Live reboot/shutdown gate** | `bash tools/verify-live-reboot.sh` | ✅ **PASS 2026-08-08** | hard gate 6 closed — a real EFI `ResetSystem` from a live `dipshit>` shell observed end to end (claim 0527, 4/4 boots): `reboot` reset the machine (second full takeover + fresh map key in `vm-serial.log`), `shutdown` powered it off (runner reports VM state → stopped); artifacts `live-reboot-*`. The claim-0011 `M2_RST!` marker write is scanned + reported but is best-effort by design (lost in the teardown race; the machine-level effect is the evidence) |
| **Live FAT32 storage gate** (fs hard gate) | `bash tools/verify-live-fs.sh` | ✅ **PASS 2026-08-09** | **hard gate 5 closed, upgraded to a real FAT driver (claim 6420, 1/1 pair)** — `ls`/`cat`/`write` persist through reboot **on the disk itself**: run A wrote `hello world` to the ESP's FAT volume via the virtio-blk transport (write-ok, `hello.txt [esp]` listed, cat reply) and run B — a fresh boot against the **same disk image** — still listed `HELLO.TXT [esp]` (the FAT 8.3 short name) and printed the content. The volume lists the loader's per-boot files too (`EFI/`, `KERNEL.BIN`, `BOOTED.TXT`, `MEMMAP.TXT`, `LOADER.TXT`). Two hardware discoveries landed in the claim: VZ presents virtio-blk as **DID 0x1042** (not the spec's 0x1041), and **resets the device at ExitBootServices** — the queue is re-armed post-MMU (`blk_rearm`, common-config MMIO writes verified DRIVER_OK). NVRAM variables are no longer the persistence medium; artifacts `live-fs-*` |
| **Bad-handoff failure gate** | `bash tools/verify-bad-handoff.sh` | ✅ **pass** | `artifacts/m2-badhandoff-fix-after.txt`: `RC.TXT` → `kernel_rc=0x0000000000000002`, gate exits 0 (first observed 2026-08-06, fixed shim) |
| **Marker fallback gate** (gate work item 3) | `bash tools/verify-marker.sh` | ✅ **pass** | `artifacts/m2-marker-gate.txt` (2026-08-07, re-verified `artifacts/m2-marker-reverify-20260807.txt`): NVRAM ladder `M2_ENTRY → … → M2_MAPD! → M2_MMUP! → M2_SERIA → M2_READY` — identity-map switch completes and probe/transport are reached (see [gate work item 3](#immediate-gate-work-prerequisites-for-m15), claims 0009/0010/0013) |
| **MMU-takeover root cause & fix** (claim 0010) | `bash tools/verify-marker.sh` | ✅ **fixed 2026-08-07** | ladder now advances `M2_MAPD! → M2_MMUP! → M2_SERIA` — the identity-map switch **completes** on VZ for the first time (`artifacts/m2-mmu-takeover-gate.txt`; see claim 0010) |
| **VZ serial console discovery** (claim 0013) | pre-exit probe + NVRAM dump | ✅ **discovered 2026-08-07** | console = modern virtio-pci (bus 0 D5 `VID=0x1af4 DID=0x1043 class=0x078000`), ECAM `0x40000000`, BAR0 (64-bit) @ `0x100010000`, transport decoded + armed pre-exit (`SEL=VIRTIO`, ladder `M2_READY`); declared MMIO windows decoded as Apple efivars store + internal debug UART. Gate blocked at the time (post-MMU transport access hung, claims 0018/0020) — **resolved by claim 1517** (T0SZ=16 + TLBI at the switch) |
| **NVRAM console channel** (claim 0015) | `bash tools/verify-nvram-console.sh` | ✅ **PASS 2026-08-07** | **first post-exit console bytes from a real VZ run**: 69–70 chunks reconstructed from `efi-vars.bin` — takeover banner, full memory map, probe record, shell banner, and real `version`/`mem`/`echo`/`help` command output (`artifacts/nvram-console-gate.txt`). Found + fixed a latent kernel bug on the way (ADR 0005: const function-pointer tables are not relocated by the flat loader — the first vtable dispatch on real hardware faulted; tables now built at runtime in BSS). See [Current blocker](#current-blocker-canonical--one-description-one-ordering) |

### Current blocker (canonical — one description, one ordering)

> **RESOLVED 2026-08-08 (claims 1517 + 6684 + 0527).** The post-MMU virtio TX
> blocker is fixed in production (claim 1517: T0SZ=16 + TLBI at the switch
> — the start-level mismatch from claims 6460/7896) **and the RX path is
> live** (claim 6684: the polled virtio receive queue delivers host
> keystrokes end to end — `bash tools/verify-live-transcript.sh` asserts
> the real `dipshit>` transcript in `vm-serial.log`, 3/3 boots) **and the
> live reboot/shutdown observation is done** (claim 0527: `reboot`
> resets the machine, `shutdown` powers it off — 4/4 boots via
> `bash tools/verify-live-reboot.sh`) **and the filesystem gate is closed**
> (claim 6420: `ls`/`cat`/`write` persist through reboot on the real disk
> via the FAT32 storage driver, `verify-live-fs.sh`, 1/1 pair).
> **Every M1.5 hard gate now passes** (all 7 closed; the last — the
> deferred filesystem one — closed 2026-08-09 by claim 3475 and upgraded
> to a real FAT driver by claim 6420). The post-M1.5 allocator and timer
> interrupt cards are now complete (claims 3972/5162/9187); tasks are next.

**Historical blocker (superseded by claim 1517):** reliable post-MMU access to the already-discovered virtio-pci console transport (class B) was required before live RX and a real interactive `dipshit>` session. The console is a modern virtio-pci device (bus 0 D5 `0x1af4/0x1043`, BAR0 `0x100010000`, claim 0013); the transport arms pre-exit (`M2_READY`) and TX works pre-exit (claim 0017) and post-ExitBootServices on the firmware translation (claim 0020 phase B), but **hung on the first post-MMU BAR/common-config read after the DipshitOS identity-map install** (claims 0018/0020, phase C/D). ExitBootServices itself is exonerated; the MMU switch (B→C) was the transition that destroyed access (claim 0020). Firmware and kernel memory attributes are byte-identical (claim 0021), so the hang was not an attribute mismatch; the no-TLBI safety contract and its validity window were in **ADR 0006** (claim 0022; superseded by claim 1517). The **NVRAM fallback console (claim 0015)** carried post-exit bytes via runtime `SetVariable` (69–70 chunks, shell + commands observed) but is not the virtio serial pipe; the **mock transcript (`zig build test-console`, class A)** is a portable host test, not VZ hardware. Ordering remains explicit: **post-MMU virtio TX (done, claim 1517), then virtio RX / live transcript** — RX cannot bypass the TX/MMU layer. Claims 6460/7896 characterized the layer: correcting the T0SZ start-level mismatch (25→16) restored end-to-end post-MMU TX in 6/18 boots, and the 4-cell walk-probe matrix proved the residual was stale-TLB interference, not a device hang — cell B (T0SZ=16 + TLBI) completed 9/9, which is exactly what claim 1517 makes production (see `docs/gate-inventory.md`). Class definitions: `docs/gate-inventory.md` (class A = portable/CI, class B = Apple-silicon/VZ hardware, class C = interactive, class D = diagnostic); a green CI badge proves class A only.

Re-verified marker/host gates on merged `main` (2026-08-07): host-console gate ✅ `artifacts/m15-host-console-reverify-20260807.txt`; marker re-verify ladder `M2_ENTRY → … → M2_READY` (`artifacts/m2-marker-reverify-20260807.txt`); bad-handoff re-verify ✅ `artifacts/m2-badhandoff-reverify-20260807.txt`.

### What we directly observe about the serial gate and the bad-handoff fix

From the bad-handoff run before the fix (re-verified 2026-08-06), fresh from
`artifacts/bad-handoff.img`:

- `BOOTED.TXT` — written by the loader: **observed** (loader executed under
  firmware).
- `LOADER.TXT` — written by the loader: **observed** —
  `base=0x7e4df000 size=0x823e8 entry_offset=0x18`, and
  `ram_first8=0xaa0103eaaa0003e9`, which decodes to `mov x9, x0; mov x10, x1` —
  the first two instructions of the kernel's naked shim. The image content is
  at `base+0` and the jump lands on the shim as designed.
- `RC.TXT` — **absent** before the fix: the kernel never returned to the
  loader. `vm-serial.log` is empty (expected for `ConOut`; the runner's
  `terminal=true` is only the no-marker default).

**Bad-handoff root cause (now observed, fixed 2026-08-06):** the naked
`_start` shim's `bl kernel_main` overwrote the link register with the shim's
own return address (disassembly of the current kernel ELF: `bl 0x3c` at
shim offset `0x30`, so LR = `0x34`). The shim's final `ret` therefore looped
`0x34 → 0x38 → 0x34` forever instead of returning to the loader, so the
pre-exit `return bad_handoff` could never reach the loader and `RC.TXT` was
never written. Fix: save the loader's `x30` in `x20` (callee-saved under
AAPCS64, preserved by `kernel_main`) before the `bl` and restore it before
`ret` — two instructions in `kernel/src/main.zig` `_start`. After the fix:
`RC.TXT` = `kernel_rc=0x0000000000000002` and `verify-bad-handoff.sh` exits 0
(`artifacts/m2-badhandoff-fix-after.txt`).

The **VZ serial gate is a separate, still-open question**: with the fix, the
bad-handoff VM provably returns through the shim, but every good-path run
still produces no serial output and the kernel never returns. Re-run
2026-08-06 21:19 (claim 0002, `artifacts/m2-vz-run-20260806.txt`):
`vm-serial.log` **0 bytes** after a 30 s run; loader evidence intact
(`BOOTED.TXT` exact content, `LOADER.TXT` `base=0x7e4df000 size=0x823e8
entry_offset=0x18`, `ram_first8=0xaa0103eaaa0003e9` = the shim's first two
instructions `mov x9,x0; mov x10,x1` — the loader→shim jump is proven);
`RC.TXT` absent (good path, expected — D6).

<details><summary>Historical — how the serial gate's silence was first explained (claim 0009, superseded by 0010/0013)</summary>

The ADR 0004 D4 marker fallback was implemented and its first VZ runs
ended at `M2_MAPD!` (claim 0009) — the ladder discriminated the death site
as the MMU-takeover window before the serial probe ever ran
(`artifacts/m2-marker-gate.txt`, historical). A diagnostic run with the
switch disabled showed `M2_MAPD! → M2_MMUP! → M2_SERIA` (`layout=none` halt).
Claim 0010 then root-caused and fixed this: the guest implements the
ARMv8.1+ TCR_EL1 layout (claim 0010; re-captured by 0021
`artifacts/fw-mmu-capture-lines.txt` — raw `m2-firmware-regs.txt` not in
this checkout), the identity map now covers undeclared MMIO as Device, and
the `tlbi vmalle1`-forced re-walk that faulted on VZ is dropped (see TLBI
bullets in `hardware-contract.md` and ADR 0006). The ladder now runs
`M2_MAPD! → M2_MMUP! → M2_SERIA` (`artifacts/m2-mmu-takeover-gate.txt`).
That "device absence in the declared windows" reading of `M2_SERIA` is
itself superseded by claim 0013 (declared windows are Apple's efivars store
+ debug UART; the real console is virtio-pci outside them). See
[Current blocker](#current-blocker-canonical--one-description-one-ordering) and [The device absence is now fully explained](#what-we-directly-observe-about-the-serial-gate-and-the-bad-handoff-fix).

Also observed (still current): the ADR 0004 D4 *memory-dump* form is
**impossible on VZ** — guest RAM is not host-mapped (claim 0009).

</details>

**The device absence is now fully explained (claim 0013, 2026-08-07).** The
console is not in the declared MMIO windows at all. Pre-exit diagnostics
persisted through the NVRAM channel (the probe dump variables `DipshitP*` in
`artifacts/efi-vars.bin`) decoded the ground truth: `0x01000000..0x01010000`
contains Apple's EFI variable-store region (raw bytes spell `efivars\0`),
and `0x20050000..0x20051000` is a PL011-family PrimeCell UART whose DR
writes produce zero bytes in `vm-serial.log` (Apple's internal EFI debug
UART). ACPI names no console (no SPCR/DBG2; the DSDT, Apple's own `Apple Vz`
AML, declares only `PCI0` + `efivars`). The VZ serial attachment is a
**modern virtio-pci console** — bus 0 device 5, `VID=0x1af4 DID=0x1043
class=0x078000` — found by pre-exit PCI enumeration over ECAM `0x40000000`
(MCFG). Its 64-bit BAR0 is firmware-assigned at `0x100010000` (above the
4 GiB identity-map blanket; assignment varies across boots, which is why the
fixed-window probe never saw it), and the transport is fully armed pre-exit
(`SEL=VIRTIO`, ladder reaches `M2_READY`). The remaining wall is **post-MMU access to the transport window hangs on
VZ** — the first post-switch BAR/common-config read does not return
(claims 0018/0020; the MMU switch is the killer, not ExitBootServices).
Claim 0015 then carried the console bytes over a post-exit-safe channel
(the runtime `SetVariable` NVRAM channel — next paragraph); the open work
is reliable post-MMU access to the transport (see
[Current blocker](#current-blocker-canonical--one-description-one-ordering)).

**The post-exit-safe channel is now live (claim 0015, 2026-08-07).** The
NVRAM console channel carries the kernel's console bytes over runtime
`SetVariable` after `ExitBootServices` (the channel claim 0009 proved
alive). `bash tools/verify-nvram-console.sh` **passes**: 69–70 chunks
reconstructed from `efi-vars.bin` give the takeover banner, the full
25-descriptor memory map, the probe record, the seam diagnostics, the
shell banner, and real command output (`version`, `mem`, `echo`, `help`)
— the first post-exit console evidence from a real VZ run
(`artifacts/nvram-console-gate.txt`, claim 0015). Two findings surfaced:

1. **Latent kernel bug fixed (ADR 0005):** the flat loader copies the
   kernel image to a runtime base with **no relocations**, so every `const`
   function-pointer table in `.rodata` (vtables, the 14-command registry,
   string-slice tables) held link-time absolute addresses. The first
   vtable dispatch on real hardware — claim 0015's shell seam — faulted
   instantly; host tests never caught it (macOS relocates test binaries).
   All such tables are now built at runtime in BSS.
2. **The NVRAM store is ~61 KiB writable, not 128 KiB** — the probe-dump
   variable was starving the chunk channel; it is gated off in nvram
   builds (the console stream carries the same evidence). The 64-chunk cap
   also truncated the session (the store still had ~47 KiB free); raised
   to 128.

The virtio-console TX gate (claim 0002, `zig build run`) was blocked at
that time (now **passing since claim 1517**); claim 0015 is the fallback
channel claim 0013 named, and it makes the
milestone's console evidence host-observable. The VZ post-exit death
window was flaky (claim 0009, re-observed: runs sometimes die at
`M2_MAPD!` or mid map-dump after `M2_TXOK!`); the gate retries up to 3
boots with fresh stores.

## Milestone 1.5 — the call

Do **not** add more kernel-proper plumbing before making the machine
interactive. The milestone-two kernel already owns the machine: it ends UEFI
Boot Services, installs its own page tables, probes the MMIO serial
candidates (PL011/16550/virtio-MMIO), and drives a polled **TX-only**
console (ADR 0004 — "no interrupts, no FIFO/DMA, no RX path") before
entering a terminal WFE loop. That console is exactly enough to serve an
interactive monitor — the monitor is simply the loop's payload. No new
firmware dependencies, no allocator, no interrupts, no storage drivers.

One immediate blocker, on both ends of the wire: the kernel console has **no
RX path at all** (ADR 0004), and until 2026-08-06 the VM runner's serial
attachment sent guest output to a file with a `nil` host-to-guest input
handle (`VZFileHandleSerialPortAttachment(fileHandleForReading: nil, ...)`
in `host/vm-runner/Sources/VMRunner/main.swift`). The M1.5 host-plumbing
slice (steps 4–7, landed 2026-08-06) added a `--console` mode that wires a
real stdin-backed input handle and tees guest output live; the evidence
path (`zig build run`) keeps the `nil`-input attachment, unchanged. Until
keystrokes can actually be read by the guest, the monitor is output-only.

### Definition of done — the target screen

```text
DIPSHITOS 0.1
AArch64 firmware-assisted kernel monitor
256 MiB detected
Type 'help' before touching anything expensive.

dipshit> help
about      explain this questionable system
cat        print a file from the ESP
clear      clean up the crime scene
echo       repeat your regrettable decisions
elephant   operational mascot diagnostics
handoff    display boot-to-kernel ABI data
ls         list files on the ESP
mem        summarize the EFI memory map
reboot     restart the machine
shutdown   request power-off
version    display build information
write      write text to a file

dipshit>
```

### Hard gates (acceptance criteria)

- [x] `zig build`, `zig build image`, and the existing regression checks still pass. *(The bad-handoff regression gate was **failing**; its root cause (shim LR clobber) was fixed 2026-08-06 — the gate now passes, see [Gate status](#gate-status).)*
- [x] `zig build console` reaches `dipshit>` — the post-MMU TX fix (claim 1517) puts the live banner + `dipshit>` prompt in `vm-serial.log` on real VZ runs.
- [x] Host keystrokes reach the kernel (RX path closed end to end) — **PASS 2026-08-08 (claim 6684)**: the polled virtio receive queue delivers host keystrokes; `verify-live-transcript.sh` drives `help`/`version`/`mem`/`echo` into a live session and asserts the replies in `vm-serial.log` (3/3 boots).
- [x] At least ten commands work (20 commands, host-tested; real command output observed post-exit via the NVRAM channel, claim 0015, and live post-MMU via claim 1517).
- [x] `ls`, `cat`, and `write` persist through reboot — **PASS 2026-08-09, upgraded to a real FAT storage driver (claim 6420)**: claim 3475's pre-exit snapshot + NVRAM persistence (passing 1/1) is **replaced** by a live FAT32 driver on the ESP (`kernel/src/fat.zig` — GPT + FAT32 mount/list/read/write with injected sector I/O, 11 host tests) over a virtio-blk transport (`kernel/src/virtio_blk.zig` — DID 0x1042 on this VZ, not the spec's 0x1041; queue 4, one request at a time). `write` now allocates clusters, updates both FAT copies, and writes the directory entry to the **disk itself**; run A persisted `hello world` and listed it `[esp]`, and run B — a fresh boot against the same disk image — still lists `HELLO.TXT [esp]` (the FAT 8.3 short name) and prints the content. **Hardware discovery fixed on the way:** VZ resets the virtio-blk device at ExitBootServices (its status reads 0 post-exit), so the queue is re-armed post-MMU (`blk_rearm`, common-config MMIO writes — verified DRIVER_OK + live reads/writes); the NVRAM variable store is no longer the persistence medium. `bash tools/verify-live-fs.sh`, class B, 1/1 pair. *(Claim 3475's other fixes stand: the per-flush TX markers/probe persist are first-flush-only / `-Dprobe-var`-gated.)*
- [x] A scripted console session passes automatically (asserting in `vm-serial.log`) — the mock transcript (`zig build test-console`, class A) passes, and the **live** `vm-serial.log` transcript assertion now passes too (`bash tools/verify-live-transcript.sh`, claim 6684, class B).
- [x] The VM can reboot or shut down from the shell — **PASS 2026-08-08 (claim 0527)**: a real EFI `ResetSystem` driven from a live `dipshit>` shell is observed end to end on VZ — `reboot` resets the machine (second full takeover, fresh memory-map key in `vm-serial.log`) and `shutdown` powers it off (VM state → stopped), 4/4 boots via `bash tools/verify-live-reboot.sh` (class B). The mechanism itself shipped + unit-proven in claim 0011. *(The claim-0011 `M2_RST!` marker write is best-effort by design and was lost in the teardown race; the machine-level reset/power-off is the evidence.)*
- [x] No allocator, MMU replacement, interrupts, scheduler, or userspace is falsely claimed.

## The march tracker (per milestone)

> **Moved 2026-08-06:** the per-step tracker and the best-agent-split
> tables used to live in this file; agents marking steps collided here
> with gate and milestone-status edits. They now live in the per-milestone
> tracker [`docs/march-m15.md`](march-m15.md) — update a step's row there,
> never here. This file holds milestone-level facts only (position, gates,
> hard gates) plus pointers.

## What comes immediately afterward

**Ordering after M1.5 is explicit and enforced by evidence classification** (`docs/gate-inventory.md`):

1. ~~**Reliable post-MMU access to the already-discovered virtio-pci console transport (post-MMU virtio TX, class B).**~~ **DONE 2026-08-08 (claim 1517)** — root cause (translation start-level mismatch + stale-TLB crutch, claims 6460/7896) fixed in production: T0SZ=16 + `tlbi vmalle1` at the switch; `zig build run` passes (banner + memory-map + terminal state in `vm-serial.log`).
2. ~~**Virtio RX / live transcript (class B `live-transcript-rx`).**~~ **DONE 2026-08-08 (claim 6684)** — the polled virtio receive queue delivers host keystrokes end to end; `bash tools/verify-live-transcript.sh` asserts the live `dipshit>` transcript in `vm-serial.log` (3/3 boots).
3. ~~**Live reboot/shutdown observation (M1.5 close-out, hard gate 6).**~~ **DONE 2026-08-08 (claim 0527)** — a real EFI `ResetSystem` from a live `dipshit>` shell observed end to end (`bash tools/verify-live-reboot.sh`, 4/4 boots: `reboot` resets the machine, `shutdown` powers it off). The last hard gate — the filesystem one — closed 2026-08-09 (claim 3475: `ls`/`cat`/`write` persist through reboot via the pre-exit ESP snapshot + NVRAM-persisted writes, `verify-live-fs.sh`) and **upgraded the same day to a real FAT32 storage driver (claim 6420)**: `write` persists to the ESP's FAT volume through a virtio-blk transport, files survive reboot on the disk itself, and the NVRAM persistence medium is gone. **All 7 M1.5 hard gates pass; the milestone is tagged `m1.5-interactive-monitor` (2026-08-09).**
4. ~~**A physical page allocator over the captured EFI map.**~~ **DONE 2026-08-08 (claim 3972)** — first-fit bitmap allocator over the captured map's ConventionalMemory (fixed 128 KiB BSS bitmap over the 4 GiB identity-map span), wired post-exit in `kernel_main`; `pages`/`pages selftest` monitor commands; 18 unit tests; live-observed on VZ (`total=0xee2b` pages across 7 regions; selftest allocates the largest contiguous run and restores the pool). **Extended 2026-08-09 (claim 5162):** the pool now also covers loader + boot-services regions, with exclusion ranges protecting the live kernel image, stack, handoff page, and captured-map buffer — `pages` reports `excluded=…`; 25 alloc/memmap unit tests; full class-A set green at HEAD `19ad92c` (`artifacts/verify-portable-5162.txt`).
5. ~~**Exception vectors** (first half of item 5).~~ **DONE 2026-08-08 (claim 9746)** — VBAR_EL1 vector table + basic synchronous/IRQ handlers installed post-MMU (kernel owns EL1; a pre-exit VBAR write was measured catastrophic on VZ — see the claim), `dipshit> fault` triggers a real `udf` that is reported and resumed live (class B gate `tools/verify-live-exceptions.sh`, 2/2).
6. ~~**GIC + timer interrupts (second half of item 5).**~~ **DONE 2026-08-09 (claim 9187; supersedes claim 7948's blocker conclusion).** The spec-corrected GICv3 driver uses MADT types 0x0B/0x0C/0x0E, targets SGI/PPI registers in the redistributor's `+0x10000` SGI frame, selects the boot CPU frame, and programs the GTDT trigger mode. On real VZ, periodic CNTP PPI 30 enters the claim-9746 EL1 IRQ vector, is acknowledged, handled, EOI’d, and re-armed; `bash tools/verify-live-timer.sh` requires five IRQ ticks and zero poll ticks and passes **3/3** while the shell remains responsive. The old idle-loop timer poll is no longer used in production. **Tasks are the next milestone-three card.**

The command layer above is portable; `docs/march-m15.md` step 15's filesystem-command **deferral is superseded 2026-08-09** — first by the pre-exit ESP file window (claim 3475) and then, **on the same day, by the real FAT32 storage driver (claim 6420)**: `ls`/`cat`/`write` now read and write the live ESP's FAT volume through a virtio-blk transport, so files persist on the disk itself and **no storage driver remains deferred**. The allocator and interrupt prerequisites are now complete; milestone-three task work is next.

## Assumptions & gaps in this plan (checked against the merged `main`)

- **ADR 0004 now exists and matches the plan's citation.** It is the
  milestone-two kernel-proper ADR; its console is polled TX-only with
  explicitly "no RX path" — exactly the constraint the plan warned about
  ("VZ may expose only a virtio console rather than a simple MMIO UART").
  The console identity on VZ is **observed** — a modern virtio-pci device
  (claim 0013, bus 0 D5 `0x1af4/0x1043`, BAR `0x100010000`); the transport is
  armed pre-exit and pre-exit TX works (claims 0013/0017). Post-MMU access
  to that transport was blocked (claims 0018/0020) until claim 1517 fixed
  the underlying start-level mismatch; post-MMU TX is now **observed**
  (banner + memory-map + terminal state in `vm-serial.log`, claim 1517).
  The virtio console's register layout is **[observed]** for the driven
  queues — queue 1 TX (claim 1517) and queue 0 RX (claim 6684, live
  keystrokes end to end) — see `docs/hardware-contract.md`.
- **Runner serial input was `nil`; it is now a real handle in `--console`
  mode.** The evidence path (`zig build run`) still uses
  `VZFileHandleSerialPortAttachment(fileHandleForReading: nil, ...)`
  unchanged; the M1.5 `--console` mode (landed 2026-08-06) wires a stdin
  pipe as `fileHandleForReading` and forwards host bytes into it
  (evidence: `artifacts/m15-host-console-gate.txt`).
- **Output observation: evidence path still file-polls; console mode
  streams.** `zig build run` still re-reads the serial log
  (`Data(contentsOf:)`) on a timer — unchanged, evidence semantics intact.
  The M1.5 `--console` mode uses a pipe-based duplex attachment and tees
  guest output live to the terminal and the log (no full-log reloads).
- **"256 MiB detected"** matches the runner's configured
  `memorySize = 256 * 1024 * 1024` (unchanged on merged `main`); `mem`
  should derive it from the captured map, not hardcode it.
- **The kernel is post-Boot-Services and never returns.** `ExitBootServices`
  is called (ADR 0004), `x3` is the handoff v2 struct (not the ESP root),
  and the kernel ends in a WFE loop. Consequences baked into the steps
  above: no UEFI Serial I/O protocol probe, no `GetMemoryMap`, no Simple
  File System — the monitor is the terminal loop's payload.
- **VZ firmware quirks still apply:** `ConOut` is not routed to the virtio
  serial port or framebuffer, but the kernel drives the virtio console
  itself — post-MMU virtio TX is now reliable (claim 1517, `zig build run`
  passes; MMU-takeover, device identity, and post-MMU TX are [observed]
  per claims 0010/0013/0020/0021/1517, and the RX-side register layout is
  [observed] for the receive queue (claim 6684); see
  `hardware-contract.md`). Transcript tests: `zig build
  test-console` (class A mock) gates on bytes the shell actually emitted;
  the live `vm-serial.log` assertion is the separate class-B gate
  (`live-transcript-rx`, claim 6684 — `bash tools/verify-live-transcript.sh`
  passes: live RX observed end to end, re-verified at `4ca9fb4` by claim
  7392) and is not proven by mock or NVRAM bytes.

## Multiagent coordination

This repo is developed by multiple agents and humans, sometimes on the same
day (e.g. PR #8's M1.5 tracker and PR #10's gate evidence landed within
hours of each other and collided; PR #12/#13 collided again on the same
changelog section). The rules below make that safe. They are **binding**
(mirrored in `AGENTS.md`).

### Rules

1. **Claim before you start.** Any non-trivial work gets a claim file in
   [`docs/claims/`](claims/README.md) and a log entry in
   [`docs/logs/`](logs/README.md) *before* code is written. Unclaimed work
   is fair game; claimed work is not.
2. **One editor per file at a time.** If two agents need the same file, the
   second waits, or merges through the integration branch — never both edit
   `kernel/src/main.zig` (or this file's tracked sections) simultaneously.
3. **Append-only logs, one per branch.** The changelog is split by branch
   under `docs/logs/<branch>.md` so parallel appends cannot collide.
   Append-only: never rewrite or delete an entry. Corrections are *new*
   entries that reference the old one.
4. **Update on completion (and on blockers).** Flip your claim file's
   status and append a log entry when done; append one when blocked so the
   next agent doesn't repeat the attempt.
5. **Own your evidence.** Every entry cites `artifacts/` files. No
   observed claim without a saved log.
6. **Doc edits go through this file.** Status prose lives here; other docs
   link to it. If you must touch `README.md`/`roadmap.md`/`testing.md`,
   prefer pointer-level changes and put the substance here.
7. **Never hand-edit a generated index.** The claim and log index tables
   in `docs/claims/README.md` / `docs/logs/README.md` are **generated**
   from the claim/log files by `tools/status/refresh-indexes.sh` — create
   your file, run the script, done. `tools/verify-coordination.sh`
   (`just verify-coordination`, also CI) fails if the indexes drift from
   the files, so a stale hand-edit cannot slip through a merge.

### Active claims

> **How to claim:** copy `docs/claims/TEMPLATE.md` to
> `docs/claims/<NNNN>-<slug>.md`, fill it in, set Status to `🔄 <branch>`
> **before** starting work, then run
> `bash tools/status/refresh-indexes.sh` — the claim and log index tables
> are **generated from the files**, so claiming never edits a shared
> table and never edits this file. Flip your claim file to `✅` (evidence)
> or `⛔` (note why) on completion and re-run the script. Unclaimed
> (`⬜`) claims are fair game; `🔄`/`✅` claims are not. The **canonical
> index with status is [`docs/claims/README.md`](claims/README.md)**;
> this file holds no claims table, so parallel claims never touch the
> same lines here.

## Changelog (append-only, per branch)

> **Moved 2026-08-06:** the changelog used to live in this file; every
> agent appended here and parallel work collided (PR #8/#10, then
> PR #12/#13). It is now **sharded by branch** under `docs/logs/` — each
> branch owns its own append-only log, so cross-branch merges never touch
> the same lines. All entries — including the final two stragglers,
> migrated verbatim to `docs/logs/agent-buffy-m15-commands.md` on
> 2026-08-06 — live in the per-branch logs; **this file holds no changelog
> entries**, so there is nothing here for parallel agents to collide on.
> See the [log index](logs/README.md) for the format and each branch's
> file.

## Immediate gate work (prerequisites for M1.5)

Ordered; each has a prompt doc and a gate. **Status lives in the claim
files** (canonical index: [`docs/claims/README.md`](claims/README.md)) —
this section is pointer-level only, so a gate passing never needs an edit
here.

1. **Root-cause the failing bad-handoff gate** — `docs/m2-bad-handoff-fix-prompt.md`.
   The kernel must return `0x2` to the loader on a bad magic; it does not.
   This unblocks M1.5 hard gate 1 and possibly the serial gate too.
   **Gate:** `bash tools/verify-bad-handoff.sh` exits 0 with
   `RC.TXT` → `kernel_rc=0x2`; good path unregressed.
   **Status:** see [`0001-bad-handoff-gate`](claims/0001-bad-handoff-gate.md)
   — ✅ fixed 2026-08-06 (root cause: shim LR clobber; evidence in the
   claim and `docs/logs/agent-buffy-m2-badhandoff-fix.md`). The serial gate
   (item 2) no longer shares that suspect.
2. **Run the VZ serial/MMU gate** — `docs/m2-vz-serial-gate-prompt.md`
   (M1.5 march step 8's "confirm the serial console", `docs/march-m15.md`).
   **Gate:** exact banner `DipshitOS kernel has seized control.`,
   `memory-map descriptors=0x...`, and `kernel terminal state` in
   `vm-serial.log`; then flip matching `[inferred] → [observed]` entries in
   `docs/hardware-contract.md`.
   **Status:** see [`0002-vz-serial-gate`](claims/0002-vz-serial-gate.md) — ⛔ blocked (historical) → **PASS 2026-08-08 (claim 1517):** the gate (`zig build run`) now exits 0 with the exact banner, `memory-map descriptors=0x…`, and `kernel terminal state` in `vm-serial.log`. Root cause of the historical block (virtio TX hangs post-MMU) was the translation start-level mismatch; fixed in production with T0SZ=16 + `tlbi vmalle1` at the switch (claims 6460/7896/1517). The post-exit-safe fallback (claim 0015, `bash tools/verify-nvram-console.sh`) remains as the NVRAM channel for nvram-console builds.
3. **If no usable serial device exists on VZ**, implement the ADR 0004 D4
   fixed-memory-marker fallback (host-side dump of the kernel's BSS
   `takeover_marker`). **Gate:** saved host-side dump matching the `M2_*`
   markers. **Status:** ✅ done 2026-08-07 — see
   [`0009-m2-marker-fallback`](claims/0009-m2-marker-fallback.md) and
   `artifacts/m2-marker-gate.txt`. The gate passes with the **NVRAM ladder**
   form (the memory-dump form is impossible on VZ — guest RAM is not
   host-mapped, observed), and the ladder discriminated the serial gate:
   every run ended at `M2_MAPD!` — the death was in the **MMU-takeover
   window**. That death is now **root-caused and fixed by claim 0010** (see
   the [gate table](#gate-status)): the ladder advances
   `M2_MAPD! → M2_MMUP! → M2_SERIA`, the switch completes, and the probe
   runs to completion finding no usable device in the declared windows
   (that reading is superseded by claim 0013 — the real console is a
   virtio-pci device outside them, see the gate table). See claim 0009 for
   the original ladder and claim 0010 for the root cause and fix.

## Housekeeping conventions (keep the project nice as it evolves)

- **This file is the single source of truth for status and coordination.**
  Update the moment a gate passes, fails, or a milestone completes; claim
  work before starting (claim file in `docs/claims/`); append to your
  branch's log under `docs/logs/`; regenerate the indexes with
  `bash tools/status/refresh-indexes.sh` after creating either. Run
  `bash tools/verify-coordination.sh` before opening a PR.
- **Evidence lives under `artifacts/`** (gitignored, except `.gitkeep`).
  Every gate claim names its evidence file and date. No evidence, no
  "observed".
- **Facts vs. inference:** hypotheses are marked `(inferred)`; hardware
  tags flip only with matching saved logs (AGENTS.md evidence rules).
- **Branch hygiene:** feature work on `agent/...` branches, PRs against
  `main` (ADR 0003, `docs/branch-protection.md`); M1.5 work merges through
  the integration branch.
- **OS junk:** `.DS_Store` files are gitignored; delete them when noticed
  (`find . -name .DS_Store -not -path './.git/*' -delete`).

## Related docs

- [`roadmap.md`](roadmap.md) — milestone planning (the "where we're going").
- [`march-m15.md`](march-m15.md) — the M1.5 per-step tracker and best-agent split (one file per milestone).
- [`testing.md`](testing.md) — the verification sequence and evidence policy.
- [`logs/README.md`](logs/README.md) — per-branch append-only changelog index (the sharded changelog).
- [`claims/README.md`](claims/README.md) — per-claim files index (the sharded claims table, generated).
- [`../tools/status/`](../tools/status/) — index generator (`refresh-indexes.sh`) and the coordination gate (`verify-coordination.sh`).
- [`hardware-contract.md`](hardware-contract.md) — hardware assumptions, `[observed]`/`[inferred]`.
- [`architecture.md`](architecture.md) — components and data flow.
- [`m2-bad-handoff-fix-prompt.md`](m2-bad-handoff-fix-prompt.md) — prompt: fix the failing failure-path gate (now passing; root cause was the shim LR clobber).
- [`m2-vz-serial-gate-prompt.md`](m2-vz-serial-gate-prompt.md) — prompt: run the VZ serial/MMU gate.
- [`m15-host-plumbing-prompt.md`](m15-host-plumbing-prompt.md) — prompt (agent A): duplex serial attachment, teeing, terminal safety, `zig build console`.
- [`m15-commands-prompt.md`](m15-commands-prompt.md) — prompt (agent C): command registry, identity/memory/utility/control commands, personality (mock-console based).
- [`decisions/`](decisions/) — ADRs 0001–0006 (binding: 0004 kernel proper, 0005 runtime-built function tables, 0006 MMU debt boundary).
- [`../AGENTS.md`](../AGENTS.md) — project rules (now including the multiagent coordination rules).
