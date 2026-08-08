"""Impact report model + rendering."""
from __future__ import annotations
import json, time
from dataclasses import dataclass, asdict
from typing import Any, Dict, List, Optional
from .inventory import Inventory
from .symbols import SymbolMapping
from .neighborhood import Neighbor
from .stale import StaleDoc
from .scoring import FileScore
SCHEMA_VERSION="ragshit.impact/v1"
IMPACT_VERSION="1"
@dataclass
class ImpactReport:
    schema_version: str; impact_version: str; repo_root: str; repo_id: str; range_spec: str; base: str; head: str; base_oid: str; head_oid: str; generated_at: str; commits: List[Dict[str,Any]]; files: List[Dict[str,Any]]; symbols: List[Dict[str,Any]]; unresolved_files: List[str]; file_scores: List[Dict[str,Any]]; neighbors: List[Dict[str,Any]]; stale_docs: List[Dict[str,Any]]; stale_filtered: List[Dict[str,Any]]; stats: Dict[str,Any]; index_head: Optional[str]; index_stale: bool; index_warning: Optional[str]; timing_ms: int
def build_report(repo_root, repo_id, inv, mapping, neighbors, file_scores, stale, timing_ms, index_head, index_stale=False, index_warning=None, stale_filtered=None):
    files=[{"path":f.path,"status":f.status,"old_path":f.old_path,"ranges":f.ranges,"extension":f.extension} for f in sorted(inv.files,key=lambda x:x.path)]
    symbols=[{"path":s.path,"name":s.name,"kind":s.kind,"lines":[s.start_line,s.end_line],"confidence":s.confidence,"commit":s.commit} for s in sorted(mapping.symbols,key=lambda x:(x.path,x.start_line,x.name))]
    nd=[{"path":n.path,"lines":[n.start_line,n.end_line],"kind":n.kind,"symbol":n.structural_name,"reason":n.reason,"query":n.query,"language":n.language,"heading":n.heading,"commit":n.commit} for n in sorted(neighbors,key=lambda x:(x.path,x.start_line,x.query))]
    sd=[{"path":s.path,"symbol":s.symbol,"lines":[s.start_line,s.end_line],"heading":s.heading,"reason":s.reason} for s in sorted(stale,key=lambda x:(x.path,x.symbol))]
    sf=list(stale_filtered or [])
    fsd=[{"path":f.path,"status":f.status,"score":f.score,"level":f.level,"components":f.components,"lines_changed":f.lines_changed,"symbols_touched":f.symbols_touched} for f in file_scores]
    commits=[{"hash":c.hash,"short":c.short,"subject":c.subject,"author":c.author,"date":c.date} for c in inv.commits]
    stats={"commits":len(commits),"files_changed":len(files),"symbols_touched":len(symbols),"neighbors":len(nd),"stale_hints":len(sd),"has_rename":inv.has_rename,"dirty_note":inv.dirty_note}
    return ImpactReport(schema_version=SCHEMA_VERSION, impact_version=IMPACT_VERSION, repo_root=repo_root, repo_id=repo_id, range_spec=inv.range_spec, base=inv.base, head=inv.head, base_oid=inv.base_oid, head_oid=inv.head_oid, generated_at=(commits[0]["date"] if commits else "1970-01-01T00:00:00Z"), commits=commits, files=files, symbols=symbols, unresolved_files=sorted(mapping.unresolved_files), file_scores=fsd, neighbors=nd, stale_docs=sd, stale_filtered=sf, stats=stats, index_head=index_head, index_stale=index_stale, index_warning=index_warning, timing_ms=timing_ms)
def report_to_json(report):
    return json.dumps(asdict(report), indent=2, sort_keys=True)+"\n"
