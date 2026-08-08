"""Deterministic review-priority scoring. Heuristic, not bug predictor."""
from __future__ import annotations
import math, re
from dataclasses import dataclass
from typing import Dict, List, Tuple
from .inventory import ChangedFile, Inventory
from .symbols import SymbolMapping
CRITICAL_PREFIXES=("kernel/","boot/","host/")
CRITICAL_FILES={"build.zig","build.zig.zon","justfile"}
BUILDLIKE_RE=re.compile(r"(^|/)(Makefile|Justfile|build\.zig|build\.zig\.zon|Cargo\.toml|pyproject\.toml)$",re.I)
IMPACT_VERSION="1"
@dataclass
class FileScore:
    path: str; status: str; score: float; level: str; components: Dict[str,float]; lines_changed: int; symbols_touched: int
def _lines(cf: ChangedFile):
    return sum(e-s+1 for s,e in cf.ranges) if cf.ranges else (0 if cf.status.startswith("D") else 1)
def score_files(inv: Inventory, mapping: SymbolMapping, neighborhood_sizes: Dict[str,int], *, touched_tests=None) -> List[FileScore]:
    changed_paths={f.path for f in inv.files}
    has_test_changed=any("test" in p.lower() or p.startswith("tests/") or "/tests/" in p or "test_" in p for p in changed_paths)
    raw=[]
    for cf in inv.files:
        comps={}
        lines=_lines(cf)
        sym_count=len(mapping.per_file.get(cf.path,[]))
        refs=neighborhood_sizes.get(cf.path,0)
        comps["base"]=3.0 if cf.ranges else (2.0 if cf.status.startswith("A") else 1.0)
        comps["lines"]=round(min(10.0, math.log2(lines+1)*2.0),2) if lines>0 else 0.0
        comps["symbols"]=round(min(12.0, sym_count*3.0),2)
        comps["references"]=round(min(9.0, math.log2(refs+1)*3.0) if refs>0 else 0.0,2)
        if any(cf.path.startswith(p) for p in CRITICAL_PREFIXES): comps["critical_path"]=8.0
        elif cf.path in CRITICAL_FILES or BUILDLIKE_RE.search(cf.path): comps["critical_path"]=5.0
        else: comps["critical_path"]=0.0
        if cf.path.startswith("docs/decisions/") or cf.path=="docs/hardware-contract.md" or cf.path.startswith("docs/claims/"): comps["doc_touched"]=4.0
        else: comps["doc_touched"]=0.0
        comps["deleted"]=6.0 if cf.status.startswith("D") else 0.0
        comps["interface"]=3.0 if (cf.path in ("build.zig","build.zig.zon","justfile") or cf.path.startswith("host/") or cf.path in ("boot/src/main.zig",)) else 0.0
        is_impl=comps["critical_path"]>=5 or cf.path.endswith(".zig") or cf.path.endswith(".swift")
        if is_impl and not has_test_changed and refs==0:
            comps["no_test"]=4.0 if (lines>0 or sym_count>0) else 0.0
        elif is_impl and not has_test_changed and refs<3:
            comps["no_test"]=2.0
        else: comps["no_test"]=0.0
        comps["test_file"]=-1.5 if "test" in cf.path.lower() else 0.0
        total=round(sum(comps.values()),2)
        raw.append((cf.path,total,comps,lines,sym_count,cf))
    max_raw=max((t for _,t,_,_,_,_ in raw), default=1)
    scale=max(max_raw,20.0)
    out=[]
    for path,total,comps,lines,sym_count,cf in sorted(raw, key=lambda x:x[0]):
        norm=round(min(100.0,(total/scale)*100.0),1)
        if norm>=70: level="critical" if any(path.startswith(p) for p in CRITICAL_PREFIXES) else "high"
        elif norm>=45: level="high"
        elif norm>=22: level="medium"
        else: level="low"
        if level=="high" and norm>=80: level="critical"
        pruned={k:v for k,v in comps.items() if v!=0}
        out.append(FileScore(path=path,status=cf.status,score=norm,level=level,components=pruned,lines_changed=lines,symbols_touched=sym_count))
    out.sort(key=lambda f:(-f.score,f.path))
    return out
