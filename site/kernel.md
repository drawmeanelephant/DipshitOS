---
title: Kernel
parent: architecture
status: published
tags: [architecture, kernel]
---

# Kernel

100% Zig. 50–78 KiB resident. **No libc, no POSIX, no guest OS anywhere.**

## Boot

UEFI (boot shim, `kernel/src/boot.zig`) → `.text`/`.rodata`/`.data`/`.bss`
relocated in a single map, ID map extended to cover them, **CR0.WP
re-enabled**, NX set on `.bss`, GDT/IDT installed, `STIVALE2` framebuffers
registered. The card's driver map — Apple's virtio-mmio transport behind
`vmmio*`, PCIe, AHCI, NVMe, and USB xHCI — comes from the pre-existing
firmware environment.

The boot image itself is small: `make-image.sh` states plainly that it is a
**boot volume only** (`EFI/BOOT/BOOTAA64.EFI` + `KERNEL.BIN`, nothing else),
and a three-pin check enforces it. Applications, data, and evidence ride the
host share.

<Aside kind="info">

**VERIFIED.** Every boot step up to the shell handoff is pinned by the
class-A `boot-kernel` spec, replayed against the runner.

</Aside>

## The core

- **Executables:** kernel type `ET_EXEC`, identity-mapped through a single
  UEFI memory-map-driven relocation, then `jump_to_kmain`. All
  `user/src/*.bin.elf` files are `ET_DYN` (PIE) at the same fixed base.
- **Logging:** bounded line buffer, a homegrown **deferred `kprintf`**, an
  explicit `spinLock`, and a serial `puts`.
- **Tables:** interrupt vector, IDT gate descriptors, and fault frames all
  use a compact record format. The interrupt stubs go through a
  **two-bank register save** (`ipushall`/`ipopall`).
- **Shutdown:** PSCI system-off is now the first path — a bare
  `psci_shutdown()`, then the legacy SMC SID check with masking, then a
  measured 20-second timeout fallback. The real QEMU path returns, so the
  old double-poll infinite loop is gone.
- **Fence discipline:** W^X, TCR shareability, ordered trap stacks, and a
  device `dsb sy` before the hang; the terminal fence is documented
  inline at its one use site (write-out, not in).

## Register budget (31 + 16)

The kernel's entry stub snapshots every caller-saved and callee-saved
register before running a single instruction. x0–x30 (31 GPRs, 248 bytes)
plus 16 SIMD/FP registers (128 bytes) are stored to a **376-byte frame** —
`ipushall` is one wide `stp` train — and restored by the interrupt return
path. The bound is closed: exactly **76** stubs are emitted (56 IRQs,
20 exceptions; `MAX_VECTORS` 64 with 56 reserved), so **all 76** trap
entries snapshot the same 376-byte layout; there is no 77th, and no code
path skips it.

The standard register snapshot page was the last one re-pointed at an
in-guest proof: after the `GOTEST.ELF` merge the pin rows read the
class-A `go-test` gate, with `live-devcons` covering the in-guest Go
process and its exec, fault, and priority pin assertions.

<Aside kind="info">

**VERIFIED.** The dual-bank snapshots are structural — asserted from the
live image in `nm` checks and exercised by every fault the gates take
(deliberate `svc 0`, `brk`, and page-fault paths).

</Aside>

## Syscall seam (78 slots, 0–77)

Userspace-facing slots at the current tree:

