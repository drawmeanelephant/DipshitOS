"""Stale-document signal: conservative heuristic."""
from __future__ import annotations
import re
from dataclasses import dataclass
from typing import List, Set
from ..indexing.database import Database
_DOC_RE=re.compile(r"^docs/")
@dataclass
class StaleDoc:
    path: str; symbol: str; start_line: int; end_line: int; heading: str|None; reason: str="mentions changed symbol but not updated in range"
def detect_stale(db: Database, repo_id: str, changed_paths: Set[str], changed_symbols: Set[str]):
    if not changed_symbols: return []
    out=[]; seen=set()
    for sym in sorted(changed_symbols):
        if len(sym)<3: continue
        try: hits=db.chunks_phrase(repo_id, sym)
        except Exception: continue
        pat=re.compile(rf"(?<![A-Za-z0-9_]){re.escape(sym)}(?![A-Za-z0-9_])")
        for c in hits:
            if c.path in changed_paths: continue
            if not _DOC_RE.match(c.path): continue
            if not pat.search(c.content): continue
            key=(c.path,sym)
            if key in seen: continue
            seen.add(key); out.append(StaleDoc(path=c.path, symbol=sym, start_line=c.start_line, end_line=c.end_line, heading=c.heading))
            if len(out)>=20: break
        if len(out)>=20: break
    out.sort(key=lambda s:(s.path,s.symbol))
    return out
