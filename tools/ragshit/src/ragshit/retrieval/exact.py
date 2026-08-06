"""Exact-match candidate collection.

Signals 1-3 of the retrieval pipeline:
1. exact relative-path match
2. partial path match
3. exact symbol or heading match
plus exact quoted-phrase matches (signal 4).
"""

from __future__ import annotations

from typing import Dict, List, Optional, Set

from ..indexing.database import Database
from ..models import Chunk, QuerySpec


def _looks_like_path(term: str) -> bool:
    return "/" in term or term.startswith(".") or "." in term


def path_exact_candidates(db: Database, repo_id: str, query: QuerySpec) -> Dict[str, Chunk]:
    """Chunks whose path equals a query term or path filter."""
    targets: Set[str] = set(query.path_filters)
    targets |= {t for t in query.terms if _looks_like_path(t)}
    out: Dict[str, Chunk] = {}
    for target in targets:
        for chunk in db.chunks_for_path(repo_id, target):
            out[chunk.chunk_id] = chunk
    return out


def path_partial_candidates(db: Database, repo_id: str, query: QuerySpec) -> Dict[str, Chunk]:
    """Chunks under a directory filter or matching a path fragment."""
    out: Dict[str, Chunk] = {}
    for frag in query.path_filters:
        frag = frag.strip()
        if not frag:
            continue
        if frag.endswith("/"):
            for chunk in db.chunks_under_path(repo_id, frag):
                out[chunk.chunk_id] = chunk
        else:
            for chunk in db.chunks_path_like(repo_id, frag):
                out[chunk.chunk_id] = chunk
    return out


def symbol_candidates(db: Database, repo_id: str, query: QuerySpec) -> Dict[str, Chunk]:
    """Chunks whose symbol or heading matches a term or symbol: filter."""
    out: Dict[str, Chunk] = {}
    for term in list(query.terms) + list(query.symbol_filters):
        term = term.strip()
        if not term:
            continue
        for chunk in db.chunks_symbol_exact(repo_id, term):
            out[chunk.chunk_id] = chunk
    return out


def heading_partial_candidates(db: Database, repo_id: str, query: QuerySpec) -> Dict[str, Chunk]:
    """Chunks whose heading contains a term (word-level heading match)."""
    out: Dict[str, Chunk] = {}
    for term in query.terms:
        if len(term) < 4:
            continue
        for chunk in db.chunks_symbol_contains(repo_id, term):
            out[chunk.chunk_id] = chunk
    return out


def phrase_candidates(db: Database, repo_id: str, query: QuerySpec) -> Dict[str, Chunk]:
    """Chunks containing a quoted phrase verbatim."""
    out: Dict[str, Chunk] = {}
    for phrase in query.phrases:
        if not phrase.strip():
            continue
        for chunk in db.chunks_phrase(repo_id, phrase):
            out[chunk.chunk_id] = chunk
    return out
