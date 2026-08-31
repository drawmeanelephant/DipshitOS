# ADR 0016: Cross-process shared anonymous mmap (seam B foundation)

Status: **DRAFT** (proposed) · Date: 2026-08-30 · Milestone: post-M32 (next
milestone, seam B) · Proposed by: claim 9612 (WMS10 split, issue #630)

> **This is a proposal, not an accepted reservation.** It turns ADR 0015 D5's
> deferred seam-B option into the next milestone's foundation. It records the
> design direction + the security (capability) decision so a later claim can
> implement it behind its own gate. No slot is reserved and no code is written
> in this ADR; a future claim ports the freeze form (slot-64 flag or a new
> slot) into ADR 0007 when the implementation begins.

## Context

ADR 0015 chose seam A (render-server): desktop policy moved into a userland WM
server, the kernel is a thin render + input + surface server. That landed
(WMS1–WMS9, issues #621–#629). Seam B — full pixel ownership — stays deferred:
apps render into their **own** mmap'd memory and the WM composes one final
buffer, eliminating per-app kernel back-buffers and per-rect fill syscalls
entirely.

Today `sys_mmap` (slot 63, M29, issue #598) is strictly **per-process**: it
allocates anonymous physical pages and maps them into a single process's TTBR0
root (`syscall.handle_mmap` → `mmu.map_user_page`). Nothing can map one
physical region into two EL0 address spaces. Seam B's first and only true
MMU-scale dependency is closing that gap.

## Enabling seams that already exist

- **M29 COW foundations** (`kernel/src/mmu.zig`): `map_user_cow_page` maps an
  EL0-RO page tagged with `sw_cow` (leaf bit 55); `set_user_leaf_writable`
  promotes it to writable and clears the bit; `get_user_leaf`/`unmap_user_page`
  expose the leaf for teardown. This is exactly the per-page capability shape
  shared-anon needs — one **write** reference plus N **read/ro** references,
  each an independent leaf under its owner's root, with teardown decoupling the
  refcount from `record_dynamic_page` lifetime.
- **Per-process event queues** (`events.zig`): the WM already receives
  `WM_POINTER`/`WM_WINDOW`/`WM_KEY` and owns damage implicitly through `dirty`
  surfaces. Damage tracking (card C) is a WM-side consumption of a flag the
  kernel already carries per surface.
- **Frozen slots**: 12–20 still work for unmigrated apps; slots 63/64 stay
  implemented. Seam B gates on a *new* mmap mode, not on breaking old ones.
- **The render-server boundary** (ADR 0015 D1): policy already split from
  blit, so "compose N shared buffers + one final present" replaces
  `sys_win_fill`/`sys_win_present` *for migrated apps* without re-architecting.

## Decisions

### D1. Mechanism — extend anonymous mmap (slot-64 flag; new slot only if insufficient)

Shared-anon is a **MAP_SHARED-style flag on an otherwise-ordinary anonymous
mmap**, not a new syscall family. The physical pages are allocated once and
mapped into each participant's root via separate leaves. Two answers are left to
the implementing claim:

1. **Slot-64 flag** (preferred): `handle_mmap` gains a shared flag. The
   simplest ABI addition; `sys_munmap` semantics stay per-root (each root's
   leaves are torn down independently; the physical region survives until the
   last ref drops). If the frozen flag namespace proves too tight, reserve a
   new slot instead — the ADR records the *mechanism*, not the exact encoding.
2. **Lifetime/refcount**: a shared region needs a **kernel-owned refcount**
   (physical page refs + a region descriptor), because no single process's
   teardown can free memory another still maps. This is coarser than M29's
   `record_dynamic_page` per-page list — it must be a *sharable* container. The
   simplest correct shape: a small fixed `SharedRegion` table (max_shared BSS)
   keyed by a kernel-issued handle, each entry holding refcount + owner + the
   va/pa set, torn down when the last participant unmaps or dies (the M29
   COW/teardown machinery generalized, as the issue body predicted).

### D2. Capability/security model (the ADR the issue insisted on)

Mapping one process's render surface into another is a **capability**, and the
kernel must decide who may map whose buffer and revoke it on close (the
governing rules, frozen here, implemented in the claim's security review):

- **Requestor-vs-owner.** A shared surface is created (and owned) by the app
  that renders into it; the WM *requests* read access. The kernel grants it
  only to a well-defined peer set — the registered WM server (`wm_server` pid)
  for read-only composition, and (future) explicitly-authorized apps.
- **Read-only for compositors.** The WM maps surfaces EL0-RO. Only the owner's
  root ever holds a writable leaf; `sw_cow` is the natural carrier — the WM's
  leaves are COW/RO, the owner's is writable. A COW fault in the WM address
  space is a kernel error, not a silent copy (shared surfaces are not
  mapper-owned COW — that is D4).
- **Revocation on close/teardown.** When the owner's window closes or the owner
  exits, the kernel unmaps every peer's RO leaves and drops the region
  descriptor (refcount → 0 frees). No peer may retain access past that point —
  a stale WM mirror must not leave dangling access to freed physical memory.
- **Trust boundary.** The WM is trusted (it registers via slot 65 and the
  kernel fans raw input to it), but the security review still bounds it: it
  gets read-only surfaces only, never the owner's writable view, and revocation
  is provable (an implementation must unit-test the close/teardown path before
  the live gate).

### D3. Surface handoff — compose-N-one-present

For migrated apps, `sys_win_fill`/`sys_win_present` hand off to: the app
renders into its shared surface (plain stores); the WM, on each `COMPOSITE_TICK`
(kind 18), copies the RO surfaces it holds into the scanout (or a single
composited back-buffer) and issues the final present. Kernel-side slots stay
frozen and unmigrated apps keep working unchanged. The WM's damage input is the
per-surface dirty flag already carried — re-owned as "the app wrote to its
buffer, mark dirty" instead of "a fill syscall arrived."

### D4. No mapper-owned COW (a deliberate non-goal)

Shared-anon here is a **kernel-enforced shared read** surface, not
`fork()`-style COW-on-write-between-peers. The owner writes; peers read; only
teardown and refcount differ from today's mmap. This keeps the security story
bounded: there is exactly one writer (the owner), so there is no write-fault
policy to multiplex. A future milestone wanting general shared-write mmap is a
separate ADR, not an expansion of this one.

## What this is not

- Not POSIX `MAP_SHARED` compatibility or a libc surface — it is a
  kernel-enforced capability with its own register/revoke rules.
- Not an ABI break: slots 12–20 and 63/64 stay implemented.
- Not a scheduler or uaccess change; `uaccess` write-region registration stays
  owner-side only.
- No code in this ADR — it is a proposal pending the implementing claim.

## Consequences

- Seam B becomes implementable as the binary end-state of the M32 migration:
  apps stop issuing per-rect fill syscalls, the WM owns the final composite.
- The kernel sheds the last per-rect fill hot path for migrated apps (realized
  only in the perf card, measured against the WMS9 baselines).
- A new security surface enters the kernel: one capability must be granted,
  bounded, and revocable — with a dedicated unit test pinning the close path.

## Alternatives considered

- **Full shared-WRITE mmap (both peers writable)**: rejected — unbounded
  write-fault policy, two writers, no single owner to revoke. Out of scope.
- **Single shared buffer per app, WM uses one global**: rejected — no damage
  granularity, no per-window isolation; cards C need per-surface damage.
- **New syscall family for sharing**: costs a reserved slot range up front;
  the slot-64 flag keeps the ABI additive. Prefer the flag until it proves
  insufficient.

## Open items for the implementing claim

- Slot-64 flag vs. new slot — decide after pinning the frozen flag namespace.
- `SharedRegion` table size + handle encoding (kernel-issued integer handle vs.
  the app's mmap va as the key).
- Damage transport shape: does the WM poll dirty flags per tick, or does the
  kernel fan a notify event? (Card SB4 answers this.)
- Refcount container: reuse/augment M29's per-page container vs. a new
  region-level one.

---

_Split from ADR 0015 D5's seam-B option and issue #630 by claim 9612 (2026-08-30)._
