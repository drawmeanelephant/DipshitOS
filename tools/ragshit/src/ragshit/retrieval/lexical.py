"""Lexical retrieval: SQLite FTS5 BM25 with a LIKE fallback.

The FTS contribution to a score is ``max(0, fts_weight + bm25_rank)``;
because BM25 ranks are <= 0, a strong lexical match approaches
``fts_weight`` (default 8.0). Column weights favour symbols and paths over
body text. See docs/ranking.md.
"""

from __future__ import annotations

import re
from typing import Dict, List, Tuple

from ..indexing.database import Database
from ..models import Chunk, QuerySpec

_FTS_OPERATORS = {"AND", "OR", "NOT", "NEAR", "IN", "IS"}


def _escape_term(term: str) -> str:
    """Make a term safe inside an FTS5 MATCH string.

    Alphanumeric terms become prefix queries (``plan*``); anything else is
    quoted as a tokenized phrase so path-like terms (``docs/decisions/x.md``)
    do not trip the FTS5 query parser."""
    esc = term.replace('"', " ").replace("(", " ").replace(")", " ")
    esc = esc.strip()
    if not esc:
        return ""
    if re.fullmatch(r"[A-Za-z0-9_]+", esc):
        if esc.upper() in _FTS_OPERATORS:
            return '"' + esc + '"'
        return esc + "*"
    return '"' + esc + '"'


def fts_match_string(query: QuerySpec) -> str:
    """Build an FTS5 MATCH expression from terms and phrases."""
    parts: List[str] = []
    for term in query.terms:
        esc = _escape_term(term)
        if not esc:
            continue
        parts.append(f"(content:{esc} OR structural_name:{esc} OR path:{esc})")
    for phrase in query.phrases:
        esc = _escape_term(phrase)
        if not esc:
            continue
        parts.append(f'content:"{esc}"')
    return " OR ".join(parts)


def _normalize(ranks: List[float]) -> Dict[float, float]:
    """Map BM25 ranks (more negative = better) into [0, fts_weight] via
    square-root min-max normalization over the query's lexical result set.
    The top lexical match scores fts_weight; the worst scores 0. The sqrt
    curve keeps single-mention chunks competitive instead of crushing them
    against outlier-heavy chunks. Deterministic."""
    if not ranks:
        return {}
    rmin, rmax = min(ranks), max(ranks)
    span = rmax - rmin
    if span <= 0:
        return {r: 8.0 for r in ranks}
    return {r: round(8.0 * (1.0 - ((r - rmin) / span) ** 0.5), 4) for r in ranks}


def lexical_candidates(
    db: Database, repo_id: str, query: QuerySpec, limit: int
) -> Tuple[Dict[str, Chunk], Dict[str, float]]:
    """Return (chunks, chunk_id -> fts_component). Uses FTS5 when
    available, otherwise the degraded LIKE search."""
    chunks: Dict[str, Chunk] = {}
    fts_scores: Dict[str, float] = {}
    if db.fts_available:
        match = fts_match_string(query)
        if not match:
            return chunks, fts_scores
        # Candidate window: fetch a generous superset of the final limit so
        # the min-max normalization (and ranking) sees the whole lexical
        # neighbourhood, not just the top handful of chunks.
        window = max(limit * 10, 250)
        results = db.fts_search(match, window)
        if not results:
            return chunks, fts_scores
        mapping = _normalize([rank for _, rank in results])
        for chunk, rank in results:
            chunks[chunk.chunk_id] = chunk
            fts_scores[chunk.chunk_id] = mapping[rank]
    else:
        terms = list(query.terms) + list(query.phrases)
        results = db.lexical_like_search(terms, limit)
        if not results:
            return chunks, fts_scores
        mapping = _normalize([score for _, score in results])
        for chunk, score in results:
            chunks[chunk.chunk_id] = chunk
            fts_scores[chunk.chunk_id] = mapping[score]
    return chunks, fts_scores
