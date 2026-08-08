"""Redundancy control — deterministic local signals.

No embeddings, no network. Uses line overlap, token Jaccard, hash equality,
structural identity.
"""
from __future__ import annotations

from typing import List, Tuple, Optional
from .candidates import Candidate


def line_overlap(a: Candidate, b: Candidate) -> float:
    if a.path != b.path:
        return 0.0
    s = max(a.start_line, b.start_line)
    e = min(a.end_line, b.end_line)
    if e < s:
        return 0.0
    overlap = e - s + 1
    smaller = min(a.end_line - a.start_line + 1, b.end_line - b.start_line + 1)
    return overlap / smaller if smaller else 0.0


def jaccard(a: Candidate, b: Candidate) -> float:
    sa = a.token_set
    sb = b.token_set
    if not sa and not sb:
        return 1.0
    if not sa or not sb:
        return 0.0
    inter = len(sa & sb)
    union = len(sa | sb)
    return inter / union if union else 0.0


def is_duplicate_hash(a: Candidate, b: Candidate) -> bool:
    return a.content_hash == b.content_hash and a.content_hash != ""


def structural_identical(a: Candidate, b: Candidate) -> bool:
    return a.path == b.path and a.start_line == b.start_line and a.end_line == b.end_line


def redundancy_penalty(candidate: Candidate, selected: List[Candidate]) -> Tuple[float, Optional[str]]:
    """Return (penalty 0..0.9, reason string) vs worst selected overlap."""
    worst = 0.0
    reason = None
    for s in selected:
        if structural_identical(candidate, s):
            return 0.9, f"structural identical to {s.path}:{s.start_line}-{s.end_line} ({s.reason})"
        if is_duplicate_hash(candidate, s):
            worst = max(worst, 0.9)
            reason = f"duplicate hash with {s.path}:{s.start_line}-{s.end_line}"
            continue
        lo = line_overlap(candidate, s)
        if lo > 0.9:
            # High line overlap with same file is redundant if coverage already covered
            worst = max(worst, 0.85)
            reason = f"{lo:.0%} line overlap with {s.path}:{s.start_line}-{s.end_line} ({s.reason})"
            continue
        elif lo > 0.5:
            worst = max(worst, 0.5)
            if worst < 0.85:
                reason = f"{lo:.0%} line overlap with {s.path}:{s.start_line}-{s.end_line}"
        jac = jaccard(candidate, s)
        if jac >= 0.85:
            if jac > worst:
                worst = 0.8
                reason = f"{jac:.0%} token Jaccard with {s.path}:{s.start_line}-{s.end_line} ({s.reason})"
        elif jac >= 0.6 and worst < 0.6:
            worst = max(worst, 0.3)
            reason = f"{jac:.0%} token overlap with {s.path}"
    return worst, reason
