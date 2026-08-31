# Claim: WMS10 split — shared-anon mmap ADR (0016) + gated cards into the next milestone

- **Owner:** buffy (`agent/buffy/wms10-split-adr`)
- **Prompt / plan:** `docs/decisions/0015-window-server-render-seam.md` (D5), `docs/march-m32-wm-migration.md` (WMS10 card, issue #630)
- **Scope:** Post-M32 planning only — no kernel/userland code. Author ADR 0016 (cross-process shared anonymous mmap / seam B), split WMS10's scoping seed (issue #630) into gated cards in a new next-milestone march tracker, and retire WMS10's deferred row from the M32 tracker.
- **Touches:** docs/decisions/0016-shared-anonymous-mmap.md docs/march-m33-seam-b-pixel-ownership.md docs/march-m32-wm-migration.md docs/status.md docs/claims/9612-wms10-shared-anon-split.md docs/logs/agent-buffy-wms10-split-adr.md
- **Depends on:** WMS1–WMS9 landed and closed (issues #621–#629); M32 complete
- **Heartbeat:** 2026-08-30
- **Status:** ✅ done

## Notes

WMS10 (issue #630) is the sole open M32 card and is explicitly a
scoping/tracker card deferred by ADR 0015 D5. Its dependencies (WMS1–WMS9) are
all closed. This claim does the *planning* half of what the issue's "next
milestone seed" calls for — author the security ADR for cross-process shared
anonymous mmap, split the seed's four checkboxes (shared-anon mmap, surface
handoff, damage tracking, perf proof) into real gated cards in a new
next-milestone march tracker, and move WMS10 out of the M32 tracker. No code.

The ADR is grounded in the existing M29 foundation: `mmu.map_user_cow_page` +
`sw_cow` (bit 55) already give EL0-RO + COW-promote pages, and `sys_mmap`
(slots 63/64) is the per-process anonymous mapper that shared-anon generalizes.

## Result (2026-08-30)

Delivered: `docs/decisions/0016-shared-anonymous-mmap.md` (DRAFT ADR: D1
slot-64-flag shared-anon + SharedRegion refcount from M29 COW, D2
capability/security rules — owner-write / WM-RO, revocation on close, trust
boundary, D3 compose-N-one-present surface handoff, D4 non-goal of
mapper-owned writable COW); `docs/march-m33-seam-b-pixel-ownership.md`
(SB1–SB6 gated cards with dependency ordering); M32 WMS10 row marked ➡️ moved
to M33; status.md M32-done + M33-proposed. Zero code changes.
