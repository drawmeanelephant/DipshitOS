# ADR 0032: A kernel→user copy resolves the destination page in the process's own root

- Status: ACCEPTED
- Date: 2026-09-17
- Issue: #1391 (this decision) · milestone #1380 (M61) · unblocks card M61d
  (#1384)
- Related: ADR 0006 (the no-TLBI debt; the overlay's discipline), ADR 0031
  (the guest self-test whose intake case found this), claim 5804 (per-task
  TTBR0 user roots), M29 VM Depth (demand paging), ADR 0007 (syscall ABI —
  `EFAULT` keeps its frozen value), `docs/hardware-contract.md` (the observed
  descriptor), `docs/testing.md` (amended by this card)

> **One rule: `copy_out` never stores into a page it has not proven EL0 can
> read.** Under a task's root, an unpopulated user page still resolves for
> EL1 — into the kernel's EL1-only identity overlay — so a store there
> returns success and reaches nothing. The copy path now resolves each
> destination page in the process's own root first, or refuses with
> `EFAULT`.

## Context

Claim 5804 gave every EL0 task its own TTBR0 root: the kernel's identity
tree cloned verbatim (EL1-only leaves, AP = 0b00) plus EL0 leaves for the
process's text/data/stack apertures (mmu.zig,
`clone_into_user_root_apertures`). The kernel stays identity-mapped, so a
user VA and the physical address with the same number are two different
things that share a page-table slot.

M29 VM Depth then made anonymous `mmap` regions **demand-backed**: the region
is registered (`process.add_mmap_regions`) and armed as a uaccess write
region at every SVC entry, but its pages get leaves only when something
faults on them

- at EL0 (permission fault on the overlay's EL1-only entry →
  `try_handle_page_fault` Case 2 → `alloc_pages` + `mmu.map_user_page`), or
- **not at all** for EL1: the overlay already answers, so no fault happens.

Observed on VZ (`just gate go-selftest`, 2026-09-17, issue #1391): a
temporary descriptor probe on the destination pages of the guest's reads
printed

```text
[uac] va=0x48090000 len=120 root=0x7e307000 kind=3 ap=0 memattr=0 desc=0x48090403
[uac] va=0x4809a000 len=25  root=0x7e307000 kind=3 ap=0 memattr=0 desc=0x4809a403
[uac] va=0x4809b000 len=25  root=0x7e307000 kind=3 ap=0 memattr=0 desc=0x4809b403
```

i.e. the destination (a page of the process's mmap arena, VA 0x4809a000 /
resolved in the **live root** to an L3 leaf with `AP = 0` and AttrIndex 0
(Device-nGnRnE) whose physical address was the VA itself. `copy_out`
returned the full byte count; the app then read the page's zeros, because
the mapping EL0 got was a *different* page, demand-filled on the app's own
first touch. The shape — a correct length of zeros — is why neither the app
nor the syscall layer could notice. Every affected page in the run was in
the mmap arena (`mmap_default_va` upward), which the clone covers with the
identity overlay exactly like kernel RAM.

Two further consequences were observed or follow directly:

- **The store went somewhere real.** Where the overlay's twin is RAM, the
  bytes land in kernel-owned physical memory: `sys_mmap` honors any aligned
  address hint and only rejects collisions with *the process's own* regions
  (`mmap_collides`), so EL0 could steer a kernel store into RAM it does not
  own. With the Device twin (the case measured) the store was dropped.
  **[inferred]** from the descriptor + the mmap-hint validation; the RAM
  variant was deliberately not executed.
- **Nothing in the app could detect it.** The byte count was right, the
  syscall returned success, and the zeros are indistinguishable from a
  legitimately empty file.

## Decision

1. **`uaccess.copy_out` proves its destination before it stores.** For every
   4 KiB page of `[address, address+len)` it requires an EL0-visible leaf
   (`mmu.leaf_el0_visible`) in the calling process's own root, *before* the
   uaccess window opens; a page that has none is demand-populated, and a
   page that cannot be populated refuses the whole copy with `EFAULT`
   having touched nothing.
2. **One resolution, shared with the fault path.**
   `exceptions.populate_user_page` is the single place that decides what a
   process's page is (mmap region prot, or the stack aperture), used by
   both `try_handle_page_fault` Case 2 and the copy path — the syscall path
   and the fault path can no longer disagree about a VA.
3. **The check lives behind a seam, not in `uaccess`.** Proving a page
   needs the process registry, the page allocator and the kernel domain
   lock, none of which belong in that leaf module (it is imported by
   `exceptions`). `uaccess.resolve_write_pages` is armed once at boot by
   `exceptions.init`, exactly like the IRQ/SVC/fault dispatchers.
4. **A refusal is `EFAULT` and is counted.** `uaccess`'s stats gain
   `unbacked` (copies refused because a destination page was not the
   process's), printed by the monitor's `uaccess` diagnostic: **0 is the
   healthy value**, and a non-zero one names a store that the overlay would
   have swallowed.
5. **Locking follows the canonical order.** The resolver takes only what
   this core does not already hold (`svclock.acquire_missing(kernel)`):
   `copy_out` runs under the caller's own domain lock (FILE for a read,
   KERNEL for mmap/pipes), and the canonical order ends with `kernel`, so
   the nested take is never a same-core self-deadlock.
6. **Host test binaries are unaffected.** There are no user roots and no
   live process off-guest, so the resolver is a no-op there and the
   primitives keep their host contract.

Rejected alternatives:

- **Stop the clone from shadowing the mmap arena.** The root is built at
  exec, before any mmap region exists, and the arena's VA range is chosen at
  runtime (`sys_mmap` hints) — the clone cannot know which VAs to leave
  unmapped. It would also break the kernel's own access to RAM under the
  task's root wherever the two overlap.
- **Let the store fault and return `EFAULT`.** An EL0-visible leaf for a
  fresh mmap page is missing, not forbidden: the Go runtime reads into
  freshly reserved arenas, so refusing would break the process instead of
  filling it. Populating is the semantic the EL0 fault path already
  implements.
- **Map pages eagerly in `sys_mmap`.** The runtime reserves up to 1 GiB per
  call; eager mapping is the memory blow-up demand paging exists to avoid.

## Consequences

- **Guest reads into fresh buffers work.** The read helper's workaround in
  `user/go/selftest` is deleted; the M61c `intake` case now reads a
  host-seeded fixture into a page EL0 has never written and requires the
  exact bytes back, so the class-B gate is the regression test.
- **The overlay is never a store target.** The EL0-steerable "kernel store
  into physical RAM" path above is closed by construction: only pages the
  process's own root exposes to EL0 are written.
- **`copy_out` may allocate.** A copy can now take the kernel domain lock
  and fault in a page; allocation failure is `EFAULT`, never a silent
  success. Copy sizes in this kernel are small (staging buffers), and the
  leaf test is a page-table walk per destination page.
- **Unchanged on purpose:** a page that already has an EL0-visible leaf —
  including a COW (`sw_cow`) leaf — is copied into exactly as before, so
  the COW/`shared_mmap` semantics of M29/M33 are untouched. The
  pre-existing aliasing of user apertures over physical addresses (a
  process's VA and the kernel's identity twin of the same number) is a
  property of claim 5804, not of this decision.
- **Acceptance.** Kernel host tests (`mmu.leaf_el0_visible`,
  `exceptions.populate_user_page`, the resolver seam in `uaccess`), `just
  gate go-selftest` PASS with the workaround removed, and the live
  `uaccess` line `… validation_faults=1 unbacked=0` asserted exactly by
  `live-uaccess` and `live-addrspaces`.
