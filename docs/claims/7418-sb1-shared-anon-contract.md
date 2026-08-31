# Claim: SB1 — accept ADR 0016, freeze the shared-anon encoding, unit-test the D2 rule

- **Owner:** buffy (`agent/buffy/m33-sb1-shared-anon-contract`)
- **Prompt / plan:** `docs/march-m33-seam-b-pixel-ownership.md` (SB1 card), `docs/decisions/0016-shared-anonymous-mmap.md`
- **Scope:** M33 SB1 (phase 0 — contract). Accept ADR 0016 (DRAFT→ACCEPTED), resolve its open items (flag-vs-new-slot, `SharedRegion` table shape, handle encoding), freeze the shared-anon ABI encoding in ADR 0007 (reserve a `MAP_SHARED` flag bit on `sys_mmap`, slot 63 — no new syscall slot), write the D2 security/capability review, and add a host-tested `shared_region.zig` kernel module encoding the D2 authorization + revocation-to-zero rule as the frozen spec SB2 implements against.
- **Touches:** docs/decisions/0016-shared-anonymous-mmap.md docs/decisions/0007-syscall-abi.md kernel/src/shared_region.zig kernel/src/syscall.zig tools/verify-unit-tests.sh docs/march-m33-seam-b-pixel-ownership.md docs/claims/7418-sb1-shared-anon-contract.md docs/logs/agent-buffy-m33-sb1-shared-anon-contract.md
- **Depends on:** ADR 0016 drafted + M33 tracker landed (claim 9612, PR #684); `main` `9b7176c`
- **Heartbeat:** 2026-08-30
- **Status:** ✅ done

## Result (2026-08-30)

Contract card delivered — the D2 revocation rule is live and host-tested BEFORE
the capability is built. All observed green (`zig test shared_region`, full
`just test`, fmt, coordination, BSS budget):

- **`docs/decisions/0016-shared-anonymous-mmap.md` → ACCEPTED.** Wrote the D2
  security review (requestor-vs-owner, read-only-for-WM, revoke-on-close,
  trust boundary) and resolved the open items: prefer the flag over a new
  syscall slot; `SharedRegion` descriptor keyed by a kernel-issued integer
  handle; `max_shared_regions` BSS bound.
- **`docs/decisions/0007-syscall-abi.md` amendment.** Reserved `M33_MAP_SHARED`
  (bit 16) in `sys_mmap` (slot 63) flags; NO new dispatch-table row (the ADR
  0013 reserved posture holds until SB2 wires the handler).
- **`kernel/src/shared_region.zig`** — pure policy module (no MMU/page-table
  touch): `create` (requestor-vs-owner), `authorize_read` (owner granted,
  WM granted RO, non-WM peer refused, writable peer never allowed),
  `grant_read`/`drop_read` (RO refcount), `drop_owner` (revoke-every-peer +
  free descriptor). 6 host tests pin owner-write / WM-read-only /
  non-WM-peer-deny / revoke-on-teardown / refcount-to-zero / stale-handle isolation.
  Registered in `tools/verify-unit-tests.sh`.
- **Pre-merge review (claim-7418, this claim):** fixed the peer-only writable
  guard (`authorize_read` checks the owner identity FIRST so an owner-write
  request is `.grant`, never `.writable_refused`); pinned SB2's mapping duty
  (a `.grant` for the OWNER is permission-to-keep, NOT an instruction to map a
  redundant `sw_cow` leaf); documented `.capacity` as the create-side signal
  (`authorize_read` never returns it); guarded `next_handle` wrap-to-0. ADR 0016
  records the review; ADR 0007's error contract already scoped `EINVAL` to a
  non-owner requestor, consistent with the fix.

## Notes

SB1 is the milestone's risk-front-loaded gate ("ADR ACCEPTED + slot reserved;
D2 revocation rule unit-tested"). This claim does exactly that WITHOUT
implementing the shared-anon capability (that is SB2): the D2 rule module is
the frozen, runnable spec SB2 wires into `sys_mmap` (owner-write leaf under
one root, WM-RO `sw_cow` leaf under the peer root, `unmap_user_page` on
teardown). No new syscall slot was consumed — the `M33_MAP_SHARED` flag bit
rides slot 63 and the dispatch table stays 128 rows until SB2 registers the
handler. Zero code touches the MMU.
