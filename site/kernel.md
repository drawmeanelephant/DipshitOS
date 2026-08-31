---
title: Kernel overview
parent: architecture
status: published
tags: [architecture, kernel]
---

# Kernel overview

The kernel is a freestanding Zig program that never returns control to
firmware once it has seized the machine.

## Boot and takeover

1. The UEFI loader (`boot/src/main.zig`) reads `KERNEL.BIN` from the ESP,
   allocates `EfiLoaderCode` pages, copies the image, performs D/I-cache
   maintenance, and jumps to the entry point with a versioned handoff contract
   (x0 = base, x1 = size, x2 = System Table, x3 = a handoff struct).
2. The kernel captures the EFI memory map, retries `ExitBootServices` up to a
   bound, and installs identity-map TTBR0_EL1 tables — the MMU is never
   disabled during the switch (T0SZ=16 plus a `tlbi vmalle1` at the transition,
   the fix that made post-MMU virtio access reliable on the host).
3. From there it drives a polled serial console and enters the interactive
   monitor.

The canonical source for the exact behavior is ADR 0004
(`docs/decisions/0004-kernel-proper.md`) and the boot-time evidence described
in [[evidence]].

## Exceptions, interrupts, timer

- A real VBAR_EL1 vector table handles synchronous and IRQ exceptions; a
  deliberate `fault` command exercises and resumes a `udf` exception live.
- The GICv3 driver (MADT-discovered redistributor frames) programs a periodic
  CNTP PPI 30; the tick drives the scheduler and every time-based subsystem
  (sleep, DHCP lease timers, TCP retransmission).
- Polled device drain is the rule where an interrupt line is not yet observed;
  the project records that honestly instead of assuming.

## The monitor

The kernel serves a live `virelai>` command monitor over the serial console.
The registry is 47 commands at the current tree, spanning:

- **Identity / machine** — `about`, `version`, `uname`, `elephant`, `beans`, `sysinfo`, `welcome`/`tour`
- **Memory / machine state** — `mem`, `hex`, `pages`, `pci`, `handoff`, `mmu`-adjacent `addrspaces`
- **Tasks / processes** — `tasks`, `spawn`, `exec`, `procs`, `kill`, `mbox`, `syscalls`
- **Storage** — `ls`, `cat`, `write`, `mount`, `settings`
- **Networking** — `net` (arp/ip/ping/udp/dhcp/dns/tcp subcommands), `netsend`
- **Graphics / input / audio** — `screen`, `text`, `roadpops`, `win`, `input`, `usb`, `beep`, `clip`
- **Misc** — `help`, `echo`, `clear`, `repeat`, `random`, `reboot`, `shutdown`, `fault`, `uaccess`, `timer`

The command surface is deliberately colorful (a command named `beans` counts
beans), but each handler is bounded and deterministic.

<Aside kind="info">

**VERIFIED.** The monitor's transcript is pinned by a byte-identical mock test
(`zig build test-console`) in class A, and the live `virelai>` session is
asserted end to end by the class B transcript gate.

</Aside>
