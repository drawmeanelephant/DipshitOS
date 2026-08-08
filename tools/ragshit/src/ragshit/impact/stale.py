"""Stale-document signal: conservative heuristic.

A doc is "stale-hint" when it mentions a changed symbol but was not itself
updated in the range. This is a REVIEW HINT ONLY — never an auto-edit.

Generic-symbol filter (fix C): symbols that are near-certain noise are
excluded from stale-hint generation so a project-name or a generic heading
change cannot create a stale-warning avalanche. The rules are conservative,
deterministic, and documented in tools/ragshit/docs/ranking.md; they only
suppress symbols with multiple independent generic signals, never merely
frequent load-bearing identifiers.
"""
from __future__ import annotations
import pathlib
import re
import subprocess
from dataclasses import dataclass
from typing import Dict, List, Optional, Set, Tuple

from ..indexing.database import Database

_DOC_RE = re.compile(r"^docs/")

# --- generic-symbol filter thresholds (fix C) -------------------------------
# Deliberately conservative: a symbol needs a strong generic signal before it
# stops producing stale hints. See tools/ragshit/docs/ranking.md#stale-hints.
HEADING_DF_THRESHOLD = 3     # a markdown heading appearing in >= N docs is generic
UBIQUITY_DF_THRESHOLD = 10   # a symbol appearing in >= N distinct docs is ubiquitous
SHELL_NAME_DF_THRESHOLD = 2  # a shell assignment name in >= N docs is generic
KEY_NAME_MAX_LEN = 6         # short YAML/TOML key names (name, id, ...)
KEY_NAME_DF_THRESHOLD = 2    # ... are generic when they appear in >= N docs


@dataclass
class StaleDoc:
    path: str; symbol: str; start_line: int; end_line: int; heading: str | None; reason: str = "mentions changed symbol but not updated in range"


def _project_name(repo) -> Optional[str]:
    """Project/repository name: git remote URL basename, else repo dir name.

    Case-insensitive comparison later; the raw name is returned so the caller
    can compare both spellings deterministically.
    """
    try:
        if repo is None:
            return None
        root = pathlib.Path(repo.root)
        proc = subprocess.run(
            ["git", "-C", str(root), "remote", "get-url", "origin"],
            capture_output=True, timeout=10,
        )
        if proc.returncode == 0:
            url = proc.stdout.decode("utf-8", "replace").strip().replace("\\", "/").rstrip("/")
            if url:
                m = re.search(r"([^/]+?)(?:\.git)?$", url)
                if m:
                    name = m.group(1)
                    if name and name not in (".", "..", "origin"):
                        return name
        return root.name or None
    except Exception:
        return None


def _word_boundary(sym: str) -> re.Pattern:
    return re.compile(rf"(?<![A-Za-z0-9_]){re.escape(sym)}(?![A-Za-z0-9_])")


def _symbol_doc_freq(db: Database, repo_id: str, sym: str, pat: re.Pattern) -> int:
    """Distinct docs/ paths whose content contains the symbol as a whole word."""
    try:
        hits = db.chunks_phrase(repo_id, sym)
    except Exception:
        return 0
    docs: Set[str] = set()
    for c in hits:
        if _DOC_RE.match(c.path) and pat.search(c.content):
            docs.add(c.path)
    return len(docs)


def generic_symbol_reasons(
    sym: str,
    kind: Optional[str],
    project: Optional[str],
    df: int,
    is_heading: bool,
) -> List[str]:
    """WHY a changed symbol is excluded from stale-hint generation (fix C).

    Returns an empty list when the symbol is load-bearing and must keep
    producing hints. Exposed for tests/debugging: the review report surfaces
    filtered symbols with these reasons.
    """
    reasons: List[str] = []
    if project and sym.lower() == project.lower():
        reasons.append("project-name")
    if is_heading and df >= HEADING_DF_THRESHOLD:
        reasons.append(f"generic-heading (appears in {df} documents)")
    if df >= UBIQUITY_DF_THRESHOLD:
        reasons.append(f"ubiquitous (appears in {df} documents)")
    # A shell assignment name (ROOT=, tmp=, pass=, id1=, ...) is bookkeeping,
    # not a cross-document contract; once it appears in >= 2 documents it is
    # almost certainly prose, not a variable reference. df>=2 keeps genuinely
    # load-bearing names (referenced deliberately by docs) intact.
    if kind == "constant" and df >= SHELL_NAME_DF_THRESHOLD:
        reasons.append(f"generic-shell-name (appears in {df} documents)")
    # Short YAML/TOML keys (name:, id:) are generic config keys; longer keys
    # (database:, maximum_characters:) stay load-bearing.
    if kind == "key" and len(sym) <= KEY_NAME_MAX_LEN and df >= KEY_NAME_DF_THRESHOLD:
        reasons.append(f"generic-config-key (appears in {df} documents)")
    return reasons


def detect_stale(
    db: Database,
    repo_id: str,
    changed_paths: Set[str],
    changed_symbols: Set[str],
    repo=None,
    symbol_kinds: Optional[Dict[str, str]] = None,
    return_filtered: bool = False,
):
    """Return stale hints for changed symbols (deterministic, capped at 20).

    ``symbol_kinds`` maps a symbol name to a precise kind ("function",
    "constant", "heading") so the generic-symbol filter can distinguish a
    load-bearing identifier from a throwaway shell name or generic heading.
    With ``return_filtered=True`` returns ``(hints, filtered)`` where
    ``filtered`` is a list of ``{"symbol", "reasons"}`` dicts explaining which
    changed symbols were excluded and why.
    """
    empty_filtered: List[Dict[str, object]] = []
    if not changed_symbols:
        return ([], empty_filtered) if return_filtered else []
    project = _project_name(repo)
    kinds = symbol_kinds or {}
    out: List[StaleDoc] = []
    filtered: Dict[str, List[str]] = {}
    seen: Set[Tuple[str, str]] = set()
    for sym in sorted(changed_symbols):
        if len(sym) < 3:
            continue
        try:
            hits = db.chunks_phrase(repo_id, sym)
        except Exception:
            hits = []
        pat = _word_boundary(sym)
        doc_paths: Set[str] = set()
        for c in hits:
            if _DOC_RE.match(c.path) and pat.search(c.content):
                doc_paths.add(c.path)
        df = len(doc_paths)
        kind = kinds.get(sym)
        is_heading = kind == "heading"
        reasons = generic_symbol_reasons(sym, kind, project, df, is_heading)
        if reasons:
            filtered[sym] = reasons
            continue
        for c in hits:
            if c.path in changed_paths:
                continue
            if not _DOC_RE.match(c.path):
                continue
            if not pat.search(c.content):
                continue
            key = (c.path, sym)
            if key in seen:
                continue
            seen.add(key)
            out.append(StaleDoc(path=c.path, symbol=sym, start_line=c.start_line, end_line=c.end_line, heading=c.heading))
            if len(out) >= 20:
                break
        if len(out) >= 20:
            break
    out.sort(key=lambda s: (s.path, s.symbol))
    if return_filtered:
        filtered_list = [{"symbol": s, "reasons": r} for s, r in sorted(filtered.items())]
        return out, filtered_list
    return out
