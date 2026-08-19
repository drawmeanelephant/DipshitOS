# Claim: Hope-chest roadmap map — gas stations from M14 to the M99 destinations

- **Owner:** buffy (`agent/buffy/hope-chest`)
- **Prompt / plan:** `docs/roadmap.md` (the "Wishlist / hope chest" section)
- **Scope:** docs only — a new `docs/hope-chest.md` plus two pointer edits (`docs/roadmap.md`, `docs/status.md`)
- **Depends on:** Milestone 14 plan (PR #180, issues #175–#178)
- **Status:** ✅ done 2026-08-19

## Notes

The maintainer's 20-item wishlist is the destination set, but the roadmap's
gated ladder ends at M14. This claim turns the wishlist's *remaining* items
(13–18, 20) and the distant-mountain list into a tiered **gas-station map**:
immediate miles (Tucson → M14/M15), the crossing to a self-hosted desktop
(California), and the far destinations (Japan → the M99-level mountains:
SMP, 3D, dynamic linking, POSIX compat, browser-grade networking,
USB-everything, self-hosting).

Honesty rules from `AGENTS.md` apply: every tier is a *destination*, not a
commitment; milestone numbers are tentative until a `march-mNN.md` tracker +
issues freeze them; hardware-only claims (e.g. virtio-sound availability)
stay `[inferred]` until observed on VZ; every gas station names the small
program/experience that consumes it (the roadmap meta-requirement).

Verified by: the doc exists and is linked from roadmap.md + status.md, the
wishlist's 20 items are fully accounted for (consumed / mapped / still
distant), and `bash tools/verify-coordination.sh` stays green.
