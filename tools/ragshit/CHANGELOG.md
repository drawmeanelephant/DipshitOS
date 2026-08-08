# Changelog

All notable changes to Ragshit are recorded here, following the evidence
rules: entries describe what was built and what was verified.

## [0.1.1] - 2026-08-08

Dogfood-hardening of `ragshit review` from real DipshitOS output (claim
3320). Accounting, coverage, stale hints, and shell importance.

### Fixed

- **Packet-size accounting (A):** `actual_size` and
  `selection_summary.actual_chars` now equal the final rendered Markdown
  length; the Markdown `Actual size` header and `budget utilization` body
  line agree; the raw sum of candidate block costs is reported separately
  as `selection_summary.candidate_cost_chars`.
- **Document/decision coverage (B):** a selected candidate satisfies
  `relevant_docs` / `decision_docs` when its own path is in that universe,
  even when it entered as changed-symbol/chunk/high-risk; a directly
  changed doc or claim now counts. The universe also includes changed
  doc-like paths.
- **Generic-symbol stale filter (C):** project-name, ubiquitous, generic
  heading, short shell-assignment, and short config-key symbols are
  excluded from stale-hint generation (reasons exposed as
  `stale_filtered`); specific identifiers still warn.
- **Shell structural importance (D):** assignments inside a function body
  fold into the function chunk; top-level one-line assignments are
  low-value, never mandatory, and lose budget priority to functions.
- **Language-tagged fences (G):** candidate blocks emit ```zig / ```shell /
  ```markdown fences with a plain-fence fallback for unknown/plaintext.

### Added

- Real-repository dogfood assertions (`tests/test_dogfood_review.py`) that
  fail on accounting disagreement, false-zero doc coverage, project-name
  stale avalanches, or shell assignments dominating selection.
- Regression tests for A/B/C/D/G (`tests/test_review_hardening.py`).

## [0.1.0] - 2026-08-05

Milestone zero: local Git-aware context and retrieval engine.

### Added

- `ragshit init`, `index`, `status`, `query`, `bundle`, `diff`, `inspect`,
  and `doctor` commands.
- Git-aware file discovery honoring `.gitignore`, `.ragshitignore`, and
  tracked-file status.
- Incremental SQLite index (WAL mode, foreign keys, transactional runs)
  with SQLite FTS5 lexical search and a documented LIKE fallback.
- Parsers: Markdown (heading hierarchy with ancestry), source heuristics
  (Zig, Swift, Python, shell, C, assembly, linker scripts, TOML, YAML,
  JSON), and plain text / log windowing.
- Hybrid retrieval: exact path, partial path, exact symbol/heading, exact
  phrase, FTS5 BM25, changed-file boost, changed-line overlap, recency,
  and decision-document priority, with deterministic tie-breaking and
  `--explain` score breakdowns.
- Markdown and JSONL context bundles with provenance boundaries, budget
  enforcement, and omission reporting.
- Embedding provider interface with a disabled implementation; no network
  calls in milestone zero.
- Doctor command verifying repository, configuration, index integrity,
  FTS5 availability, and stale-index conditions.
- DipshitOS acceptance script (`tests/acceptance/acceptance.py`).

### Not implemented (milestone-zero exclusions)

- No real embeddings, no LLM calls, no daemon mode, no web UI, no editor
  extension, no remote repositories, no authentication, no cloud storage,
  no code generation, no automatic file modification.
