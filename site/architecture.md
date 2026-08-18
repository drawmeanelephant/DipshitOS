---
title: Architecture
status: published
tags: [architecture, overview]
---

# Architecture

DipshitOS is a layered, freestanding kernel with no libc and no heap in the
boot-critical paths — bounded fixed-BSS storage is the norm. This page is the
map; the satellites below carry the detail.

## The stack, top to bottom

```text
┌───────────────────────────────────────────────┐
│  EL0 user programs + desktop apps (CALC.BIN,   │
│  NOTEPAD.BIN, DESKTOP.BIN, FETCH.BIN, …)      │
│  syscalls: ping/write/…/ipc/win/events/file/  │
│             exec/kill/tcp/fs (0–37)           │
├───────────────────────────────────────────────┤
│  Monitor + shell (dipshit>)                   │
│  Road Pops terminal · Driving Award compositor │
├───────────────────────────────────────────────┤
│  Scheduler (round-robin, 7 tasks) · processes │
│  Physical allocator · identity-map MMU        │
├───────────────────────────────────────────────┤
│  Drivers: virtio console/blk/entropy/gpu/net  │
│  + USB XHCI + HID · GICv3 · generic timer     │
├───────────────────────────────────────────────┤
│  UEFI boot loader (BOOTAA64.EFI)              │
└───────────────────────────────────────────────┘
```

## What owns what

- [[kernel|Kernel overview]] — boot, `ExitBootServices`, exception vectors, the monitor and command registry.
- [[memory|Memory model]] — the physical allocator, identity-map page tables, per-task address spaces.
- [[userspace|Userspace & syscalls]] — EL0, the frozen syscall ABI, fault-safe uaccess, exec and processes.
- [[drivers|Device drivers]] — the virtio surface, the XHCI USB controller, and the MMIO contracts.

## Design discipline

Three rules show up everywhere:

1. **Bounded static storage.** Rings, FIFOs, window tables, and frame buffers
   are fixed-size BSS carve-outs. There is no general heap in the device
   paths; a full ring refuses or drops oldest, it does not grow.
2. **One request at a time.** Device queues are small (size 4) and drained
   polled — the project observes device behavior rather than assuming
   interrupt delivery, then records what it saw in
   [`docs/hardware-contract.md`](https://github.com/drawmeanelephant/DipshitOS/blob/main/docs/hardware-contract.md).
3. **Evidence over assertion.** Every subsystem has host tests (deterministic)
   and, where hardware is involved, a live Virtualization.framework gate. See
   [[evidence]].

## Subsystem boundaries in one line each

| Subsystem | What it does |
|-----------|--------------|
| Boot loader | loads `KERNEL.BIN`, writes `BOOTED.TXT`/`RC.TXT` evidence, jumps to the kernel |
| MMU | identity-map TTBR0_EL1 tables (T0SZ=16), per-task user roots, EL1-only kernel overlay |
| Allocator | first-fit bitmap over the captured EFI map, with exclusion ranges |
| Scheduler | tick-driven round-robin; 7 slots (shell + worker + 4 EL0 + idle) |
| Processes | bounded registry, lifecycle states, exit-status propagation, IPC mailboxes |
| Syscalls | ADR 0007: 64-slot table, 38 implemented (0–37), deterministic counters |
| Networking | virtio-net → ARP → IPv4/ICMP → UDP → DHCP → DNS → TCP, plus a NAT mode and the EL0 TCP seam |
| Graphics | virtio-gpu framebuffer → text → Road Pops → Driving Award compositor |
| Input | XHCI host controller → USB enumeration → HID boot protocol → event FIFO → per-process event queues |
| Events | keyboard/pointer/window events routed to focused EL0 apps (`sys_poll_event`/`sys_wait_event`) |
| Desktop | the zero-heap `ui.zig` widget toolkit + CALC/NOTEPAD/TOP/DESKTOP/FILE applications |

<Aside kind="note">

**PLANNED.** The architecture deliberately stays single-CPU, single-display,
and 2D-blit-only. SMP, multi-display, and accelerated/3D paths are explicit
non-goals for now.

</Aside>