| Slot | Name | Notes |
|------|------|-------|
| 0/1 | `write`/`read` | console only (main thread), serial seam, argv struct |
| 2/3 | `exit`/`yield` | main thread only, one-shot gate, tickless |
| 4/5 | `spawn`/`wait` | EL0 load, bounded pending-exit queue |
| 6 | `uptime` | tick-count `u64` |
| 7 | `cwd` | process-local path (syscall 7) |
| 8/9 | `open`/`close` | owner-tagged 8-handle file table (M10) |
| 10/11 | `read`/`write` | file read/write (M10, handle-typed) |
| 12–20 | window | owner-restricted per-process EL0 windows |
| 21 | `kill` | terminate a running EL0 program |
| 22 | `dir_list` | directory enumeration (M10) |
| 23–27 | file I/O | the M10 file-table ABI |
| 28 | `dbg` | one-shot, text only, serial seam (A1) |
| 29 | `snd` | queue-0 stream `sndsnd` → 線 / note bookkeeping |
| 30–32 | `window_*` | position, size, raise (Arc3) |
| 33 | `mouse_set` | guest-relative motion → fixed-point velocity |
| 34–37 | `file_delete`/`file_rename`/`file_truncate`/`file_free` | mutate the file store (M13 B1) |
| 38/39 | `add_cmd`/`send_reply` | guest-registered monitor commands (M14 #767) |
| 40–46 | graphics | pixels, damage, invalidate, grab, hover, wallpaper, set-unmapped |
| 47/48 | `win_resize`/`drag_start` | Arc4 #237 |
| 49/50 | `win_move_to_workspace`/`win_set_unsaved` | #241, #242 |
| 51 | `setrlimit` | Arc5 #246, self-only |
| 52 | `notify` | window-server notifications |
| 53 | `win_set_unsaved` | Arc5 #251, self-only |
| 54–62 | extras | `_HANDOFF`, time read, `chan_*`, `getrlimit`, framebuffer query |
| 63/64 | `mmap`/`munmap` | anonymous user memory (M29) |
| 65 | `wmctl` | the registered WM server's exclusive control surface (M32, ADR 0015) |
| 66 | `time` | Unix wall-clock seconds from the EFI epoch (#1058) |
| 67 | `tty_attach` | attach/detach the controlling terminal front-end (ADR 0020) |
| 68 | `principal` | read `{uid, caps}` (M50, ADR 0024) |
| 69 | `file_mode` | owner-only chmod, persisted to `OWNERS.TXT` (ADR 0024) |
| 70 | `secret_get` | read `SECRETS.TXT` — never logged (ADR 0024) |
| 71 | `tty_net_auth` | the delegated net-auth challenge channel — never logged (ADR 0024) |
| 72 | `getrandom` | capped read from the kernel CSPRNG (M51, ADR 0025) |
| 73/74 | `thread`/`futex` | the GOOS=virelai thread + futex seam (ADR 0027) |
| 75 | `exnotify` | EL0 fault-handler register (#1228) |
| 76 | `sock_ready` | socket readiness for the Go netpoll (#1163) |
| 77 | `file_sync` | `fsync` for EL0 — push `/host` writes to the live fd (M66a, ADR 0007 amendment) |

Kernel-side dispatch trampolines (`kniggle_trap`): CFI v2 (12 gates) with
the 7,000-gate fail-closed check and bounded capability-trait dispatch.

<Aside kind="info">

**LIVE-GATED.** The table row-by-row pin set is `live-user-fs`,
`live-concurrent`, `live-wait`, `live-ipc`, `live-net-udp-syscall`,
`live-net-tcp-syscall`, `live-events`, `live-sys-kill`, `live-desktop`,
`live-exit`, and `live-roadpops`.

</Aside>

## Identity & drivers

- **virtio-gpu** (`virtio_gpu.zig`): spec 2D path — `GET_DISPLAY_INFO` →
  `CREATE_2D` → `ATTACH_BACKING` → `SET_SCANOUT` → `TRANSFER` → `FLUSH`
  (4 KiB-aligned BSS framebuffer).
- **virtio-net** (`virtio_net.zig`): RX → ARP/ICMP/UDP/TCP (SYN..FIN,
  sliding window), TCP feature path on `--net-tcp`; UDP/TCP direct path.
- **Custom-virtio channel** (`custom_virtio.zig` + `virtio_file.zig`): queue
  5 is the host file channel (`--cvc-file <host-dir>`); queue 1 is the echo
  test path (`live-virtio-e2e`).
- **virtio-input** (`virtio_input.zig`): IRQ + snapshot ring → fixed-point
  pointer motion (the CG class gates).
- **virtio-rng** (`virtio_rng.zig`): the stack's only entropy source.
- **Virtio-console** (`virtio_console.zig`): `--console-tcp <port>` serves a
  real TCP listener at EL0; `live-devcons` boots 2 VMs and connects both
  directions.
- **USB xHCI** (`xhci.zig`): a bounded xHCI driver with a slot/context
  array, 32 doorbells, scratchpad allocator, transfer ring, and the
  `LLGT` low-level common-setup entry point (L4), with a
  class/subclass/protocol match table. Two class paths are live: **HID boot
  protocol** (`input.zig` — the keyboard/pointer behind `--input`; two known
  devices, no hubs, no full report-descriptor parser; gates `live-usb`,
  `live-input`) and **mass storage** (`usb_msc.zig` — Bulk-Only Transport +
  minimal SCSI over `--usb-msd`, raw sector write/read-back; gate
  `live-usb-msc`), with `fat32_ro.zig` providing the read-only FAT view.
- **Storage today** is the host share over custom-virtio queue 5 — see
  [storage](storage.md).

<Aside kind="warning">

**LIMITATION.** `screen` is the shared cross-platform screen path (running
headless, dumped to disk after boot) — it is not the Apple Virtualization
frame-capture path (see `docs/testing.md`).

</Aside>
