"""Symbol-level impact: map changed hunks to enclosing indexed symbols."""
from __future__ import annotations
from dataclasses import dataclass
from typing import Dict, List, Optional
from ..indexing.database import Database
from ..models import Chunk
from .inventory import Inventory

@dataclass
class ChangedSymbol:
    path: str
    name: str
    kind: str
    start_line: int
    end_line: int
    confidence: float
    commit: Optional[str]

@dataclass
class SymbolMapping:
    symbols: List[ChangedSymbol]
    unresolved_files: List[str]
    per_file: Dict[str, List[ChangedSymbol]]

def _overlaps(a,b,c,d):
    return a<=d and b>=c

def map_symbols(db: Database, repo_id: str, inv: Inventory) -> SymbolMapping:
    symbols=[]; unresolved=[]; per_file={}
    for cf in inv.files:
        if cf.status.startswith("D"):
            try: chunks=db.chunks_for_path(repo_id, cf.path)
            except Exception: chunks=[]
            for c in chunks:
                if c.structural_name:
                    cs=ChangedSymbol(path=cf.path, name=c.structural_name, kind=c.kind, start_line=c.start_line, end_line=c.end_line, confidence=c.confidence, commit=c.commit)
                    symbols.append(cs); per_file.setdefault(cf.path,[]).append(cs)
            if cf.path not in per_file: unresolved.append(cf.path)
            continue
        if not cf.ranges:
            unresolved.append(cf.path); continue
        try: chunks=db.chunks_for_path(repo_id, cf.path)
        except Exception: unresolved.append(cf.path); continue
        sym_chunks=[c for c in chunks if c.structural_name]
        sym_chunks.sort(key=lambda c:(c.start_line,c.end_line,c.chunk_id))
        file_syms=[]; seen=set()
        for rs,re in cf.ranges:
            overlapping=[c for c in sym_chunks if _overlaps(c.start_line,c.end_line,rs,re)]
            if not overlapping:
                best=None; best_span=None
                for c in sym_chunks:
                    if c.start_line<=rs<=c.end_line:
                        span=c.end_line-c.start_line
                        if best is None or span<best_span: best=c; best_span=span
                if best is not None: overlapping=[best]
            for c in overlapping:
                key=(c.structural_name,c.start_line,c.end_line)
                if key in seen: continue
                seen.add(key)
                file_syms.append(ChangedSymbol(path=cf.path, name=c.structural_name or "", kind=c.kind, start_line=c.start_line, end_line=c.end_line, confidence=c.confidence, commit=c.commit))
        if file_syms:
            file_syms.sort(key=lambda s:(s.start_line,s.name))
            per_file[cf.path]=file_syms; symbols.extend(file_syms)
        else:
            unresolved.append(cf.path)
    symbols.sort(key=lambda s:(s.path,s.start_line,s.name))
    unresolved=sorted(set(unresolved))
    return SymbolMapping(symbols=symbols, unresolved_files=unresolved, per_file=per_file)
