---
title: Memory
parent: architecture
status: published
tags: [architecture, memory]
---

# Memory

**Fixed, measured, and never guessed** — there is no dynamic heap and no
paging. The ELF loader maps `.text`/`.rodata`/`.data`/`.bss` at a fixed
layout and the syscall table is a **runtime-built 128-slot table with 78
implemented slots (0–77, contiguous)**. The [kernel](kernel.md) is 50–78 KiB resident.

## The data budget (exact, frozen)

Every global buffer, queue, table, ansi stack, fault frame, and display
surface is bounded **at compile time** and sized from a single table in
[`docs/memory-map.md`](https://github.com/drawmeanelephant/DipshitOS/blob/main/docs/memory-map.md).

| Resource | Bound |
|---|---|
| Registered kernel/EL0 pages | 64 |
| Windows (registry) | 12 (kernel + EL0 share one bounded registry) |
| Threads | 16 per process (M39), 8 total (record) |
| MMIO windows per device | 16 (8×16 B) |
| Kernel control commands | 28 |
| Monitor commands | **78** |
| Monitor outputs | 28 |
| Ansis | 32 depth, 64 per ansi |
| Transcripts | 8 |
| Typed bytes/lines | 80 per line, 24 total |
| Channels | 8 |
| Faults | 16 in-flight, 1 per thread |
| Sleeper queues | 16 (9 per wakeup) |
| File handles | 8 per process |
| Tickless deadlines | 8 |
| EL0 windows | 16 |
| Ready queues | 64 (ENOSYS past 63) |
| Event slots | 128 |
| Exit-code slots | 32 |
| Registry entries | 20 (deadlock-bounded) |

Pointers are validated against `PAGE_SIZE` and `CORE_VA_END` — EL0 pointers
additionally must be `<` `USER_TOP` and `>=` `USER_BASE`, with page-frame
bounds. Ring indices are written **after** the payload and read back before
release, so an overflowing producer can never leak stale bytes.

## The page pool

64 registered pages. Frames come from two lock-free LIFO stacks (32 + 32),
so every alloc/free is exactly `cmpxchg` (CAS) plus a single linked-list
store: the head is read, compared, swapped in one instruction, and the old
head becomes the pushed frame's `next`. A per-CPU reserve releases **only**
on underflow, so the list can never grow an unpushable frame. Kernel/EL0
frames are disjoint from the allocator (visible directly through `nstat`).
No page is ever lost: deallocation, shutdown, and process teardown all push
back to the same two stacks (M39 T7).

**Existing pages were re-pointed at in-guest proofs after the HF6 image
retag:** the `exec` and page-in pins (M08/M29) were deleted with the flat
image — `live-exec` gates the share load today — and the size/page budget
row was retagged to the class-A `go-size` gate.

## Paging

There is no demand paging, no swap, and no paging in any form. Virtual
addresses in the ELF path are the physical addresses of the loaded pages
(ID map). A page-fault frame exists (user `mmap` reservations fault lazily,
the fault handler is exercised by `live-mmap` and the VM fault-unit tests)
but there is no demand pager behind it: an unbacked address faults, records,
and dies — it is never a scheduling event.

## NVRAM as swap (arc three)

`Arc3-3` opens the store of first resort. NVRAM (`nvram_zig.zig`) is 256 KiB
of persistent storage, split into four zones: file store **4× 60 KiB**, log
256 B, panic ring 2 KiB, and the reserved table **15.7 KiB** — the rest of
the space is `__nvram_pad__`, zero at build, untouched at runtime. The file
store is a flat **key×value log** with 16 pre-registered keys and a 160-entry
reverse lookup; keys map to fixed 60 KiB slots, the whole thing is
initialized to `0xFF`, and `mkfs`/`fsck`/`cat`/`write` are its recovery
commands. The system call ABI is minimal — `file_put(path, data, len)`,
`file_get`, `file_del`, `file_stat`, `file_enum` — and since M34 HF6 the
writable notes live on the host share of NVRAM, not in NVRAM itself (the
zone itself remains as the panic/log store).

The store is exercised by `live-nvram` and `live-nvram-fs`, and sits behind
the class-A `nvram-file` pin gate.

## System call table (arc four)

Milestone four opened the gate: a **runtime-built, 128-slot** table with
**78** slots implemented (0–77) and the rest returning `ENOSYS`. The M29
ABI renumbering added `mmap`/`munmap` and `rlimit`, the M32 `wmctl`
reservation, the M50 principal/caps set, the M51 CSPRNG `getrandom` and
bounded files, the thread/futex seam for `GOOS=virelai`, and `sock_ready`
for the Go netpoll. A fixed table of statically-typed stubs copies
user blocks in and out under `kmemcpy`, tracks one dirty line per write for
the damage grid, and every slot is pinned by a live class-A gate.

Milestone nine's **per-process event queues** widened the seam: bounded
ring queues, one event per seat action, and `poll`/`wait` for readiness.
EL0 windows, the per-process file ABI (M10) and its mutating extensions
(M13 B1), the command-registration pair (M14 #767), the kill slot, and the
rest of the current table all sit on the same bounded path. The bounds
haven't moved: 128 slots, one shared page budget, one fixed layout.

The register-fence pin rows were deleted with the image retag: the register
snapshot is now asserted structurally from the live image by the `boot-kernel`
spec, and the page-budget row is pinned by the class-A `go-size` gate.

## ToC

- [Memory map (reference)](https://github.com/drawmeanelephant/DipshitOS/blob/main/docs/memory-map.md) — the actual table of every buffer size and index rule.
- [Evidence](https://virelaios.dev/evidence/) — the gate index that proves these bounds hold.

<Aside kind="info">

**VERIFIED.** Measured numbers and bounded-layout claims come from
[`docs/memory-map.md`](https://github.com/drawmeanelephant/DipshitOS/blob/main/docs/memory-map.md)
and are gated by `live-fs` (measured boot budget) and `live-gfs` (bounded
syscall surface).

</Aside>

<Aside kind="warning">

**LIMITATION.** 64 registered pages, no demand paging, no swap, no paging in
any form. A process that grows past its file/stdio/channel budget dies by
`ENOSYS` or a fault — it is never silently truncated.

</Aside>
