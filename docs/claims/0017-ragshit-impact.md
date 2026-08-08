# Claim: Ragshit `impact` — Git-aware change-impact reviewer context

- **Owner:** buffy (`freebuff/ragshit-impact`)
- **Prompt / plan:** task prompt 2026-08-07 — `ragshit impact` implementation; plan in `artifacts/impact-plan.md`
- **Scope:** `tools/ragshit/` only — new `impact` command (inventory, symbol mapping, neighborhood, scoring, stale-doc, bundle/JSON), tests, docs; plus claim/log plumbing
- **Depends on:** — (isolated from kernel/MMU/virtio work; treats `kernel/`, `boot/`, `host/`, `image/` as read-only input)
- **Status:** ✅ done 2026-08-07 — `ragshit impact . HEAD~5..HEAD` deterministic, provenance-backed; tests 99 passed, doctor ok, dogfood HEAD~1/~5/~10 saved under artifacts/

## Notes

Implements `ragshit impact <repo> <git-range>` (`--bundle`, `--json`) as a
substantially smarter reviewer-context command than `git diff --stat`.

Capabilities: machine-readable change inventory (NUL-delimited Git,
renames/added/deleted/modified with new-side line ranges, changed symbols
via indexed chunks), symbol-level impact (nearest enclosing indexed symbol),
reference neighborhood (direct-symbol / identifier-reference /
documentation-reference / test-reference / lexical-related via the SQLite
index, never a fake call graph), deterministic explainable review-priority
scoring (documented formula, component breakdown, tests), review packet
bundle, JSON schema/version, conservative stale-doc heuristic, temp-repo
tests, performance via index reuse. No network, no embeddings, SQLite/FTS5
only, stdlib only.

Verification: existing ragshit suite + new impact tests + `ragshit doctor`
+ `verify-coordination` + dogfood on `HEAD~1..HEAD`, `HEAD~5..HEAD`,
`HEAD~10..HEAD`; reports saved under `artifacts/`. Final report:
`artifacts/impact-final-report.md`.
