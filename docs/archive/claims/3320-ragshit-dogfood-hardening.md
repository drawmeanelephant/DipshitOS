# Claim: Ragshit review dogfood-hardening — honest accounting, coverage, stale filter, shell importance

- **Owner:** buffy (`freebuff/you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d`)
- **Prompt / plan:** task prompt 2026-08-08 — fix concrete defects exposed by real `ragshit review` dogfood: (A) packet-size accounting, (B) doc/decision coverage, (C) generic-symbol stale filter, (D) shell symbol importance, (E) virtio BAR-rebase comment verification, (F) dogfood assertion gate, (G, optional) language-tagged fences
- **Scope:** `tools/ragshit/` only (src + tests + docs + README), narrowly necessary justfile alias, coordination claim/log files, and ONE kernel comment correction ONLY if task E proves the comment stale. NO kernel behavior, NO host behavior, NO `docs/status.md`, NO milestone criteria.
- **Depends on:** main with claim 9112 (`ragshit review`) landed (PR #34)
- **Status:** ✅ done 2026-08-08 — A/B/C/D/F/G landed; stale BAR-rebase comment corrected (E); suite 137 passed + 1 skipped, doctor/coordination/portable gates green; evidence under `artifacts/ragshit-dogfood-20260808/`

## Notes

Deterministic claim ID from `bash tools/status/claim-id.sh '<branch>' 'ragshit-dogfood-hardening'` = 3320.

Dogfood reproduction on `HEAD~5..HEAD` at `--budget-chars 40000 --explain` confirmed all reported defects on current main (938d068):

- A: header `Actual size: 39787 chars` (== len of rendered markdown, chars) but Selection-summary body line `budget utilization: 27570 / 40000 (68.9%)` (candidate-cost sum) — the rendered body is stale because report fields are patched AFTER the single render; only the header line is regex-patched.
- B: `decision_docs: 0 / 25`, `relevant_docs: 0 / 39` while claim files, gate-inventory, README, claims README are selected as changed-symbol/high-risk — coverage only counts WHY a candidate was generated (`doc:` covers), not WHAT path it selected.
- C: 20 stale-doc warnings all for the project name `DipshitOS` and generic heading `Current state` — generic-symbol avalanche.
- D: mandatory changed-symbol pool dominated by shell assignments `ROOT`, `TMP`, `pass`, `fail`, `id1`..`id4`, `out`, `seen`, `sum`, `branch`, `slug`, `derived`, `hs` — many selected while meaningful context truncated.
- E: `kernel/src/virtio_console.zig` carries a comment claiming a post-exit BAR rebase below 0x10000 in `virtio_pci_rebase_post_exit`; docs (hardware-contract, claims 0013/0020/0021) say the firmware-assigned BAR is mapped in place and the rebase experiment was abandoned. Verify code truth, then either the smallest comment-only correction or a reported contradiction.

Verification: ragshit suite (129 passed, 1 skipped at claim start), `ragshit doctor`, `ragshit index`, fresh `ragshit review` + `ragshit bundle`, `bash tools/verify-coordination.sh`, plus the portable verification required by main. Evidence under `artifacts/`.
