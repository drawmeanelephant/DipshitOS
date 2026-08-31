# ADR 0016: Cross-process shared anonymous mmap (seam B foundation)

Status: **ACCEPTED** (claim 7418, SB1) · Date: 2026-08-30 · Milestone: M33
(seam B) · Proposed and authored by: claim 9612 (WMS10 split, issue #630);
accepted by claim 7418 (M33 SB1, contract card)

> **Accepted 2026-08-30 by claim 7418 (M33 SB1).** This turns ADR 0015 D5's
> deferred seam-B option into the next milestone's foundation. It records the
> design direction + the security (capability) decision, freezes the ABI
> encoding (a `M33_MAP_SHARED` flag bit on `sys_mmap`, slot 63 — resolved by
> claim 7418 in this acceptance), and makes the D2 security rule a runnable,
> host-tested kernel module. The ABI freeze (a `M33_MAP_SHARED` flag bit on
> `sys_mmap`, slot 63, instead of a new syscall slot) and the D2 security
> review land in ADR 0007 + `kernel/src/shared_region.zig` under this claim;
> SB2 implements the actual capability. No new syscall slot is consumed.

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

### D1. Mechanism — extend anonymous mmap; DECIDED: flag on `sys_mmap` (slot 63)

Shared-anon is a **MAP_SHARED-style flag on an otherwise-ordinary anonymous
mmap**, not a new syscall family. The physical pages are allocated once and
mapped into each participant's root via separate leaves. Two answers are left to
the implementing claim:

1. **Slot-64 flag** (preferred): `handle_mmap` gains a shared flag. The
   simplest ABI addition; `sys_munmap` semantics stay per-root (each root's
   leaves are torn down independently; the physical region survives until the
   last ref drops). If the frozen flag namespace proves too tight, reserve a
   new slot instead — the ADR records the *mechanism*, not the exact encoding.
2. **Lifetime/refcount (DECIDED shape — accepted by claim 7418)**: a shared region needs a **kernel-owned refcount**
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
## Open items — resolved by claim 7418 (SB1, acceptance) vs. deferred to a later card

- **Flag vs. new slot — RESOLVED (claim 7418): a `M33_MAP_SHARED` flag bit (16)
  on `sys_mmap` (slot 63).** Frozen in ADR 0007. No new dispatch row. See D1.
- **`SharedRegion` handle encoding — RESOLVED (claim 7418): a kernel-issued
  integer handle** (not the app's mmap va). The mmap va is per-root and can be
  reused/replaced across roots (and a second process maps a DIFFERENT va into
  its own root), so it is not a stable capability identity; a kernel integer
  handle names the region regardless of each root's local va. Frozen in
  `shared_region.create` (returns the handle) and ADR 0007.
- **`SharedRegion` table size — RESOLVED (claim 7418): `max_shared_regions` = 8**
  (the module constant). Seam-B migrates apps one at a time (the WMS7 mailbox
  re-point lever), so 8 live surfaces covers the first stretching pass; SB2
  sizes the actual array from this constant. BSS-bounded, per ADR 0013.
- **Damage transport shape — DEFERRED to SB4** (feature-parity card). Not a
  contract decision; the kernel already carries per-surface dirty.
- **Refcount container — RESOLVED (claim 7418): a NEW region-level refcount in
  `shared_region`**, distinct from M29's per-page `record_dynamic_page` list —
  the coarser, sharable container D1.2 describes. The owner is NOT counted in
  `refcount` (its writable map is the region's creation side and dies with the
  owner); reads are counted, so `drop_owner` returns how many peers were revoked.

## Acceptance — D2 security review (claim 7418, SB1)

Mapping one process's render surface into another is a **capability**. This
review turns D2's governing rules into a runnable, host-tested policy module
(`kernel/src/shared_region.zig`, 6 host tests) that SB2 implements into
`sys_mmap` — the milestone's highest-risk change, tested BEFORE the capability
exists.

The decision table (`shared_region.Grant`), as frozen:

| Requestor | Desired view | Handles | Verdict | Why |
|-----------|-------------|---------|---------|-----|
| surface owner | read/write (its own) | its own `create` | `.grant` (read) at least; writable leaf is the region's creation side, SB2 | the creator always retains its own surface |
| registered WM server | read-only | `authorize_read(wm, h, ro)` | `.grant` | D2 read-only-for-compositors; the WM is the trusted compositor |
| registered WM server | writable | `authorize_read(wm, h, rw)` | `.writable_refused` | a peer NEVER holds a writable view (D2) |
| any non-owner, non-WM app | read-only | `authorize_read(other, h, ro)` | `.not_authorized` | D2 trust boundary: only the WM reads another app's surface |
| anyone, no WM registered | read-only | `authorize_read(*, h, ro, wm=0)` | `.not_authorized` | no compositor seat exists → no peer reads at all |
| anyone, stale handle | any | `authorize_read(*, dead_h, …)` | `.gone` | region torn down; no stale access survives |

**Review fix (claim-7418, pre-merge): the writable guard is PEER-only.** A
writable request from the OWNER is granted (`.grant`), not refused — the ADR
decision table grants the owner read/write of its own surface; the writable
leaf is the region's creation side, mapped by SB2 at create. Only a `want_writable`
request from a NON-owner is `.writable_refused`. `authorize_read` checks the
owner identity FIRST so an owner-write request cannot alias the peer-read-only
guard.

**SB2 mapping duty (must not drift):** a `.grant` for the OWNER is
permission-to-keep, NOT an instruction to map a redundant `sw_cow` RO leaf —
the owner's writable leaf already exists (created with the region). Only
NON-owner granted peers (the WM) get an EL0-RO `sw_cow` leaf from `.grant`.
Mis-mapping an RO/COW view for the owner would hand it a copy-on-write alias of
its own surface instead of its write leaf.

The revocation rule, as frozen and host-tested (`drop_owner`): when the owner's
window closes or the owner exits, EVERY peer read reference is revoked (the
function returns the count revoked so a gate can assert peers were unmapped) and
the region descriptor is freed (refcount 0 → free). `grant_read` on a freed
handle is a defensively-refused no-op — a stale WM mirror cannot re-grant or
retain access to freed physical memory.

The test suite pins exactly this: `capacity bound`, `owner always granted; a
peer is WM-only`, `no WM registered means no peer reads at all`,
`grant_read / drop_read maintain the read refcount`, `teardown revokes every
peer and frees the descriptor`, and `stale handle after teardown cannot
re-grant old peers`. SB2 must map real `sw_cow` leaves only for `.grant`
results and unmap them on revoke.

---

_Split from ADR 0015 D5's seam-B option and issue #630 by claim 9612 (2026-08-30).
Accepted by claim 7418 (M33 SB1, 2026-08-30).
Implemented by claim 8878 (M33 SB2, 2026-08-31): `sys_mmap` slot 63 honors
`M33_MAP_SHARED` (bit 16) — owner `MAP_ANON|SHARED` allocates one region, maps
WRITABLE leaves into the owner's root, registers a `SharedRegion`; the registered
WM attaches by handle (`addr=handle, prot=R, SHARED`) → `authorize_read` (D2:
non-owner RO only) → `ref_page` → EL0-RO `sw_cow` in the WM's OWN root
(`kernel/src/shared_mmap.zig`, wired into the scheduler exit seam); owner
munmap/exit revokes the WM view and frees at refcount 0. Live gate PASS
(`verify-live-sb2-shared-anon.sh`, headless VZ).
Elevated to WINDOWS by claim 3633 (M33 SB3, 2026-08-31): the surface-handoff
card. A user window binds a shared-anonymous surface via
`sys_mmap(addr = M33_SURF_WIN_TAG | window_id, MAP_ANON|M33_MAP_SHARED)` — the
addr-tag reuses SB2's owner-create + peer-attach wholesale, the frozen
`sys_win_open`/`fill`/`present` slots (12-14) stay byte-identical for unmigrated
apps, `composite()` blits from the surface's `pa_base`, and a registered WM
auto-mirrors RO at bind time (the SB2 mirror in the WM's own root).
`M33_SURF_WIN_TAG` = `0x8000_0000_0000_0000` (bit 63) is frozen in ADR 0007.
Live gate PASS (`verify-live-sb3-surface-handoff.sh`, headless VZ): a migrated
app stored `0xAB` with a plain write and the registered WM read it RO — the
parity proof vs the old fill path._

