"""Symbol-level impact: map changed hunks to enclosing indexed symbols."""
from __future__ import annotations
import pathlib, subprocess
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

def _fallback_parse_deleted(repo, base_oid: str, path: str) -> List[ChangedSymbol]:
    """When a file was deleted and the index no longer has chunks for it,
    recover symbols by parsing the base revision directly via git show.
    Returns empty on any failure (binary, not found, unparsable).
    """
    if repo is None or not base_oid or not path:
        return []
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo.root), "show", f"{base_oid}:{path}"],
            capture_output=True, timeout=30,
        )
        if proc.returncode != 0:
            return []
        raw = proc.stdout
        if not raw or b"\x00" in raw[:8192]:
            return []
        text = raw.decode("utf-8", errors="replace")
        # Detect kind/language the same way the indexer does
        from ..discovery.files import detect_kind
        from ..parsing import get_parser
        first_line = text.splitlines()[0] if text else ""
        kind, language = detect_kind(path, first_line)
        result = get_parser(kind, language).parse(text, path)
        out: List[ChangedSymbol] = []
        for pc in result.chunks:
            if pc.structural_name:
                out.append(ChangedSymbol(path=path, name=pc.structural_name, kind=pc.kind, start_line=pc.start_line, end_line=pc.end_line, confidence=pc.confidence, commit=None))
        # If no structural symbols but file existed, fall back to a synthetic
        # entry so the deleted symbol is at least surfaced as the file itself.
        if not out:
            # Only synthesize for source-like files; plaintext notes stay unresolved
            if kind == "source" and text.strip():
                stem = pathlib.Path(path).stem
                if stem:
                    out.append(ChangedSymbol(path=path, name=stem, kind="file", start_line=1, end_line=len(text.splitlines()), confidence=0.5, commit=None))
        return out
    except Exception:
        return []

def map_symbols(db: Database, repo_id: str, inv: Inventory, repo=None) -> SymbolMapping:
    symbols=[]; unresolved=[]; per_file={}
    for cf in inv.files:
        if cf.status.startswith("D"):
            chunks=[]
            try: chunks=db.chunks_for_path(repo_id, cf.path)
            except Exception: chunks=[]
            structural = [c for c in chunks if c.structural_name]
            if structural:
                for c in structural:
                    cs=ChangedSymbol(path=cf.path, name=c.structural_name, kind=c.kind, start_line=c.start_line, end_line=c.end_line, confidence=c.confidence, commit=c.commit)
                    symbols.append(cs); per_file.setdefault(cf.path,[]).append(cs)
            else:
                # DB has no chunks (index refreshed past deletion) -> fallback to base
                recovered = _fallback_parse_deleted(repo, inv.base_oid, cf.path)
                if recovered:
                    for cs in recovered:
                        symbols.append(cs); per_file.setdefault(cf.path,[]).append(cs)
                else:
                    unresolved.append(cf.path)
            if cf.path not in per_file and cf.path not in unresolved:
                unresolved.append(cf.path)
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
