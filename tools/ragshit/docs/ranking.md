# Ranking

A chunk's final score is the sum of independent, deterministic per-signal
components. Weights are configurable (`[retrieval]`); the formulas below
use the defaults.

```
score = Σ signals, each additive and clamped:

  path exact           path_match_boost        (4.0)   path == filter or term
  path partial         path_match_boost / 2    (2.0)   filter is a path substring / dir prefix
  symbol exact         symbol_match_boost      (5.0)   structural_name == term (case-insensitive)
  symbol partial       symbol_match_boost / 2  (2.5)   name contains a ≥4-char term or vice versa
  heading exact        heading_match_boost     (3.0)   leaf heading or full ancestry equals a term
  heading match        heading_token_boost × n (≤3.0)  n query terms found as tokens in the heading
                                                       path (prefix-tolerant: 'milestone' matches
                                                       'milestones')
  symbol match         symbol_token_boost × n  (≤5.0)  n query terms found as tokens in the symbol
                                                       (applies when symbol exact did not)
  phrase match         phrase_boost × n        (≤6.0)  n verbatim quoted phrases found in content
  term coverage        coverage_boost × n      (≤3.0)  n distinct query terms (≥ 4 chars) present in
                                                       chunk content when ≥ 2 match — rewards chunks
                                                       addressing multiple aspects of the query
  FTS rank             normalized BM25          (≤8.0)  min-max over the query's lexical result set;
                       bm25 weights: content 1.0, structural_name 2.0, path 2.0
  modified file        changed_file_boost      (2.0)   file in changed ∪ staged ∪ untracked
  changed-line overlap changed_line_boost      (2.0)   chunk line range ∩ changed line range ≠ ∅
  recent change        recent_change_boost     (0.5)   file in last 10 commits
  decision document    decision_doc_boost      (0.5)   query mentions decision words AND chunk is
                                                       markdown or under a 'decision' path
```

## FTS normalization

SQLite BM25 returns negative scores where *more negative is better*, and
the magnitude is unbounded (it depends on idf and document length), so a
fixed offset like `fts_weight + bm25` would zero out the strongest matches.
Instead the BM25 ranks of the query's lexical result set are min-max
normalized into `[0, fts_weight]`: the top lexical match scores
`fts_weight` (8.0), the worst scores 0, and ordering is preserved. The
normalization is a pure function of the (deterministic) result set, so
identical inputs still produce identical scores.

The lexical candidate window is `max(limit * 10, 250)` chunks: retrieval
fetches a generous superset of the final limit so normalization and the
additive boosts see the whole lexical neighbourhood, not just the top
handful of chunks. Chunks outside the window (on very large repositories)
can still be reached through the exact-path/symbol/phrase signals.

## Degraded mode without FTS5

`lexical_like_search` scores a chunk by the number of query terms matched
in content/symbol/heading via `LIKE`, negated and shifted into the same
range. Ordering is (score desc, path, start line, chunk id). Doctor flags
this mode as a warning; results are still deterministic.

## Merging and deduplication

Candidates from every signal are merged by stable chunk id. Overlapping
chunks of the same file are deduplicated: a lower-scoring chunk whose line
range overlaps a kept chunk is dropped unless it earned an exact signal
(path exact, symbol exact, heading exact, or phrase match).

## Deterministic tie-breaking

When scores tie, results order by:

1. relative path (ascending)
2. start line (ascending)
3. chunk identifier (ascending, lexicographic)

Ranking information is never hidden: `ragshit query --explain` prints the
score and every non-zero component.

## Example

```
score: 14.72
  symbol exact: +5.00
  path partial: +2.00
  FTS rank: +3.72
  modified file: +2.00
  changed-line overlap: +2.00
```


## Impact review-priority scoring (ragshit impact)

`ragshit impact` ranks **files** by a deterministic review-priority heuristic (not a bug predictor).
Per-file score is the sum of components, then normalized to 0..100.

```
components (before 0..100 normalization, max theoretical ~42):
  base               3.0 if hunks exist else 2.0 (added) / 1.0
  lines              log2(lines+1)*2, capped 10   — amount of new lines
  symbols            symbols_touched*3, capped 12 — how many indexed symbols the hunks map to
  references         log2(refs+1)*3, capped 9     — centrality: number of index hits (direct-symbol/identifier/doc/test)
  critical_path      8 if kernel/boot/host, 5 if build.zig|justfile or buildlike, else 0
  doc_touched        4 if docs/decisions|hardware-contract|claims is in the changed set
  deleted            6 if file status D
  interface          3 if build.zig|justfile or host/ or boot/src/main.zig
  no_test            4 if impl and not has_test_changed and refs==0 and lines/symbols>0 else 2 if impl and refs<3, else 0
  test_file         -1.5 if path contains "test" (dampens churn-only test files)
score = sum(components)   (rounded 2dp)
normalized = min(100, (score / max(max_score, 20)) * 100)  -> round 1dp
level:  <22 low, 22-44 medium, 45-69 high, >=70 high/critical (kernel/boot/host -> critical)
       high+>=80 also critical
has_rename flag is carried in stats but not scored separately; dirty working tree is noted not scored.
```
All components are exposed per file in both markdown and JSON (`file_scores[].components`).
Normalization uses max 20 as a floor so docs-only changes don't inflate to 100.
Deterministic: all inputs are local (git range, index), sorted, and capped.

