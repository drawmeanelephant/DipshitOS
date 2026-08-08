"""Reference neighborhood: index-only nearby context."""
from __future__ import annotations
import re
from dataclasses import dataclass
from typing import Dict, List, Set, Tuple
from ..indexing.database import Database
_DOC_PREFIXES=("docs/",)
def _is_test_path(path: str):
    low=path.lower()
    return ("/tests/" in path or path.startswith("tests/") or "test_" in low or low.endswith("_test.py") or low.endswith("_test.zig") or "__tests__" in path or low.startswith("tools/ragshit/tests"))
def _is_doc_path(path: str):
    return path.startswith(_DOC_PREFIXES) or path.startswith("tools/ragshit/docs")
_WORD_CACHE: Dict[str, re.Pattern]={}
def _word_pat(term: str):
    if term not in _WORD_CACHE:
        _WORD_CACHE[term]=re.compile(rf"(?<![A-Za-z0-9_]){re.escape(term)}(?![A-Za-z0-9_])")
    return _WORD_CACHE[term]
@dataclass
class Neighbor:
    path: str; start_line: int; end_line: int; kind: str; structural_name: str|None; reason: str; query: str; commit: str|None; language: str; heading: str|None
def collect_neighborhood(db: Database, repo_id: str, changed_paths: Set[str], symbols_by_path: Dict[str,List[str]], changed_symbols: Set[str]):
    neighbors: Dict[Tuple[str,int,int,str], Neighbor]={}
    for sym in sorted(changed_symbols):
        if len(sym)<2: continue
        try: exact_chunks=db.chunks_symbol_exact(repo_id, sym)
        except Exception: exact_chunks=[]
        for c in exact_chunks:
            if c.path in changed_paths: continue
            key=(c.path,c.start_line,c.end_line,sym)
            if key in neighbors: continue
            neighbors[key]=Neighbor(path=c.path, start_line=c.start_line, end_line=c.end_line, kind=c.kind, structural_name=c.structural_name, reason="direct-symbol", query=sym, commit=c.commit, language=c.language, heading=c.heading)
        try: phrase_chunks=db.chunks_phrase(repo_id, sym)
        except Exception: phrase_chunks=[]
        for c in phrase_chunks:
            key=(c.path,c.start_line,c.end_line,sym)
            if key in neighbors: continue
            if c.path in changed_paths: continue
            if sym not in c.content: continue
            has_word=bool(_word_pat(sym).search(c.content))
            if not has_word: reason="lexical-related"
            else:
                if _is_test_path(c.path): reason="test-reference"
                elif _is_doc_path(c.path) or c.language=="markdown": reason="documentation-reference"
                else: reason="identifier-reference"
            neighbors[key]=Neighbor(path=c.path, start_line=c.start_line, end_line=c.end_line, kind=c.kind, structural_name=c.structural_name, reason=reason, query=sym, commit=c.commit, language=c.language, heading=c.heading)
    for path in sorted(changed_paths):
        if path in symbols_by_path: continue
        base=path.rsplit("/",1)[-1]; stem=base.rsplit(".",1)[0] if "." in base else base
        if len(stem)<3: continue
        try: hits=db.chunks_phrase(repo_id, stem)
        except Exception: continue
        for c in hits[:20]:
            if c.path in changed_paths: continue
            key=(c.path,c.start_line,c.end_line,path)
            if key in neighbors: continue
            if _is_test_path(c.path): reason="test-reference"
            elif _is_doc_path(c.path): reason="documentation-reference"
            else: reason="lexical-related"
            neighbors[key]=Neighbor(path=c.path, start_line=c.start_line, end_line=c.end_line, kind=c.kind, structural_name=c.structural_name, reason=reason, query=path, commit=c.commit, language=c.language, heading=c.heading)
    out=sorted(neighbors.values(), key=lambda n:(n.reason!="direct-symbol", n.path, n.start_line, n.query))
    out=out[:80]
    per: Dict[str,int]={}
    for n in out:
        for p,syms in symbols_by_path.items():
            if n.query in syms: per[p]=per.get(p,0)+1
        if n.query in changed_paths: per[n.query]=per.get(n.query,0)+1
    return out, per
