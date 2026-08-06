# SQLite schema

The index is a normal SQLite database (WAL mode, foreign keys on) plus an
FTS5 external-content table when FTS5 is available. One database per
repository, default location `.ragshit/index.sqlite3`.

## Tables

### `repositories`
| column | notes |
|--------|-------|
| `id` | stable id: SHA-256 of origin URL, else first commit hash, else dir name |
| `root_path` | display only — never used as an identifier |
| `created_at` | |

### `files`
| column | notes |
|--------|-------|
| `id` | PK |
| `repo_id` | FK → repositories |
| `path` | repository-relative, POSIX |
| `kind` | markdown / source / plaintext |
| `language` | zig / swift / python / shell / c / assembly / linker / toml / yaml / json / markdown / plaintext |
| `content_hash` | SHA-256 of file bytes; drives incremental indexing |
| `byte_size`, `line_count` | |
| `tracked` | git tracked status at index time |
| `last_commit` | last commit touching the file (computed for changed files) |
| `indexed_at` | |

Unique on `(repo_id, path)`.

### `chunks`
| column | notes |
|--------|-------|
| `id` | PK, rowid |
| `chunk_id` | stable id (below), unique |
| `file_id` | FK → files, ON DELETE CASCADE |
| `repo_id` | FK → repositories, ON DELETE CASCADE |
| `path`, `start_line`, `end_line` | 1-based inclusive |
| `content`, `content_hash` | |
| `kind` | section / symbol / document / window / comment / key |
| `structural_name` | symbol or leaf heading when confidently found |
| `heading` | full ancestry path, e.g. `Decisions > D1` |
| `language` | |
| `commit` | HEAD commit at indexing time |
| `confidence` | parser confidence for the chunk (structural: 0.9, whole-file: 0.6-0.8, windows: 0.5) |
| `index_run_id` | FK → index_runs |

### `git_refs`
Branch, HEAD, detached flag, and updated-at recorded at the last index
run (one row per repo).

### `index_runs`
Explicit run metadata: timestamps, status, and the counters reported by
`ragshit index`. This is the only table that legitimately changes between
two runs over unchanged sources.

### `chunks_fts` (FTS5)
External-content table over `chunks`:

```
CREATE VIRTUAL TABLE chunks_fts USING fts5(
    content, structural_name, path,
    content='chunks', content_rowid='id');
```

Kept in sync by AFTER INSERT/DELETE/UPDATE triggers on `chunks`. Searched
with column weights `bm25(chunks_fts, 1.0, 2.0, 2.0)` (content, symbol,
path). `ragshit index` runs `optimize` after each transaction.

## Stable chunk identifiers

```
chunk_id = SHA256(
    repository_id + "\x00" +
    relative_path + "\x00" +
    chunk_kind + "\x00" +
    structural_name + "\x00" +
    content_hash
)
```

Derived entirely from stable source properties — never a random UUID,
never an absolute filesystem path. The same source therefore yields the
same chunk id on any machine and any run, which is what makes two
identical indexing runs produce zero changed records and what makes
`doctor`'s duplicate-chunk-id check meaningful.

## Integrity

`PRAGMA foreign_keys = ON` prevents orphaned chunks at write time;
`doctor` additionally verifies `PRAGMA integrity_check`, duplicate chunk
ids, orphaned rows, stale files, and index freshness against HEAD.
