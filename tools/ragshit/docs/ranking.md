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
