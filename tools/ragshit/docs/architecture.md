# Architecture

Ragshit is a pipeline of six layers, all local, all deterministic:

```
discovery → parsing → indexing → retrieval → rendering → (doctor/status)
     │          │          │          │
  git state ────┴──────────┴──────────┘   (read-only git, source of truth)
```

## Components

### `git/` — authoritative repository state
- `repository.py` — root resolution (`git rev-parse --show-toplevel`),
  branch/HEAD, tracked/untracked file lists, recent commits, and a stable
  repository id derived from the origin URL (falling back to the first
  commit hash, then the directory name) — never an absolute path.
- `status.py` — `git status --porcelain=v2` parsing into changed/staged/
  untracked sets plus per-file new-side changed line ranges from
  `git diff --unified=0`.
- `diff.py` — range parsing (`A..B` or `A`), commits, per-file line
  ranges, and *heuristic* diff analysis (decision docs, affected symbols,
  nearby tests, evidence artifacts) that is explicitly labeled heuristic.

### `discovery/` — what gets indexed
- `ignore.py` — gitignore-style matcher (negation, dir patterns, `**`,
  anchoring) over `.gitignore` and `.ragshitignore`. Tracked files
  override `.gitignore`; `.ragshitignore` overrides everything.
- `files.py` — candidate enumeration from `git ls-files` (plus
  `--others --exclude-standard` when `include_untracked`), skipping
  binaries (NUL sniff), oversized files, symlinks, and `.git/`/`.ragshit/`.

### `parsing/` — source-addressable chunks
- `base.py` — chunk model, 1-based inclusive line ranges, overlapping
  window fallback (120 lines / 20 overlap).
- `markdown.py` — heading-hierarchy chunking with heading ancestry
  (`Decisions > D1`), code-fence awareness, document-top chunk, and
  small-section merging (a parent absorbs its subsections only when its
  own body ≤ 3 lines, every subsection ≤ 10 lines, and the subtree ≤ 40
  lines — ADR-style decision sections stay granular).
- `source.py` — conservative per-language declaration heuristics
  (Zig/Swift/Python/shell/C/assembly/linker/TOML/YAML/JSON). Brace
  balancing bounds function/type chunks; leading comments attach to the
  first declaration; unstructured content falls back to windows with
  confidence 0.5.
- `plaintext.py` — whole-document chunk under 120 lines, else windows.

### `indexing/` — SQLite
- `schema.py` — tables `repositories`, `files`, `chunks`, `git_refs`,
  `index_runs`, plus the FTS5 external-content table and sync triggers.
- `database.py` — WAL mode, foreign keys, transactional runs, FTS5 BM25
  queries with column weights (content 1, symbol 2, path 2), and a
  degraded LIKE search when FTS5 is unavailable.
- `indexer.py` — incremental: content-hash skip, reparse changed files,
  delete removed files, one transaction per run, commit only on success.
  Stable chunk ids: `SHA256(repo-id + path + kind + name + content-hash)`.

### `retrieval/` — hybrid ranking
- `exact.py` — exact path, partial path, symbol/heading, phrase candidates.
- `lexical.py` — FTS5 MATCH construction with prefix terms and column
  scoping; LIKE fallback.
- `ranking.py` — additive per-signal scoring (see `ranking.md`),
  deterministic tie-breaking, overlap deduplication.
- `query.py` — query parsing with `path:`/`kind:`/`symbol:`/`changed:`
  filters (invalid filters are hard errors), then orchestration of all
  signals.

### `rendering/` — output
- `markdown.py` / `jsonl.py` — query results and bundles.
- `bundle.py` — budgeted context assembly: exact matches → diff overlap →
  decision docs → low-ranked duplicates dropped → truncation only as a
  final resort, with omissions always reported and unresolved-evidence
  markers scanned from retrieved content.

### `impact/` — change-impact analysis (inputs to `review`)
- `inventory.py` — NUL-delimited `name-status` + `unified=0` hunk parsing.
- `symbols.py` — changed hunks → enclosing indexed symbol (fallback `git show` for deleted files).
- `neighborhood.py` — index-only reference neighborhood (direct-symbol / identifier / doc / test / lexical).
- `scoring.py` — per-file review-priority heuristic, normalized 0..100.
- `stale.py` — docs mentioning a changed symbol but not changed in range.
- `report.py` — `ragshit.impact/v1` JSON + Markdown.

### `review/` — budgeted reviewer packet
- `candidates.py` — deterministic pool with provenance, cost, coverage keys, token sets.
- `coverage.py` — explicit dimensions and `covered/total` metrics.
- `redundancy.py` — line overlap, token Jaccard, hash, structural identity.
- `selection.py` — greedy weighted set cover under hard budget with mandatory reserve + truncation.
- `report.py` — `ragshit.review/v1` JSON + Markdown, baseline comparison, `len(markdown) ≤ budget`.

### `doctor.py`, `cli.py`, `embeddings/`
- `doctor.py` — ten checks (repo, git, config, DB, FTS5, ignore behavior,
  freshness, referenced files, duplicate chunk ids, orphans).
- `cli.py` — nine subcommands (`init`, `index`, `status`, `query`, `bundle`, `diff`, `inspect`, `impact`, `review`, `doctor`) with non-zero exit codes on failure.
- `embeddings/` — `EmbeddingProvider` protocol + disabled provider; no
  retrieval path depends on embeddings.

## Degraded modes

| Condition | Behavior |
|-----------|----------|
| FTS5 unavailable | lexical search falls back to deterministic LIKE scoring, flagged by `doctor` as a warning |
| Python < 3.11 | `tomllib` replaced by the minimal `_toml.py` parser |
| No commits yet | unborn HEAD: empty history, diff vs index+worktree only, everything else works |
| Detached HEAD | works; branch shows as detached |
| Parser finds no structure | overlapping windows with lowered confidence |

## Determinism

All ordering is explicit (`ORDER BY` clauses, sorted() with fixed keys).
Bundle output contains no timestamps, host names, or version stamps, so
identical inputs produce byte-identical bundles. The only timestamped
records are `index_runs` rows (explicit run metadata) and file
`indexed_at` columns, which are never rendered into bundles.
