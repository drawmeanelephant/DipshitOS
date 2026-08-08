# Claim: Ragshit `review` — decision-useful coverage under hard budget truncation

- **Owner:** buffy (`freebuff/start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e`)
- **Prompt / plan:** task prompt 2026-08-08 — `ragshit review . HEAD~5..HEAD --budget-chars 40000 --explain` can report 100% changed-symbol coverage while mandatory-budget truncation reduces a large changed structural symbol to a useless prefix; make coverage claims decision-useful under hard budget pressure without redesigning `review` or broadening it into a whole-repository/task-specific context system
- **Scope:** `tools/ragshit/` only — `src/ragshit/review/` (candidates/coverage/selection/report), regression tests (synthetic + real-repo dogfood), `tools/ragshit/docs/*` + README only if needed, plus this claim/log and generated indexes. NO kernel/host/boot changes. NO `docs/status.md` milestone edits.
- **Depends on:** main with claims 9112 (`ragshit review`) and 3320 (accounting/stale/shell hardening) landed — the packet budget accounting and generic stale-symbol filter are already fixed and must not be reopened
- **Status:** ✅ done 2026-08-08 — anchor-aware truncation + weak/truncated coverage landed (`tools/ragshit/src/ragshit/review/{candidates,coverage,selection,report}.py`, framing-loop plateau fix in `cli.py`); full suite 147 passed / 1 skipped, doctor ok, dogfood at 20k/30k/40k/60k with exact size accounting and byte-identical duplicate runs; before/after packets under `artifacts/ragshit-0176/`

## Notes

Deterministic claim ID from `bash tools/status/claim-id.sh '<branch>' 'ragshit-review-coverage-truncation'` = 0176.

Reproduced defect (before fix): under a tight `--budget-chars`, mandatory changed-symbol
candidates that exceed the budget are line-truncated keeping the START of the structural
chunk; a large changed function like `kernel/src/virtio_console.zig`'s `virtio_pci_init`
(~231 lines) renders as essentially one line while coverage still reports the changed
symbol as fully covered (`changed_symbols: N / N (100%)`). A structurally large symbol
must not be reported as usefully covered merely because one nearly content-free prefix
line survived truncation.

Implemented fix (smallest that solves the observed problem): anchor-aware truncation
that preserves a signature/heading plus the actual changed-line neighborhood (git
`--unified=2` context, `_CTX = 2`) when a mandatory structural excerpt must shrink, plus
an explicit weak/truncated-coverage signal so truncated excerpts are not counted
identically to useful coverage. Truncation pressure is distributed across mandatory
symbols in two phases: shave every excerpt to its useful floor first, then shave the
largest below its floor / drop as genuine last resort. Weak excerpts are excluded from
covered counts, listed in `missing_coverage`, and surfaced in `## Weak / truncated
coverage` + the additive JSON `weak` array. Also fixed the framing-loop plateau: when
every mandatory excerpt already sits at its useful floor, allowance reductions no longer
move the selection, so the loop now jumps below the plateau to keep exact budget
accounting without the envelope. No magic fixed line count; no embeddings/LLM/network;
hard budget retained; determinism retained.

Verification (done): full ragshit suite (147 passed, 1 skipped), `ragshit doctor` all
checks OK, fresh index, real-repo dogfood at 20000/30000/40000/60000 budgets,
duplicate-run byte comparison identical, exact `len(final_markdown)` == `actual_size` ==
`selection_summary.actual_chars` at every budget, envelope never used, before/after
packets under `artifacts/ragshit-0176/` (`before-40000.md` shows `virtio_pci_init` as
one line `p…`; `after-40000.md` renders its signature + the changed region).
