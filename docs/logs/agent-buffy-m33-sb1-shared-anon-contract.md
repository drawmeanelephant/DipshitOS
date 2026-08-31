# Log — agent/buffy/m33-sb1-shared-anon-contract

## 2026-08-30 — claim 7418 opened (SB1: shared-anon contract card)

Phase-0 card on `agent/buffy/m33-sb1-shared-anon-contract` off `main` `9b7176c`.
Turns ADR 0016 (DRAFT) into an accepted contract and makes the D2 security rule
a runnable, host-tested artifact WITHOUT implementing the SB2 capability:

- ADR 0016 DRAFT → ACCEPTED; write the D2 security review; resolve open items
  (flag over new slot; `SharedRegion` integer-handle descriptor; `max_shared_regions`
  BSS bound).
- ADR 0007 amendment: reserve `M33_MAP_SHARED` (bit 16) on `sys_mmap` slot 63;
  no new dispatch row (ADR 0013 posture holds until SB2).
- New `kernel/src/shared_region.zig` (pure policy, no MMU/page-table touch):
  the D2 authorize + read-only-grant + revoke-to-zero rule, host-tested and
  registered in the module test list.
- M33 tracker SB1 row flipped to ✅ with the observed result.

## 2026-08-30 — claim 7418 done (ADR accepted, flag reserved, D2 rule host-tested)

Delivered + verified green (`zig test shared_region`, full `just test`, fmt,
coordination, BSS budget): ADR 0016 ACCEPTED with the D2 security review; ADR
0007 reserves `M33_MAP_SHARED` (bit 16) on slot 63 with no new dispatch row;
`kernel/src/shared_region.zig` carries the frozen D2 rule (create /
authorize_read / grant_read / drop_read / drop_owner) with 6 host tests pinning
owner-write, WM-read-only, non-WM-peer-deny, revoke-every-peer-on-teardown,
refcount-to-zero, and stale-handle isolation. The D2 rule module is the spec
SB2 implements into `sys_mmap` (two EL0 roots, one physical region; owner
writes, WM reads RO, munmap/exit revokes peers).
