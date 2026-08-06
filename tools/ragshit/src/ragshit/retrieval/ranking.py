"""Deterministic hybrid ranking.

Final score = sum of per-signal components:

    path exact          path_match_boost    (4.0)
    path partial        path_match_boost/2  (2.0)
    symbol exact        symbol_match_boost  (5.0)
    heading exact       heading_match_boost (3.0)
    phrase match        2.0 per phrase      (bounded by phrase_boost)
    FTS rank            max(0, fts_weight + bm25)  (<= 8.0)
    modified file       changed_file_boost  (2.0)
    changed-line overlap changed_line_boost (2.0)
    recent change       recent_change_boost (0.5)
    decision document   decision_doc_boost  (0.5, query-driven)

Ties are broken deterministically by (relative path, start line, chunk id).
Ranking information is never hidden: every component is available for
explanation.
"""

from __future__ import annotations

import re
from typing import Dict, List, Optional

from ..config import RetrievalConfig
from ..models import Chunk, GitState, QuerySpec, RetrievedChunk

DECISION_WORDS = {
    "adr", "milestone", "decision", "decisions", "roadmap", "contract",
    "evidence", "observed", "inferred", "non-goal", "nongoal", "non-goals",
    "architecture", "assumption", "handoff",
}


def _heading_leaf(heading: Optional[str]) -> str:
    if not heading:
        return ""
    return heading.split(" > ")[-1].lower()


def _token_overlap(terms: List[str], text: str) -> List[str]:
    """Query terms that appear as tokens in *text* (with prefix tolerance,
    so 'milestone' matches 'milestones' and 'assumption' matches
    'assumptions'). Deterministic: matches keep query term order."""
    if not terms:
        return []
    tokens = set(re.findall(r"[a-z0-9_]+", text.lower()))
    hits = []
    for term in terms:
        if len(term) < 3:
            continue
        if term in tokens:
            hits.append(term)
        elif len(term) >= 4 and any(tok.startswith(term) for tok in tokens):
            hits.append(term)
        elif len(term) >= 4 and any(term.startswith(tok) for tok in tokens):
            hits.append(term)
    return hits


def _content_coverage(terms: List[str], content: str) -> List[str]:
    """Distinct query terms (>= 4 chars) present in chunk content. Measures
    how many aspects of the query a chunk addresses; cheap, deterministic,
    and independent of BM25's length normalization."""
    tokens = set(re.findall(r"[a-z0-9]+", content.lower()))
    covered = []
    for term in terms:
        if len(term) < 4:
            continue
        if term in tokens or any(tok.startswith(term) for tok in tokens):
            covered.append(term)
    return covered


