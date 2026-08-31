# Log — agent/buffy/m33-sb2-shared-anon-capability

## 2026-08-30 — claim 8878 opened (SB2: shared-anon mmap capability)

Capability card on `agent/buffy/m33-sb2-shared-anon-capability` off `main`
(PR #686 merged). Implements the cross-process shared-anonymous mmap behind the
frozen `M33_MAP_SHARED` flag (bit 16) on `sys_mmap` (slot 63), using ONLY the
existing M29 machinery (`alloc.ref_page`/`unref_page` + `mmu.map_user_cow_page`/
`sw_cow`) at the region level and the reviewed D2 rule from `shared_region.zig`.
No new syscall slot.

## 2026-08-30 — claim 8878 done (capability wired, page-proof host tests green)

Delivered + verified green (`zig build`, full host suite incl. the new
shared_region page-proof tests, fmt, coordination, BSS budget): owner create
path in `handle_mmap` (alloc-pages once, `shared_region.create`, record pa/va,
map owner-writable leaves); WM grant path (`authorize_read` -> `grant_read` ->
`ref_page` + map EL0-RO `sw_cow` leaves into the WM root); revoke on owner
`munmap`/exit (`drop_owner` -> unmap WM RO leaves + unref + free). Host proof:
two roots (owner + WM) map the same physical PA, owner writable + peer RO;
owner teardown revokes the peer. SB2 tracker row flipped. Claim 8878.