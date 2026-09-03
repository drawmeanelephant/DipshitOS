# Claim: M37 desktop-quality scoping — split #821 into gated cards

- **Owner:** t3code (`t3code/bfd813db`)
- **Prompt / plan:** `docs/desktop-quality-scoping.md`
- **Scope:** Scoping only — turn issue #821 (umbrella) into a GH milestone 24 / M37 proposal with 5 gated cards (DQ1–DQ5); no production code changes
- **Touches:** docs/claims/8459-m37-desktop-quality-scoping.md, docs/logs/t3code-bfd813db.md, docs/desktop-quality-scoping.md, docs/march-m37-desktop-quality.md
- **Depends on:** —
- **Heartbeat:** 2026-09-03
- **Status:** ✅ t3code/bfd813db

## Notes

Issue #821 bundles four workstreams (god-menu completion, tab chrome render,
tab mouse interaction, design tokens + snap guides) plus its own verification
plan. Phase 1 (claim 7154, commit `1d80f50`) already landed the God Menu
overlay skeleton in `user/src/wnd.zig` with hardcoded sections. This claim
drafts the milestone split (scoping doc + march tracker + issue bodies) so
each card gets its own gate and its own editor per `AGENTS.md`. Verified by
`verify-coordination.sh`; no guest behavior changes.