def rank_candidates(
    config: RetrievalConfig,
    query: QuerySpec,
    candidates: Dict[str, Chunk],
    fts_scores: Dict[str, float],
    git: GitState,
) -> List[RetrievedChunk]:
    rc = config
    modified = git.changed_paths | git.staged_paths
    recent = git.recent_paths
    decision_terms = set(query.terms) & DECISION_WORDS
    terms_lower = [t.lower() for t in query.terms]
    symbol_terms = [t.lower() for t in query.terms + query.symbol_filters]
    heading_terms = [t.lower() for t in query.terms + query.symbol_filters]

    results: List[RetrievedChunk] = []
    for chunk in candidates.values():
        comps: Dict[str, float] = {}
        path = chunk.path
        path_l = path.lower()

        # 1. exact / partial path
        if path in query.path_filters or path in query.terms:
            comps["path exact"] = rc.path_match_boost
        else:
            partial = False
            for frag in query.path_filters:
                if frag and (frag in path_l or path_l.endswith(frag.lstrip("/"))):
                    partial = True
                    break
            if not partial:
                for term in query.terms:
                    if "/" in term and term in path_l:
                        partial = True
                        break
            if partial:
                comps["path partial"] = round(rc.path_match_boost / 2.0, 4)

        # 2. symbol exact / partial / token overlap
        symbol = (chunk.structural_name or "").lower()
        symbol_exact = bool(symbol) and any(symbol == t for t in symbol_terms)
        if symbol_exact:
            comps["symbol exact"] = rc.symbol_match_boost
        elif symbol:
            for t in symbol_terms:
                if len(t) >= 4 and (t in symbol or symbol in t):
                    comps["symbol partial"] = round(rc.symbol_match_boost / 2.0, 4)
                    break

        # 3. heading exact + heading token overlap (structural relevance)
        leaf = _heading_leaf(chunk.heading)
        heading_full = (chunk.heading or "").lower()
        if leaf and any(leaf == t for t in heading_terms):
            comps["heading exact"] = rc.heading_match_boost
        elif any(heading_full == t for t in heading_terms):
            comps["heading exact"] = rc.heading_match_boost
        if chunk.heading:
            hits = _token_overlap(heading_terms, chunk.heading)
            if hits:
                comps["heading match"] = round(
                    min(rc.heading_match_boost, rc.heading_token_boost * len(hits)), 4
                )
        if symbol and not symbol_exact:
            hits = _token_overlap(symbol_terms, symbol)
            if hits:
                comps["symbol match"] = round(
                    min(rc.symbol_match_boost, rc.symbol_token_boost * len(hits)), 4
                )

        # 4. phrase match
        if query.phrases:
            content_l = chunk.content.lower()
            matched = sum(1 for p in query.phrases if p.lower() in content_l)
            if matched:
                comps["phrase match"] = round(min(rc.phrase_boost * matched, 6.0), 4)

        # 5. FTS + multi-aspect term coverage
        fts = fts_scores.get(chunk.chunk_id, 0.0)
        if fts > 0:
            comps["FTS rank"] = round(fts, 4)
        if len(query.terms) >= 2:
            covered = _content_coverage(terms_lower, chunk.content)
            if len(covered) >= 2:
                comps["term coverage"] = round(
                    min(3.0, rc.coverage_boost * len(covered)), 4
                )

        # 6. changed-file boost + 7. changed-line overlap
        if path in modified or path in git.untracked_paths:
            comps["modified file"] = rc.changed_file_boost
            for start, end in git.changed_ranges.get(path, []):
                if chunk.start_line <= end and chunk.end_line >= start:
                    comps["changed-line overlap"] = rc.changed_line_boost
                    break

        # 8. recency
        if path in recent:
            comps["recent change"] = rc.recent_change_boost

        # 9. decision-document priority (query-driven, not path-baked)
        if decision_terms and (chunk.kind == "markdown" or "decision" in path_l):
            comps["decision document"] = rc.decision_doc_boost

        results.append(RetrievedChunk(
            chunk=chunk,
            score=round(sum(comps.values()), 4),
            components=comps,
        ))
    return results


def sort_results(results: List[RetrievedChunk]) -> List[RetrievedChunk]:
    """Score descending; deterministic tie-break by path, start line, id."""
    return sorted(
        results,
        key=lambda r: (-r.score, r.chunk.path, r.chunk.start_line, r.chunk.chunk_id),
    )


def dedupe_overlaps(results: List[RetrievedChunk]) -> List[RetrievedChunk]:
    """Drop lower-scoring chunks that overlap a kept chunk in the same file,
    unless the lower one earned an exact signal."""
    kept: List[RetrievedChunk] = []
    for result in results:
        if any(
            other.chunk.path == result.chunk.path
            and other.chunk.start_line <= result.chunk.end_line
            and other.chunk.end_line >= result.chunk.start_line
            and not _has_exact_signal(result)
            for other in kept
        ):
            continue
        kept.append(result)
    return kept


def _has_exact_signal(result: RetrievedChunk) -> bool:
    return any(
        name in result.components
        for name in ("path exact", "symbol exact", "heading exact", "phrase match")
    )
