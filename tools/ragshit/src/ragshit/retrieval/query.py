"""Query parsing and retrieval orchestration."""

from __future__ import annotations

import shlex
from typing import Dict, List, Optional, Tuple

from ..config import RetrievalConfig
from ..errors import QuerySyntaxError
from ..git.repository import GitRepository
from ..git.status import git_state
from ..indexing.database import Database
from ..models import Chunk, GitState, QuerySpec, RetrievedChunk
from . import exact, lexical, ranking

KNOWN_FILTERS = ("path", "kind", "symbol", "changed")
KIND_VALUES = {"markdown", "source", "plaintext", "document", "window",
               "section", "symbol", "comment", "key",
               "zig", "swift", "python", "shell", "c", "assembly", "linker",
               "toml", "yaml", "json"}


def parse_query(text: str) -> QuerySpec:
    if text is None or not text.strip():
        raise QuerySyntaxError("empty query")
    query = QuerySpec()
    try:
        tokens = shlex.split(text, posix=True)
    except ValueError as exc:
        raise QuerySyntaxError(f"cannot parse query: {exc}") from exc
    for token in tokens:
        if token.startswith("path:"):
            value = token[len("path:"):].strip()
            if not value:
                raise QuerySyntaxError("empty path: filter")
            query.path_filters.append(value)
        elif token.startswith("kind:"):
            value = token[len("kind:"):].strip().lower()
            if value not in KIND_VALUES:
                raise QuerySyntaxError(
                    f"invalid kind filter '{value}' (supported: markdown, source, "
                    "plaintext, zig, swift, python, shell, c, assembly, linker, toml, yaml, json)"
                )
            query.kind_filters.append(value)
        elif token.startswith("symbol:"):
            value = token[len("symbol:"):].strip()
            if not value:
                raise QuerySyntaxError("empty symbol: filter")
            query.symbol_filters.append(value)
        elif token.startswith("changed:"):
            value = token[len("changed:"):].strip().lower()
            if value == "true":
                query.changed = True
            elif value == "false":
                query.changed = False
            else:
                raise QuerySyntaxError(f"invalid changed filter '{value}' (use changed:true or changed:false)")
        elif token.startswith("path=") or token.startswith("kind=") \
                or token.startswith("symbol=") or token.startswith("changed="):
            raise QuerySyntaxError(
                f"invalid filter '{token}'; use 'key:value' syntax (path:, kind:, symbol:, changed:)"
            )
        elif ":" in token:
            key, _, value = token.partition(":")
            # Only treat alpha keys with a non-empty value as attempted
            # filters, so prose like "observed:" or "time: 5" (which shlex
            # splits at the space) stays an ordinary search term.
            if key.isalpha() and len(key) <= 12 and value:
                raise QuerySyntaxError(
                    f"unknown filter '{key}' in '{token}' (supported: path:, kind:, symbol:, changed:)"
                )
            else:
                query.terms.append(token)
        elif token.startswith('"') or token.endswith('"'):
            query.phrases.append(token.strip('"'))
        else:
            query.terms.append(token)
    return query


def _kind_matches(chunk_kind: str, chunk_language: str, value: str) -> bool:
    return chunk_kind == value or chunk_language == value


def run_query(
    db: Database,
    repo: GitRepository,
    config: RetrievalConfig,
    text: str,
    limit: int,
    git: Optional[GitState] = None,
) -> Tuple[List[RetrievedChunk], GitState]:
    """Hybrid retrieval: exact -> phrase -> FTS -> git-aware ranking."""
    query = parse_query(text)
    if git is None:
        git = git_state(repo)
    repo_id = repo.repo_id

    candidates: Dict[str, Chunk] = {}
    fts_scores: Dict[str, float] = {}

    # Exact signals first (their candidates are cheap and precise).
    for bucket in (
        exact.path_exact_candidates(db, repo_id, query),
        exact.path_partial_candidates(db, repo_id, query),
        exact.symbol_candidates(db, repo_id, query),
        exact.heading_partial_candidates(db, repo_id, query),
        exact.phrase_candidates(db, repo_id, query),
    ):
        for chunk_id, chunk in bucket.items():
            candidates.setdefault(chunk_id, chunk)

    # Lexical signal (FTS5 or degraded LIKE).
    lex_chunks, fts = lexical.lexical_candidates(db, repo_id, query, max(limit * 6, 60))
    fts_scores.update(fts)
    for chunk_id, chunk in lex_chunks.items():
        candidates.setdefault(chunk_id, chunk)

    if not candidates:
        return [], git

    # Filters (path:, kind:, changed: restrict the candidate set).
    for frag in query.path_filters:
        if not frag:
            continue
        if frag.endswith("/"):
            prefix = frag.rstrip("/") + "/"
            candidates = {
                cid: chunk for cid, chunk in candidates.items()
                if chunk.path == frag or chunk.path.startswith(prefix)
            }
        else:
            candidates = {
                cid: chunk for cid, chunk in candidates.items()
                if frag in chunk.path
            }
    if query.changed is not None:
        dirty = git.changed_paths | git.staged_paths | git.untracked_paths
        candidates = {
            cid: chunk for cid, chunk in candidates.items()
            if (chunk.path in dirty) == query.changed
        }
    for kind_filter in query.kind_filters:
        candidates = {
            cid: chunk for cid, chunk in candidates.items()
            if _kind_matches(chunk.kind, chunk.language, kind_filter)
        }
    if not candidates:
        return [], git

    ranked = ranking.rank_candidates(config, query, candidates, fts_scores, git)
    ranked = ranking.sort_results(ranked)
    ranked = ranking.dedupe_overlaps(ranked)
    return ranked[:limit], git
