# Changelog

All notable changes to Ragshit are recorded here, following the evidence
rules: entries describe what was built and what was verified.

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
