# Roadmap

## Milestone zero (this release) — local Git-aware context engine

Implemented: repository discovery, parsing and chunking, SQLite index
with FTS5 (LIKE fallback), hybrid Git-aware ranking, Markdown/JSONL
bundles, the full CLI, tests, and VirelaiOS acceptance checks.

Explicitly excluded from milestone zero: real embeddings, LLM calls,
autonomous agents, daemon mode, web UI, editor extension, remote
repositories without a local clone, multi-user server behavior,
authentication, cloud databases, code generation, and automatic file
modification.

## Milestone one (next)

> Add one optional embedding provider and compare hybrid retrieval against
> the lexical baseline.

Steps implied by that milestone:

1. Implement one provider (e.g. a local, deterministic one that needs no
   network — see *Provider options*), behind the existing
   `EmbeddingProvider` protocol.
2. Add an `embeddings` column store to the schema (per chunk, plus a
   provider/dimension row) with a separate indexing path so the lexical
   pipeline is untouched.
3. Add an optional similarity signal to `ranking.py`, weighted far below
   the lexical signals (seasoning, not soup).
4. Add a comparison harness that runs the VirelaiOS acceptance queries
   against lexical-only and hybrid, reporting exact score changes and
   whether any expected path moved.
5. Do not ship a provider that requires a network connection before the
   privacy model is explicitly extended and documented.

### Provider options (not chosen, documented only)

- Local deterministic hashing / TF-style fingerprints (no network, but
  weak semantics).
- An on-device model loaded from a file (no network at query time; model
  distribution problem).
- A hosted embedding API (strongest semantics; violates the current
  no-network privacy model until explicitly adopted via a new ADR).

## Later ideas (not commitments)

- Daemon mode with file-watching incremental reindex.
- Editor extension surfacing retrieved context inline.
- Query result caching and query logs for quality analysis.
- A `reindex` command and automatic reindex on HEAD moves.

## Boundaries

Any architectural expansion (new retrieval signal, new storage backend,
network access, embedding provider) requires an architecture decision
record under `docs/decisions/` before implementation, per `AGENTS.md`.