## Review budgeted selection (ragshit review)

`ragshit review --budget-chars N` is a deterministic context-selection problem: given
candidate chunks built from `ragshit impact` signals, pick the smallest high-value
packet that still covers the important implementation/tests/docs/claims/risk signals
under a hard character budget.

### Candidate cost

Cost = rendered Markdown block bytes (header `### path:start-end` + `reason/covers/score/provenance`
+ code fence overhead + `content`). Covers, provenance, and fences are counted so `len(markdown)`
is predictable; the final `report_to_markdown` envelope truncation reserves the packet header
and measures real `len(markdown)` (chars) so `--budget-chars` is never exceeded.

### Candidate utility (base)

```
reason weights (base_utility before redundancy/penalties):
  changed-symbol         10.0    the changed function itself (near-mandatory)
  changed-chunk           9.0    hunk-overlapping chunk not already a symbol
  high-risk-file          8.0    one per critical/high file from file_scores
  hardware-contract       7.0    docs/hardware-contract.md excerpt
  test-reference          6.0    test file mentioning a changed symbol
  documentation-reference 5.0    doc mentioning a changed symbol
  claim-reference         5.0    docs/claims/*  |  decision-reference 5.0  |  build-file 5.0
  stale-hint              4.0    doc mentioning changed symbol but not updated in range
  surrounding-context     3.0    adjacent symbol to give caller/transport context
  lexical-related         1.0    weaker shared-token hit

file_priority bonus: min(5.0, file_score/20) added to changed-symbol/changed-chunk/high-risk
when the candidate path is a critical/high file. Stale hints and direct symbol links add +1.
```

### Coverage model

Explicit dimensions counted as `covered / total`:

* `changed_symbols` — distinct changed symbol names from `map_symbols`.
* `changed_files` / `changed_implementation` — files in the git range.
* `high_risk_files` — files where `file_scores.level ∈ {critical, high}`.
* `related_tests` — neighbor `test-reference` paths.
* `relevant_docs` — `documentation-reference / claim-reference / decision-reference / hardware-contract`.
* `decision_docs` — subset under `docs/decisions/`, `docs/claims/`, or `hardware-contract`.
* `stale_warnings` — `path:symbol` from `detect_stale`.

Coverage keys are carried per candidate (`changed_symbol:<name>`, `doc:<path>`, ...)
and `coverage_metrics` counts covered vs universe; one giant file cannot fake full coverage.

### Selection algorithm (deterministic greedy weighted set cover)

1. **Mandatory reserve.** One candidate per changed symbol (`changed-symbol`) and one per
   high-risk file; sorted `(-utility, cost, path, start, id)`. Budget is reserved for
   mandatory first. If mandatory cost alone exceeds the budget, the mandatory pool is
   *safely truncated* (largest content shaved deterministically, provenance kept, omitted
   lines marked) rather than silently dropping a changed function.
2. **Greedy diversity step.** Remaining candidates ordered by `effective_utility / cost` where
   `effective_utility = base_utility * (1 - redundancy_penalty)`. Redundancy penalty 0..0.9
   from line-overlap, token Jaccard, or hash equality with already-selected chunks.
   At each step the max ratio affordable candidate is taken; if it would exceed the budget
   it is rejected as `budget pressure`. Highly redundant candidates whose coverage is
   already fully duplicated are rejected as `redundant` instead of being selected.
3. **Ordering.** All pools are `sorted` with deterministic keys; ties break by
   `(utility desc, cost asc, path, start_line, cid)`. No randomness.

The selector prefers a diverse useful packet (implementation + caller + test + contract + claim)
over five near-identical chunks from the same function.

### Redundancy control

Deterministic local signals (no embeddings):

* line overlap: `overlap / min(len(a), len(b)) > 0.9` → penalty 0.85
* structural identity: same `path+start+end` → penalty 0.9
* content hash equality → penalty 0.9
* normalized token Jaccard (word set of content, lowercased `[a-z0-9_]+`) `≥ 0.85` → 0.8,
  `≥ 0.60` → 0.3. Exposed as `"92% token Jaccard with path:line (reason)"`.

Coverage already covered by selected chunks raises the effective duplication to 100% and
the candidate is rejected as `redundant ... coverage already 92% duplicated`.

### Safe truncation

* Never removes provenance header.
* Keeps the changed region: largest-content-first shaving retains the start of the
  content + appends `"... [truncated N lines omitted]"`.
* Markdown envelope (`_enforce_budget`) reserves `## Review packet` header and truncates
  the tail, closing an open fence if needed, and is recomputed after selection so
  `len(markdown) ≤ budget` always.

### Budget + index-head safety

Budget is a hard envelope; tiny budgets degrade gracefully with truncation and a
`truncated` flag. Index mismatch (`index HEAD != range head`) is surfaced loudly in
both Markdown and JSON and on `stderr`, but does not rebuild the index (existing
conventions). Real wall-clock timing is written to `stderr` only; deterministic
output `timing_ms` is always `0`.

### Baseline

Naive: *take candidates sorted by `base_utility` then path until budget is full* (no
redundancy, no diversity). The diversity selector demonstrably wins on intentionally
constructed cases (more changed-files/symbols/high-risk coverage per budget) and ties
when the naive order is already optimal. Both are computed and reported in the packet
and in JSON (`baseline.improved_dimensions`).

