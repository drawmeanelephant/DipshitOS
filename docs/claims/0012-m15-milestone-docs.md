# Claim: M1.5 march step 20 — close the milestone honestly (outer docs + context snapshot)

- **Owner:** buffy (`agent/buffy/m15-milestone-docs`)
- **Prompt / plan:** `docs/march-m15.md` step 20 ("Close the milestone
  honestly") — planning-first prompt delivered directly (no prompt file in
  `docs/` yet)
- **Scope:** docs-only pointer-level refresh of README.md,
  docs/roadmap.md, docs/architecture.md, docs/testing.md so they describe
  the 2026-08-07 state of `main` (marker ladder, MMU-takeover fix, M1.5
  monitor) and link to `docs/status.md` as the canonical source; regen the
  deterministic context snapshot; close-out checklist logged. No kernel/,
  host/, tools/, build.zig, justfile, or gate changes; `docs/status.md` and
  `docs/march-m15.md` untouched (integrator owns milestone-close prose).
- **Depends on:** claims 0009 (marker ladder) + 0010 (MMU-takeover fix),
  both landed 2026-08-07; all M1.5 code slices (claims 0003–0008)
- **Status:** ✅ done 2026-08-07 — README/roadmap/architecture/testing
  refreshed to the 2026-08-07 reality and pointer-linked to
  `docs/status.md`; `artifacts/context.md` regenerated;
  `verify-coordination.sh` green; close-out checklist logged in
  `docs/logs/agent-buffy-m15-milestone-docs.md`

## Notes

The outer docs were frozen against the pre-marker-ladder world: README
("run gate is blocked by missing serial evidence", "TX-only… no RX path"),
roadmap ("implementation attempted… hardware verification is blocked"),
architecture ("intended… probe (blocked: empty)", "intended kernel terminal
WFE loop (not observed)"), and testing ("Milestone two VZ serial/MMU
takeover gate: blocked"). Claims 0009/0010 changed the facts: the NVRAM
ladder gate exists and passes, the MMU takeover completes on VZ, and the VZ
serial gate's blocker is isolated to the absence of a usable MMIO serial
device (probe runs to completion, `M2_SERIA`). This claim rewrites those
stale spots as pointers to `docs/status.md` and logs what remains before
M1.5 can be tagged.

Verification: `zig build context` regenerates; `bash
tools/verify-coordination.sh` exits 0; every factual claim traces to
`docs/status.md` or a claim file; `git diff` touches only the four docs
plus this claim/log and the generated indexes.

## Outcome (2026-08-07)

All four docs edited with pointer-level changes that link to
`docs/status.md` as the canonical source; no milestone closed, no release
number invented, the VZ serial gate stays honestly unpassed (blocker
isolated to device absence per claims 0009/0010). `artifacts/context.md`
regenerated (323 KiB, deterministic). Parallel work noted: a separate
Freebuff docs-tightening branch (`freebuff/can-you-look-through-the-
documentation-…`) also touches README/roadmap/architecture but is not on
`origin/main`; merges may need reconciliation. Close-out checklist for the
final integrator is logged in `docs/logs/agent-buffy-m15-milestone-docs.md`.
No `[observed]` claim in these edits without claim/status backing.
