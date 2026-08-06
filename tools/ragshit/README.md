# Ragshit

A **local, Git-aware repository context and retrieval engine** for coding
agents and LLM reviewers. It builds a searchable index of a repository and
produces deterministic context bundles with exact file paths, line ranges,
commits, and scores — so an LLM can cite exactly where every claim came
from.

The name is a joke. The retrieval is not.

The tool ships inside the DipshitOS repository at `tools/ragshit/`, but it
indexes any local Git checkout — pass any repository path to the
subcommands.

## What it is

* A CLI that indexes a local Git repository into SQLite (+ FTS5).
* Hybrid retrieval: exact path/symbol/phrase → full-text BM25 → Git-aware
  ranking (changed files, changed-line overlap, recency, decision docs).
* Deterministic Markdown or JSONL **context bundles** — one file you can
  drop into any LLM, with every source chunk bounded and addressable.
* A `doctor` for verifying the index, and a `diff` command that summarizes
  a git range for review.

## What it is not

* Not a chatbot. Not an autonomous coding agent. Not a web service.
* No LLM calls, no network, no hosted vector database, no embeddings in
  milestone zero.
* No daemon mode, no editor extension, no cloud.

## Installation

Python 3.12+ recommended (3.9/3.10 work with a built-in minimal TOML
reader). No third-party dependencies — standard library only.

```bash
# from the DipshitOS repo root (the tool lives at tools/ragshit/):
./tools/ragshit/ragshit --version

# from inside the tool checkout, without installing anything:
./ragshit --version

# or install the console script:
python -m pip install -e .

# or run as a module:
PYTHONPATH=src python -m ragshit --help
```

## Quick start

All subcommands take a repository path; config and index are always
resolved to the **repository root** (via `git rev-parse --show-toplevel`).

```bash
./tools/ragshit/ragshit init .     # writes .ragshit.toml + .ragshitignore at the repo root
./tools/ragshit/ragshit index .    # builds the local SQLite index (.ragshit/)
./tools/ragshit/ragshit query . "ExitBootServices memory ownership"
./tools/ragshit/ragshit bundle . "review milestone two" --output artifacts/review-context.md
./tools/ragshit/ragshit diff . main..HEAD
./tools/ragshit/ragshit doctor .
```

`just ragshit <subcommand> <args>` aliases the launcher from the repo root
(see the DipshitOS `justfile`). `ragshit query` optionally explains its
scoring:

```bash
./tools/ragshit/ragshit query . "BootInfo handoff ABI" --limit 12 --explain
```

## Query syntax

```
ordinary words          lexical search terms
"exact phrases"         verbatim phrase match
path:docs/decisions/    path filter (directory or fragment)
kind:markdown           kind filter (markdown/source/plaintext or a language)
symbol:BootInfo         symbol / heading filter
changed:true            restrict to files with working-tree changes
```

Invalid filters produce a clear error; they are never silently ignored.

## Supported file types

Markdown (heading hierarchy + ancestry), source (Zig, Swift, Python,
shell, C, assembly, linker scripts, TOML, YAML, JSON via conservative
structural heuristics), and plain text / logs (bounded line windows).
Everything preserves exact 1-based line ranges and never splits a line.
Unstructured or unparseable files fall back to 120-line windows with
20-line overlap and a lowered parser confidence.

## Retrieval behavior

Signals, in priority order: exact path → partial path → exact
symbol/heading → exact phrase → FTS5 BM25 → changed-file boost →
changed-line overlap → recency → decision-document priority. Ranking is
fully deterministic (ties break by path, start line, chunk id), and every
score component is visible with `--explain`. See `docs/ranking.md`.

## Configuration

`ragshit init` creates `.ragshit.toml` (index, retrieval weights, bundle
budget, embeddings) and `.ragshitignore`. Tracked files stay eligible even
when `.gitignore` matches them; only `.ragshitignore` can exclude a tracked
file. See `docs/configuration.md`.

## Configuration location

Configuration is per-repository: `ragshit init PATH` writes `.ragshit.toml`
and `.ragshitignore` at the **repository root** (resolved via
`git rev-parse --show-toplevel`), not inside the directory you name —
`ragshit init docs/` configures the whole repository.

## Privacy model

Milestone zero makes **no network calls whatsoever**. Everything — index,
search, bundles — runs locally. Git is only ever invoked in read-only
mode against your own checkout (`rev-parse`, `ls-files`, `status`,
`log`, `diff`). The index lives under `.ragshit/` in the repository and
contains only content and metadata from that repository.

## Current limitations

* Real embeddings are not implemented (interface exists; disabled by
  default). The roadmap's next milestone adds one optional provider.
* Structural parsing is heuristic, not a compiler — symbol names are only
  recorded when confidently found, and parser confidence is stored with
  every chunk.
* Binary files, oversized files (default 1 MiB), and symlinks are skipped
  by default.
* Only the root `.gitignore` is honored; nested `.gitignore` files in
  subdirectories are not read.
* Retrieval quality is validated by acceptance tests against DipshitOS,
  not by LLM judgment.

## Relationship to Git

Git is the authoritative source of repository state: tracked files,
branch/HEAD, changed files, changed line ranges, and history. Ragshit
never recursively walks `.git`, never writes to the repository (except the
`.ragshit/` index and the config files `init` creates), and works with
detached HEADs and repositories with no commits yet.

## Optional future embeddings

The `EmbeddingsProvider` protocol (`embeddings/base.py`) defines the
interface; the disabled provider fails clearly if called. When embeddings
arrive they will be seasoning on top of the lexical baseline, not a
replacement for it. See `docs/roadmap.md`.

## Documentation

* `docs/architecture.md` — component design and data flow
* `docs/configuration.md` — every configuration key
* `docs/ranking.md` — the exact ranking formula
* `docs/schema.md` — the SQLite schema and chunk-id derivation
* `docs/roadmap.md` — what comes next, and what stays out

## License

MIT.
