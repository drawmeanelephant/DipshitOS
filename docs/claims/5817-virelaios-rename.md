# Claim: VirelaiOS rename sweep — retire DipshitOS (issue #676, ADR 0017)

- **Owner:** buffy (`freebuff/okay-i-think-we-need-to-work-through-this-big-one--076be815-d689-40da-9389-cfd56bae921f`)
- **Prompt / plan:** GitHub issue #676 (umbrella) + cards #697 (R1 guest identity), #698 (R2 infra + themes), #699 (R3 test fixtures + golden transcripts), #700 (R4 docs prose + ADR ACCEPTED + post-sweep audit). Milestone 18 — Rename — VirelaiOS.
- **Scope:** Execute the DipshitOS → VirelaiOS rename per issue #676. The issue names "ADR 0016" but `docs/decisions/0016-shared-anonymous-mmap.md` (M33 seam B, claim 7418, ACCEPTED 2026-08-30) already holds 0016, so this sweep writes **ADR 0017** (`docs/decisions/0017-virelaios-codename.md`) and flips it ACCEPTED at landing. The DipshitOS name is memorialized FIRST as a dedicated commit (`docs/archive/dipshitos-name.md`) so the historical reference survives the sweep, per the user's explicit request. Protected/historical locations are untouched: `docs/archive/**`, `docs/claims/**`, `docs/logs/**`, ADRs 0001–0016, `tools/ragshit/CHANGELOG.md`, GitHub repo slug + Pages URLs, `artifacts/**`.
- **Touches:** AGENTS.md, README.md, LICENSE, justfile, build.zig, build.zig.zon, publication-profile.example.json, .github/workflows/**, kernel/**, user/**, host/**, image/**, tools/**, site/**, tests/**, themes/**, docs/status.md, docs/march-*.md, docs/roadmap*.md, docs/testing.md, docs/gate-inventory.md, docs/hardware-contract.md, docs/branch-protection.md, docs/dogfood-m27.md, docs/prompts/**, docs/decisions/0017-virelaios-codename.md
- **Depends on:** —
- **Heartbeat:** 2026-08-31
- **Status:** 🔄 freebuff/okay-i-think-we-need-to-work-through-this-big-one--076be815-d689-40da-9389-cfd56bae921f

## Notes

Mechanical cross-cutting sweep, quarantined to one agent (per milestone 18). The
byte-width invariant holds: `dipshit` ↔ `virelai` are both 8 letters, so
`dipshit>` ↔ `virelai>`, `DipshitOS` ↔ `VirelaiOS`, `dipshit-kernel` ↔
`virelai-kernel`, `DIPSHITOS BOOTLOADER` ↔ `VIRELAIOS BOOTLOADER`, and every
NVRAM variable name (`DipshitM2`, `DipshitC0`, `DIPSHITC`, …) stay
byte-width-identical — exact-byte transcript gates keep their rhythm.

Known coordination note: the sweep's Touches overlap 🔄 claims 2852
(`agent/buffy/docs-pass` — docs/status.md, docs/march-m32-wm-migration.md) and
9731 (`agent/buffy/toolchain-env-check` — tools/env-check.sh, justfile,
AGENTS.md). Both are pre-existing 🔄 claims from other branches; the cross-
cutting rename inherently touches those files. Overlap documented here and in
the branch log; the coordination gate's pairwise check will flag it until
those claims flip.

Verification: `bash tools/verify-unit-tests.sh`, `zig build test-console`,
`zig build image`, `bash tools/verify-coordination.sh`, ragshit pytest, and a
post-sweep `rg -i dipshit` audit proving leftovers exist only in
protected/historical locations (and GitHub URLs).
