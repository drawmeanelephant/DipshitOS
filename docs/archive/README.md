# docs/archive — archived one-shot prompts, frozen designs, completed roadmap plans

Files here are one-shot agent prompts, designs, trackers, and roadmap
plans from **completed** milestones (prompts, designs, and the M1.5 march
tracker moved here when their milestone closed; the per-milestone
`roadmap-m{N}.md` plans moved here from `docs/roadmap.md` by issue #264 /
claim 2860). The `claims/` + `logs/` subdirectories that used to live here
(completed claim files and per-branch session logs moved from
`docs/claims/` / `docs/logs/`) were **deleted 2026-09-03** when claims
moved to the GitHub issue tracker (label `claim`) — old claim numbers and
log entries survive only in git history. They are history,
not active plans: do not feed them to an agent as a work order, and do
not treat their milestone expectations as current state. Completed
milestones' point-in-time test/audit evidence also lives here
(`ragshit-0176/`, `m3-ragshit-bundle.md` — moved from `artifacts/` by
issue #268 / claim 4516); the files are raw recorded output, so they
carry no banner and must stay byte-identical. The canonical,
always-current answers are `docs/status.md`, `docs/roadmap.md`, and
always-current answers are `docs/status.md`, `docs/roadmap.md`, and
`docs/march-m3.md` — keep completed-work docs out of `docs/` root so the
root holds only active documentation.

**M75b (issue #1671, 2026-09-23) moved the closed-arc scoping docs here:**
`wms10-seam-b-scoping.md`, `crypto-scoping.md`,
`desktop-quality-scoping.md`, `wasm-core-scoping.md`,
`roadmap-post-arc5.md`, `agent-concurrency-plan.md`, and
`concurrency-gameplan.md`. Every inbound link (march trackers, roadmap,
TEAMS, wasm-import-contract, line-of-sight, the `syscall.zig` §8 comment)
was rewritten to the `archive/` path in the same change. **Kept in
`docs/` root (still binding, cited by live code or an ADR):**
`wasm-import-contract.md` (frozen `env.*` surface — `wasm.zig`, tests,
`live-wasm-abi`), `line-of-sight.md` (ZC tooling + ADR 0035),
`host-file-channel-scoping.md` (HF contract — `virtio_custom.zig`, gate
fixtures), `html-renderer-scoping.md` (ADR 0028), `ssh-scoping.md`
(ADR 0025), `trust-scoping.md` (ADR 0024). The march trackers stay in
`docs/` — `status.md` links them as per-arc detail.
