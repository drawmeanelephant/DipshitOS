# Claim: Harden the multiagent coordination tooling

- **Owner:** buffy (`freebuff/make-sure-git-is-current-first-18548850-6288-40ff-bca2-007971e567ac`)
- **Prompt / plan:** inline — see Notes (coordination-tooling hardening)
- **Scope:** `tools/status/refresh-indexes.sh`, `tools/status/claim-id.sh` (new), `tools/verify-coordination.sh`, `docs/claims/` instructions, coordination test + `just`/CI wiring
- **Depends on:** —
- **Status:** ✅ done 2026-08-08 — escaping, deterministic claim IDs (gate-enforced 0024+), structural table validation, and 15 positive/negative tests landed; all coordination gates + verify-mmu-debt pass (log entry documents exact before/after)

## Notes

Goal: harden the multiagent coordination tooling.

1. **Escape generated table-cell content.** `refresh-indexes.sh` interpolates
   claim Owner/Status text and log titles into Markdown table rows with no
   escaping; a literal `|` (or `\`) in that content silently widens/corrupts
   the generated index tables. Escape `|` → `\|` and `\` → `\\` in every
   generated cell.
2. **Collision-resistant claim IDs.** The sequential "next NNNN" convention
   already collided once: claim 0013 was claimed concurrently by two agents
   (10:27 serial-discovery vs 15:18 status-reverify) and the loser had to be
   manually renumbered to 0014 (commit `be811cb`). Replace it with a
   deterministic ID — `NNNN = cksum(branch:slug)` mapped into `[0024, 9999]`
   — computed by the new `tools/status/claim-id.sh`. Legacy claims 0001–0023
   are grandfathered; 0024+ is enforced by `verify-coordination.sh`, so a
   hand-picked sequential number can no longer slip through.
3. **Structural validation of generated Markdown.** `--check` only diffs the
   tables against the generator's own output, so consistency with a broken
   generator passes. Add a cell-count check per row (honoring `\|` escapes)
   to `refresh-indexes.sh --check`, which `verify-coordination.sh` inherits.
4. **Tests.** Add `tools/status/test-coordination.sh` with positive and
   negative cases: a status containing `|` must not break the index; a raw
   `|` in a table row must fail the gate; a hand-sequenced 0024+ claim must
   fail the gate; `claim-id.sh` must be deterministic.

Verified by: `refresh`, `--check`, `verify-coordination.sh`,
`test-coordination.sh`, and deliberate negative cases.
