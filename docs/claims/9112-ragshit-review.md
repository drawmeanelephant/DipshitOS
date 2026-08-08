# Claim: Ragshit `review` — deterministic budgeted reviewer context packet

- **Owner:** buffy (`freebuff/ragshit-review`)
- **Prompt / plan:** task prompt 2026-08-08 — `ragshit review <repo> <git-range> --budget-chars` with budgeted selection, coverage model, redundancy control, mandatory content, truncation, JSON schema, tests, baseline, dogfood; plan in `artifacts/review-plan.md`
- **Scope:** `tools/ragshit/` only — new `review` package (candidates, coverage, scoring, selection, truncation, report, baseline), CLI wiring, tests, docs (`tools/ragshit/README.md`, `tools/ragshit/docs/*`), one claim/log, narrow justfile alias
- **Depends on:** `tools/ragshit/impact` (inventory, symbol mapping, neighborhood, scoring, stale) — reuse as input; `tools/ragshit/indexing` for chunk access
- **Status:** ✅ done 2026-08-08 — `ragshit review . HEAD~5..HEAD --budget-chars 30000` deterministic budgeted packet; 124 passed, doctor ok, coordination ok, dogfood HEAD~1/~5/~10 at 10k/25k/50k under artifacts/review-packets/; baseline comparison measurably improved

## Notes

Implements `ragshit review . HEAD~5..HEAD --budget-chars 30000` as a deterministic context-selection problem (not another search). Reuses existing indexing and impact analysis. Must stay under hard budget, define explicit coverage dimensions, implement greedy weighted set cover with redundancy penalties, reserve mandatory content safely, support --explain and --json (ragshit.review/v1), handle stale index HEAD, safe truncation, determinism tests, baseline comparison, and dogfood on HEAD~1/~5/~10 at 10k/25k/50k. No LLM, no network, no embeddings.
