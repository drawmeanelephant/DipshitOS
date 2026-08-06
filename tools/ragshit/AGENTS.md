# AGENTS.md — rules for working in this repository

These rules bind any AI agent or human contributor working in this project.

## Project identity

- Ragshit is a local, Git-aware repository context and retrieval engine.
- It ships inside the DipshitOS repository at `tools/ragshit/`; it can
  index any local Git checkout.
- Its first real customer is the DipshitOS repository; DipshitOS-specific
  expectations live only in `tests/acceptance/`, never in the core engine.
- Python 3.12+ standard library first; small dependencies only where they
  provide substantial value. SQLite (FTS5 when available) is the index.

## Non-negotiables

- **Retrieval correctness beats feature count.** A query returning the
  wrong file is a bug; a missing feature is a roadmap item.
- **Exact source provenance always.** Every chunk carries path, 1-based
  line range, commit, and score. Never drop a line range to make output
  prettier. Never split a line.
- **Deterministic ranking and output.** Ties break by (path, start line,
  chunk id). Two runs over unchanged sources must produce byte-identical
  bundles — no timestamps, host names, or tool versions in output.
- **No hosted infrastructure.** No network calls, no cloud databases, no
  web services, no daemon mode in milestone zero. Git is read-only.
- **No LLM dependency in the core.** No LLM calls, no code generation.
- **No silent parser guesses.** Structural heuristics record a name only
  when found; parser confidence is stored with every chunk. Never
  manufacture symbol names.
- **No unbounded ingestion.** Respect `max_file_bytes`; skip binaries
  (NUL detection), symlinks by default, and `.git/` / `.ragshit/` always.
- **No indexing secrets.** Never store credentials, tokens, or
  environment secrets in the index, config, or bundles.
- **No architecture expansion without an ADR.** New components or new
  retrieval signals go through `docs/decisions/` first.
- **No embeddings until the lexical baseline is tested.** The
  `EmbeddingProvider` interface exists; a real provider is future work.

## Evidence rules

- State what was directly observed versus inferred. Never present a guess
  as a result.
- Support retrieval-quality claims with the acceptance tests and exact
  ranked output. A command returning results is not proof of quality.
- Run `python -m pytest` before claiming success; save command output
  under `artifacts/` when reporting verification.

## Testing rules

- Tests use temporary repositories with locally configured author
  identity; never depend on a developer's global git config.
- Test: tracked discovery, ignore behavior, Markdown chunking, fallback
  windows, stable chunk ids, incremental indexing, removal, transaction
  rollback, ranking boosts, tie-breaking, bundle budgets, filter errors,
  detached HEAD, no-commit repos, FTS5-unavailable degradation, and CLI
  exit codes.
