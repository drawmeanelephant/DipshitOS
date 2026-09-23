---
title: Drivers
parent: architecture
status: published
tags: [architecture, drivers]
---

# Drivers

A registered driver is a `Driver`: `selftest` / `init` / `start` / `stop` /
`irq` / `poll` / `state` / `deinit`. The AArch64 core (GIC, GICv3, SMC
mailbox, RPI property) registers the same way. `DriverCfg` governs memory
pool, IRQ policy, thread count, and affinity — overridable per instance.

## What's implemented (gates)

- **Transport.** There is **no guest virtio-blk driver and no AHCI driver** —
  the firmware reads the boot volume before the kernel starts, and every
  in-kernel byte comes from the host share (custom-virtio queue 5) or the
  USB MSC path (below). `virtio_net.zig` is the v2.0 network path (link
  status, RX/TX, RSS indirection table + hash key, and the queue-pair
  masks) fronting the VirtIO 1.0 guest-side path; `virtio_console`,
  `virtio_gpu`, `virtio_entropy`, and `virtio_input` cover console,
  framebuffer, RNG, and input.
- **AHCI.** Not present: no AHCI/ATA driver exists in the tree and no gate
  references one — the boot volume is the firmware's to read, and the
  kernel's byte sources are the share and USB MSC (above).

<Aside kind="info">

**VERIFIED.** Each line above is gated by a named class-A or class-B spec
(`live-usb-msc` among them); the specs are the source of truth.

</Aside>

- **USB.** `xhci.zig` is a bounded xHCI host driver — slot/context array,
  32 doorbells, scratchpad allocator, transfer ring, and the `LLGT`
  low-level common-setup entry (L4) — with a class/subclass/protocol match
  table. Two class paths are live: **HID boot protocol** behind `input.zig`
  (`live-usb`, `live-input` — the keyboard/pointer behind `--input`; two
  known devices, no hubs, no full report-descriptor parser) and **mass
  storage** in `usb_msc.zig` (Bulk-Only Transport + minimal SCSI, driven by
  `usb msc probe` over `--usb-msd`, with a real sector write/read-back;
  gates `live-usb-msc`, `live-usb-bulk`, `live-usb-block`).
- **Storage.** See [storage](storage.md): host share over custom-virtio
  queue 5 (`--cvc-file`) is the writable store; `usb_msc` + `fat32_ro` cover
  read-only USB images; `file_table` covers the per-process ABI.

## Staging & quality

- **Staging.** `STAGING` registers 51 candidates (5 probes) with a bounded
  subcommand array; each probe publishes or faults without touching other
  lanes.
- **Quality.** 1,000+ host unit tests cover the VirtIO transport, driver
  manager, and ring paths; class-A gate specs pin each seam live.

## Timing sources

There is one timer in the system: the architectural timer at EL1. `boot/zig`
arms it at `CNTFRQ`, and everything else — the tickless deadlines, the 1 Hz
overlay clock, the spinner, the sleep/wake path — derives from that single
source. There is no second clock and no wall-clock RTC in the kernel; the
`time` syscall (slot 66) reads the EFI epoch handed over at boot.

<Aside kind="warning">

**LIMITATION.** Drivers are thin VirtIO 1.0 guests with one generic backend
path; there is no MMIO-abstraction bridge (the driver sees guest-physical
addresses directly, which is what the fixed-layout contract assumes). USB
HID covers boot-protocol devices only (the two known devices, no hubs), and
there is no writeable FAT filesystem — images attached through `--usb-msd`
are read at the file level by `fat32_ro`.`

</Aside>
