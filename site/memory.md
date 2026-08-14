---
title: Memory model
parent: architecture
status: published
tags: [architecture, mmu, memory]
---

# Memory model

DipshitOS is identity-mapped with per-task user roots. There is no demand
paging, no swap, and no kernel heap in the device paths.

## Physical allocation

A first-fit bitmap allocator covers the captured EFI map (Conventional +
loader + boot-services memory), with exclusion ranges protecting the live
kernel image, stack, handoff page, and captured-map buffer. The `pages` command
reports totals, free counts, and the exclusions.

## The MMU

- The kernel stays identity-mapped in TTBR0_EL1 (T0SZ=16), with TTBR1=0 — a
  design forced by an observed Virtualization.framework incompatibility with a
  TTBR1 KVA shadow (64 KiB table-address masking; see ADR 0007).
- Each EL0 task gets its own TTBR0 user root: a clone of the kernel identity
  tree with the task's text + stack leaves overlaid at their user VAs.
- Kernel RAM, firmware, and MMIO are EL1-only (AP=0b00), so EL0 can reach only
  its own leaves — and every user leaf is UXN/PXN (W^X).

## Address spaces and W^X

- `addrspaces` reports TTBR1=0, T0SZ=16, per-task TTBR0 roots, and the user
  root's leaf inventory.
- The loaded program's text leaf is EL0 read-only; exec packs an argv block
  into the same text page (zero extra pages) so even process arguments stay
  read-only.

## Storage discipline

Rings, FIFOs, window back-buffers, and frame buffers are fixed-size BSS
carve-outs. Capacity is a documented constant — the scheduler pool is 7 slots,
the IPC mailbox is 8 × 64 B per process, the window registry is bounded — and
overflow refuses or drops-oldest rather than allocating.

<Aside kind="warning">

**LIMITATION.** No demand paging, no overcommit, no swap. The 256 MiB guest is
a fixed reservation, which is exactly why the balloon device (memory reclaim)
is still unstarted and low priority.

</Aside>