def report_to_markdown(report, bundle=None):
    lines=[]
    lines.append("# Change impact"); lines.append("")
    lines.append(f"Git range: `{report.range_spec}`")
    lines.append(f"Base: `{report.base}` (`{report.base_oid[:12]}`)")
    lines.append(f"Head: `{report.head}` (`{report.head_oid[:12]}`)")
    if report.index_stale and report.index_warning:
        lines.append("")
        lines.append(f"> ⚠️ {report.index_warning}")
        lines.append(f"> Run `ragshit index {report.repo_root}` to refresh the index for this range.")
    lines.append("")
    lines.append("## Commits")
    if report.commits:
        for c in report.commits: lines.append(f"- `{c['short']}` {c['subject']} -- {c['author']}")
    else: lines.append("- (no commits in range)")
    lines.append("")
    lines.append(f"## Changed files ({len(report.files)})")
    for f in report.files:
        r=", ".join(f"{a}-{b}" for a,b in f["ranges"]) if f["ranges"] else "no new lines"
        old=f" -> {f['old_path']}" if f['old_path'] else ""
        lines.append(f"- `{f['status']}` `{f['path']}`{old} ({r})")
    if report.stats.get("dirty_note"): lines.append(f"- Note: {report.stats['dirty_note']} (not in range)")
    lines.append("")
    lines.append("## Highest-priority review areas")
    if report.file_scores:
        for i,fs in enumerate(report.file_scores[:10],1):
            comps=", ".join(f"{k}={v:g}" for k,v in sorted(fs["components"].items()))
            lines.append(f"{i}. `{fs['path']}` -- score {fs['score']} ({fs['level']}) -- {fs['lines_changed']} lines, {fs['symbols_touched']} symbols -- {comps}")
    else: lines.append("- (no file scores)")
    lines.append(""); lines.append("### Scoring formula (deterministic heuristic)")
    lines.append("Components sum then normalized 0..100. See tools/ragshit/docs/ranking.md#impact and scoring.py. Review-priority heuristic, not bug predictor."); lines.append("")
    lines.append("## Changed symbols")
    if report.symbols:
        for s in report.symbols: lines.append(f"- `{s['name']}` in `{s['path']}` -- lines {s['lines'][0]}-{s['lines'][1]} -- commit:{s['commit'] or '?' } -- kind={s['kind']} conf={s['confidence']:.2f}")
    else: lines.append("- (no symbols resolved)")
    if report.unresolved_files:
        lines.append(""); lines.append("Unresolved (no symbol confidently assigned):")
        for p in report.unresolved_files: lines.append(f"- `{p}` -- change could not be assigned confidently to a symbol")
    lines.append("")
    tn=[n for n in report.neighbors if n["reason"]=="test-reference"]
    lines.append("## Related tests")
    if tn:
        for n in sorted(tn, key=lambda x:(x["path"],x["lines"]))[:20]: lines.append(f"- `{n['path']}`:{n['lines'][0]}-{n['lines'][1]} -- {n['reason']} for `{n['query']}` -- commit:{n['commit'] or '?'}")
    else: lines.append("- (no test references found)")
    lines.append("")
    dn=[n for n in report.neighbors if n["reason"] in ("documentation-reference","direct-symbol")]
    lines.append("## Relevant documentation / ADRs / claims")
    if dn:
        for n in sorted(dn, key=lambda x:(x["path"],x["query"]))[:20]: lines.append(f"- `{n['path']}`:{n['lines'][0]}-{n['lines'][1]} -- {n['reason']} for `{n['query']}`" + (f" -- {n['heading']}" if n['heading'] else ""))
    else: lines.append("- (no documentation references found)")
    lines.append(""); lines.append("## Reference neighborhood (all evidence-labeled)")
    if report.neighbors:
        for n in report.neighbors[:30]: lines.append(f"- `{n['path']}`:{n['lines'][0]}-{n['lines'][1]} -- {n['reason']} for `{n['query']}` -- kind={n['kind']} lang={n['language']} commit={n['commit'] or '?'}")
    else: lines.append("- (no neighborhood hits)")
    lines.append("");    lines.append("## Potentially stale context (review hint only)")
    lines.append("Documentation mentioning a changed symbol but not changed in this range. Do not auto-edit; verify manually.")
    if report.stale_docs:
        for s in report.stale_docs: lines.append(f"- `{s['path']}`:{s['lines'][0]}-{s['lines'][1]} -- mentions `{s['symbol']}`" + (f" -- {s['heading']}" if s['heading'] else ""))
    else: lines.append("- (no stale-doc hints)")
    if report.stale_filtered:
        details=", ".join(f"`{f['symbol']}` ({'; '.join(f['reasons']) })" for f in report.stale_filtered)
        lines.append(f"- filtered generic symbols (no hints generated): {details}")
    lines.append("")
    if bundle: lines.append("## Review packet (provenance-backed excerpts)"); lines.append(bundle.rstrip()); lines.append("")
    # Deterministic footer: no timing; index staleness is explicit
    if report.index_stale and report.index_warning:
        lines.append(f"> ⚠️ {report.index_warning}")
        lines.append("")
    lines.append(f"stats: {report.stats} -- index HEAD: {report.index_head[:12] if report.index_head else '(unknown)'} -- deterministic: timing_ms is 0 (real timing on stderr)")
    lines.append("")
    return "\n".join(lines)
