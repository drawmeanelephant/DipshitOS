# WMS10 (Seam B) — scoping sketch and gated card split

Status: **PROPOSAL (scoping seed for issue #630)** · Date: 2026-08-30 ·
Derived from: ADR 0015 D5 (seam B, deferred), M29 COW/mmap machinery, WMS2
render-server register, WMS9 span-batching measurements.

> This is the design sketch issue #630 asks for: it turns the five scoping
> seed checkboxes into **five gated cards**, ordered so each card lands a
> provable increment on top of seam A (ADR 0015 D1) without re-architecting
> it. It is NOT a commitment to start — per the issue, seam B is post-M32.

## Current-state survey (what seam B builds on)

- **Per-process mmap exists but is strictly private** (`kernel/src/syscall.zig`
  slots 63/64, `handle_mmap`/`handle_munmap`): pages allocated per-process,
  recorded in `process.zig` `mmap_regions` (max 8) + `dynamic_pages`
  (max 128/proc), zero-filled on demand or MAP_POPULATE, freed via
  `unref_page` on munmap/process exit.
- **COW machinery exists** (`kernel/src/exceptions.zig try_handle_page_fault`,
  `kernel/src/mmu.zig map_user_cow_page`/`set_user_leaf_writable`, `sw_cow`
  software bit 55): refcounted physical pages (`kernel/src/alloc.zig`
  `shared_pages` table, 256 entries, `ref_page`/`unref_page`/
  `page_refcount`), fault-driven copy-on-write, TLB invalidation per VA.
- **The render server** (`kernel/src/wm_server.zig` + slot 65 `sys_wmctl`)
  already separates policy from blit; kind-18 `COMPOSITE_TICK` pacing; the
  kernel owns per-window back-buffers (`user_bufs`, 4 × 512×424×4 B ≈ 868 KiB
  each, ~3.4 MiB total) and blits them in `composite()`.
- **WMS9 (merged)** collapsed per-pixel fills to batched spans on slot 46 —
  the syscall-count baseline seam B improves on is recorded in
  `artifacts/wms9-fill-reduction.md`.
- **Frozen slots 13/14** (`sys_win_fill`/`sys_win_present`) remain the
  unmigrated-app fallback; seam B must not break them.

### Sizing facts that shape the design

- One user window back-buffer = 512×424×4 B = 868,352 B = **212 pages**.
- 4 user windows = **848 pages** of shared-table entries; the current
  `shared_pages` table holds only **256 entries** → must grow (or index by
  region, not page).
- `max_dynamic_pages` is 128/proc → a 212-page shared window buffer cannot be
  tracked per-process with today's table; seam B needs its own region-based
  accounting, not per-page dynamic-page records.
- `max_mmap_regions` is 8/proc — enough for a handful of surface mappings.

## Design sketch

### 1. Shared anonymous mmap (the MMU fundamental)

New primitive: **`sys_mmap_shared(key, len, prot)` / `sys_mmap_attach(key,
addr_hint, len, prot)`** — or a slot-64 flag (`MAP_SHARED = 0x01`) plus a
key-carrying variant. Recommended shape:

- A **shared-memory object table** in the kernel (`kernel/src/shm.zig`):
  fixed BSS table of N shared regions, each `{ key: u64, owner_pid, pa_base,
  pages, refcount, prot }`. Keys are 64-bit values minted by the kernel on
  create (not guessable: `csprng`), so a key *is* the capability token.
- **Creation:** owner calls `sys_shm_create(len)` → kernel allocates `pages`
  physical pages, zeroes them, refcount = 1, returns the key.
- **Attach:** another process calls `sys_shm_attach(key)` → kernel maps the
  SAME physical pages into the caller's TTBR0 space at a kernel-chosen VA
  (reuse `next_mmap_va`), increments refcount, records an `MmapRegion` with a
  new flag `MAP_SHARED` so the existing demand/teardown paths recognize it.
  Permission model: RO attach allowed for anyone holding the key; RW attach
  only if the owner granted write (capability bit stored in the table row).
- **Lifetime:** pages are owned by the shared-region table, not by either
  process. Process exit unmaps its mappings and decrements refcount (the
  existing `unref_page` loop in process teardown handles this once regions
  are flagged shared); the region and its pages are freed when refcount
  reaches 0 **or** the owner explicitly destroys it. If the owner dies first,
  the region stays alive for remaining attachers (the buffer outlives its
  creator — required for the WM to keep compositing a dead app's last frame).
- **MMU work:** `mmu.map_shared_page(root_phys, va, pa, writable)` —
  mechanically the existing `map_user_page`; the new part is *bookkeeping*
  (two address spaces pointing at one `pa` must not double-free). The M29 COW
  fault path must skip `sw_cow` handling for shared-region pages (a write to
  a shared RW page is normal, not COW): shared pages are mapped writable
  directly, never via `map_user_cow_page`.
- **TLB:** `invalidate_tlb_va` is per-VA and inner-shareable — sufficient,
  since the two mappings are at different VAs in different TTBR0 spaces.

### 2. Surface handoff (WM composes from app-owned buffers)

- New `sys_wmctl` subcommand (or WMRPC kind): **SURFACE_BIND** — a migrated
  app tells the kernel "window N's pixels live in shared region K"; the
  kernel validates ownership (caller owns window N, holds attach rights on K)
  and records the binding in the window descriptor.
- `composite()` changes for bound windows: instead of painting from
  `user_bufs[idx]`, blit from the shared region's physical pages (kernel can
  address them directly — they are kernel-allocated physical pages).
- **Frozen slots keep working:** unbound windows keep using `user_bufs` +
  slots 13/14 exactly as today. Migration is per-app, opt-in, reversible
  (SURFACE_UNBIND restores the back-buffer copy).
- The WM's present path is unchanged: it still issues REQUEST_PRESENT; the
  kernel still composites + transfers + flushes. Zero-copy comes later
  (damage card); this card only removes the fill-syscall copy step.

### 3. Damage tracking

- Apps self-report dirty rects: `sys_surface_damage(id, rects_ptr, n)` —
  app records which regions it painted since last present. Kernel ORs them
  into a per-window damage list (fixed BSS ring, e.g. 16 rects/window).
- `composite()` for bound windows blits only damaged rects (intersected with
  the window rect and occlusion rules); a full-window present falls back to
  today's behavior when the damage list is empty-but-dirty.
- Replaces the per-rect fill dirty-flag semantic the kernel owns today
  (`win.dirty`): the flag becomes "app declared damage", not "kernel saw a
  fill".

### 4. Security model (ADR before code)

- A shared region key is a **capability**: possession = permission. The ADR
  must decide: (a) can a key be transferred over IPC mailboxes (yes — that is
  how the WM learns about surfaces; keys ride the existing 64 B WMRPC frame
  or a new SURFACE_BIND message)? (b) revocation on window close — kernel
  invalidates the binding and (optionally) kills remaining attachments;
  (c) RO-vs-RW attach bits; (d) audit rule: the kernel never dereferences an
  app's shared pages except through a validated binding.
- Threat: a malicious app mapping another app's surface and scribbling it.
  Mitigation: keys are kernel-minted CSPRNG values, unguessable; transfer
  only via the app's own explicit send; revocation on window close.

### 5. Perf proof

- WMS9's `artifacts/wms9-fill-reduction.md` is the "before". Seam B's payoff
  is **zero-copy present** (no fill syscalls at all — the WM composes straight
  from app memory) and must be measured: fills-per-frame → 0, present latency
  before/after, saved under `artifacts/`.

## Gated card split

| # | Card | Depends | Gate |
|---|------|---------|------|
| S1 | **Shared-anon mmap fundamental** — `kernel/src/shm.zig` object table, `sys_shm_create`/`sys_shm_attach`/`sys_shm_detach` (new slots 66/67/68 or slot-63 flag+key variant — decide in ADR), refcount/lifetime rules, COW-path exclusion for shared pages, host tests (two fake roots mapping one PA, refcount to zero frees) | — | host tests green; two-process attach/detach proven in host test; BSS budget re-run |
| S2 | **Capability/security ADR** — ADR 0016: key-as-capability model, transfer-over-IPC rules, revocation on window close, RO/RW attach bits, audit rules | S1 | ADR accepted and merged |
| S3 | **Surface handoff** — SURFACE_BIND/UNBIND via `sys_wmctl`, `composite()` blits bound windows from shared pages, frozen slots untouched for unbound windows, per-app opt-in migration of one app (WND? EDIT?) | S1, S2 | live gate: bound app renders correctly with WM registered AND shim-only; frozen-slot app unchanged; `verify-vz` green |
| S4 | **Damage tracking** — `sys_surface_damage`, per-window damage rings, `composite()` blits only damaged rects for bound windows, dirty-flag semantic re-owned | S3 | live gate: partial repaint observable (damage counters in monitor row), full present fallback when damage empty |
| S5 | **Perf proof + app migration** — migrate remaining desktop apps to bound surfaces, before/after measurement vs WMS9 baseline, zero-copy present proven (fills-per-frame → 0 for bound apps) | S4 | saved before/after measurement; all M18–M31 gates green |

S1 and S2 can proceed in parallel; S3 is the first card that touches the live
desktop; S5 closes the milestone boundary that issue #630 records.

## Explicitly out of scope (unchanged from the issue)

Everything here for M32. This document is the recorded boundary; the cards
above are the *next* milestone's seed.
