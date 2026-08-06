# Configuration

`ragshit init` writes `.ragshit.toml` and `.ragshitignore` at the
repository root. Absent keys fall back to these defaults; unknown keys or
sections are a hard configuration error.

## `[index]`

| key | default | meaning |
|-----|---------|---------|
| `database` | `.ragshit/index.sqlite3` | index path, relative to the repository root |
| `include_untracked` | `false` | index untracked files (`git ls-files --others --exclude-standard`) |
| `max_file_bytes` | `1048576` | skip files larger than this |
| `follow_symlinks` | `false` | index symlinked files |

## `[retrieval]`

| key | default | meaning |
|-----|---------|---------|
| `default_limit` | `20` | results when `--limit` is not given |
| `maximum_limit` | `100` | hard cap on `--limit` |
| `changed_file_boost` | `2.0` | file has working-tree changes |
| `path_match_boost` | `4.0` | exact path match (partial = half) |
| `symbol_match_boost` | `5.0` | exact symbol match (partial = half) |
| `heading_match_boost` | `3.0` | heading equals a query term (also caps token overlap) |
| `heading_token_boost` | `1.0` | per query term found as a token in the heading path (capped at `heading_match_boost`) |
| `symbol_token_boost` | `1.0` | per query term found as a token in the symbol name (capped at `symbol_match_boost`) |
| `coverage_boost` | `1.0` | per distinct query term (≥ 4 chars) present in chunk content, when ≥ 2 terms match (capped at 3.0) |
| `changed_line_boost` | `2.0` | chunk overlaps a changed line range |
| `recent_change_boost` | `0.5` | file touched in the last 10 commits |
| `decision_doc_boost` | `0.5` | decision/ADR-style chunk when the query mentions decisions |
| `fts_weight` | `8.0` | ceiling of the FTS5 contribution |
| `phrase_boost` | `2.0` | per verbatim phrase found (capped at 6.0) |

## `[bundle]`

| key | default | meaning |
|-----|---------|---------|
| `maximum_characters` | `120000` | bundle character budget |
| `include_git_status` | `true` | repository-state section |
| `include_recent_commits` | `true` | last commits in the state section |
| `recent_commit_count` | `10` | how many |
| `include_diff` | `true` | working-tree diff summary when no `--diff` given |

## `[embeddings]`

| key | default | meaning |
|-----|---------|---------|
| `enabled` | `false` | embeddings off in milestone zero |
| `provider` | `"disabled"` | only `disabled` exists today |

## `.ragshitignore`

gitignore-style patterns with negation support. Semantics:

1. `.ragshitignore` always wins — a tracked file listed there is excluded.
2. `.gitignore` applies only to untracked files; tracked files override it.
3. `.git/` and `.ragshit/` are never eligible.
