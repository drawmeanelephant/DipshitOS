# Claim: ci-generated-indexes

- **Owner:** ox-alpha (`t3code/concurrent-agents-merge-conflicts`)
- **Prompt / plan:** user request 2026-08-24 — scale concurrent agents by removing the last guaranteed merge-conflict class: every branch regenerates `docs/claims/README.md` / `docs/logs/README.md` because the gate fails on drift, so those two files collide textually on nearly every near-simultaneous merge (both recent conflicts were inside generated index regions).
- **Scope:**
  1. `refresh-indexes.sh` gains a structure-only validation mode (markers + column count, no sync diff).
  2. `verify-coordination.sh` enforces index *structure*, not *sync* — drift stops failing PRs.
  3. New `.github/workflows/indexes.yml`: on push to main, regenerate indexes and open/update one **auto-merge squash PR** (`indexes/bot-regenerate`) — branch protection forbids direct pushes (no-bypass ruleset per docs/branch-protection.md), so a direct bot push was rejected on the first live run; requires `INDEXES_PAT` secret + "Allow auto-merge" enabled.
  4. Docs (AGENTS.md, claims/logs READMEs, TEMPLATE, gate-inventory, testing, status pointers, site pages): branches no longer run/commit the refresh script; resolve-by-regeneration recipe for legacy conflicts.
  5. Test suite: gate tolerates stale committed indexes; `--check` still fails on drift (bot contract); structure enforcement retained.
- **Touches:** tools/verify-coordination.sh, tools/status/refresh-indexes.sh, tools/status/test-coordination.sh, .github/workflows/indexes.yml, AGENTS.md, docs/claims/README.md, docs/claims/TEMPLATE.md, docs/logs/README.md, docs/gate-inventory.md, docs/testing.md, docs/status.md, site/contributing.md, site/claims.md
- **Depends on:** —
- **Heartbeat:** 2026-08-24
- **Status:** ✅ done 2026-08-24 — observed end-to-end on this host: PRs #532/#533/#534 merged; live runs fixed two real failures (no-bypass ruleset rejected direct push → auto-merge PR design; checkout's forced GITHUB_TOKEN header beat the PAT → extraheader unset + `gh auth setup-git`); run 32723105968 pushed `indexes/bot-regenerate`, PR #535 opened, required check passed (macOS build 4m42s), auto-squash-merged as `2954d68`; main's tables now carry the 2599/5069 rows (logs index 93 rows) with zero branch-side churn. Test suite 21/21.

## Notes

Why not keep branch-side regeneration: any file two branches both must
modify collides on merge regardless of discipline; the only safe writer for
a shared derived artifact is a single serialized one (the bot). The local
gate keeps everything that is per-file checkable (claim/log well-formedness,
deterministic IDs, Touches overlap, staleness, status.md tripwires, table
structure). Sync correctness moves to main, where it is meaningful and
machine-enforced immediately after merge.

Verify with `bash tools/status/test-coordination.sh` and
`bash tools/verify-coordination.sh`.
