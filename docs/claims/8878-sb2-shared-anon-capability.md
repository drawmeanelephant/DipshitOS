# Claim: SB2 — shared-anon mmap capability into sys_mmap (M33)

- **Owner:** buffy (`agent/buffy/m33-sb2-shared-anon-capability`)
- **Prompt / plan:** `docs/march-m33-seam-b-pixel-ownership.md` (SB2 card), `docs/decisions/0016-shared-anonymous-mmap.md` (accepted), `docs/decisions/0007-syscall-abi.md` (M33_MAP_SHARED reservation, claim 7418)
- **Scope:** M33 SB2 (phase 1 — capability). Implement the cross-process shared-anonymous mmap capability behind the frozen `M33_MAP_SHARED` flag (bit 16) on `sys_mmap` (slot 63): the owner creates a `SharedRegion` + allocates the physical pages once + maps its writable leaves; when a WM is registered it grants read to the WM and maps EL0-RO `sw_cow` leaves into the WM's root; owner `munmap`/exit revokes every peer and frees at refcount 0. Honors the reviewed D2 rule exactly. No syscall-slot addition and no MMU change beyond the existing M29 seam.
- **Touches:** kernel/src/syscall.zig kernel/src/shared_region.zig kernel/src/process.zig kernel/src/alloc.zig docs/march-m33-seam-b-pixel-ownership.md docs/claims/8878-sb2-shared-anon-capability.md docs/logs/agent-buffy-m33-sb2-shared-anon-capability.md tools/verify-live-m33-sb2-shared-anon.sh tools/verify-unit-tests.sh
- **Depends on:** SB1 accepted (claim 7418, PR #686) — ADR 0016 + `M33_MAP_SHARED` flag + `shared_region.zig` D2 rule on `main`
- **Heartbeat:** 2026-08-30
- **Status:** ✅ done

## Result (2026-08-30)

Implemented + verified green (`zig build`, full host suite incl. the new
shared_region page-proof tests, fmt, coordination, BSS budget):

- **`kernel/src/shared_region.zig`** — the SB1 policy module gained SB2 state:
  descriptor fields (originally reserved `_pages`/`_va`) now hold `pa_base`,
  `page_count`, `owner_va`, `wm_va`, `wm_root_phys`; the policy functions stay
  pure (the D2 grant/revoke rule is unchanged) but `create`/`drop_owner` drive
  SB2's page bookkeeping via new `attach_owner`/`attach_peer`/`revoke_peers`
  helpers that the syscall layer calls. 6 original + new page-proof tests.
- **`kernel/src/syscall.zig`** — `handle_mmap` (slot 63) honors the frozen
  `M33_MAP_SHARED` bit: owner alloc-pages once, `shared_region.create`, records
  pa/va; if a WM is registered it grants read + maps EL0-RO `sw_cow` leaves into
  the WM root; `handle_munmap` (slot 64) revokes peers on owner teardown; the
  exit path reuses the munmap revoke so a dying owner cannot strand a WM mirror.
- **Host proof (the gate's "two EL0 spaces map one physical region"):** a new
  test builds two roots (owner + WM), maps the same `pa` RW in the owner root
  and RO+`sw_cow` in the WM root, then teardown unmaps the WM leaf + frees.
- **`docs/march-m33-seam-b-pixel-ownership.md`** — SB2 row flipped ✅.

## Notes

SB2 is the milestone's highest-risk card: the first time one physical region is
mapped read-writable in one EL0 root and read-only in another. It is built on
the existing M29 `alloc.ref_page`/`unref_page` + COW `mmu.map_user_cow_page`/
`sw_cow`, extended to region-level, wired through the SINGLE frozen flag (no new
slot). The D2 grant/revoke decisions come from the already-merged, reviewed
SB1 `shared_region` policy module; this claim wires them to the page tables.
Gate: owner write leaf and a WM RO/`sw_cow` leaf exist for the same physical PA;
owner teardown revokes the WM peer and frees.