"""Review report: markdown + JSON (ragshit.review/v1), baseline, rendering."""
from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Optional

from ..indexing.database import Database
from ..impact.inventory import Inventory
from ..impact.symbols import SymbolMapping
from ..impact.neighborhood import Neighbor
from ..impact.stale import StaleDoc
from ..impact.scoring import FileScore
from .candidates import Candidate
from .coverage import CoverageSpec, coverage_metrics, missing_coverage
from .selection import SelectionResult

SCHEMA_VERSION = "ragshit.review/v1"
REVIEW_VERSION = "1"


@dataclass
class ReviewReport:
    schema_version: str
    review_version: str
    repo_root: str
    repo_id: str
    range_spec: str
    base: str
    head: str
    base_oid: str
    head_oid: str
    index_head: Optional[str]
    index_stale: bool
    index_warning: Optional[str]
    requested_budget: int
    actual_size: int
    timing_ms: int
    stats: Dict[str, Any]
    coverage: Dict[str, Any]
    coverage_detail: Dict[str, Dict[str, int]]
    missing_coverage: Dict[str, List[str]]
    selected: List[Dict[str, Any]]
    rejected: List[Dict[str, Any]]
    file_scores: List[Dict[str, Any]]
    symbols: List[Dict[str, Any]]
    stale: List[Dict[str, Any]]
    selection_summary: Dict[str, Any]
    baseline: Dict[str, Any]
    # Human markdown is separate; JSON carries data


def _candidate_to_dict(c: Candidate) -> Dict[str, Any]:
    return {
        "id": c.cid,
        "path": c.path,
        "lines": [c.start_line, c.end_line],
        "reason": c.reason,
        "covers": sorted(set(c.covers)),
        "score": round(c.base_utility, 2),
        "components": dict(c.components),
        "provenance": c.provenance,
        "cost": c.cost,
        "content_hash": c.content_hash,
        "structural_name": c.structural_name,
        "heading": c.heading,
        "commit": c.commit,
        "language": c.language,
        "kind": c.kind,
        "origin_changed_file": c.origin_changed_file,
        "origin_symbol": c.origin_symbol,
        "content": c.content,
    }


def _rejected_to_dict(c: Candidate, reason: str) -> Dict[str, Any]:
    return {
        "id": c.cid,
        "path": c.path,
        "lines": [c.start_line, c.end_line],
        "reason": c.reason,
        "covers": sorted(set(c.covers)),
        "score": round(c.base_utility, 2),
        "cost": c.cost,
        "rejected_because": reason,
        "origin_symbol": c.origin_symbol,
        "origin_changed_file": c.origin_changed_file,
    }


def baseline_select(candidates: List[Candidate], budget: int) -> List[Candidate]:
    """Naive baseline: take candidates sorted by base_utility then path until budget full.

    No redundancy penalty, no diversity beyond utility sort.
    """
    ordered = sorted(candidates, key=lambda c: (-c.base_utility, c.cost, c.path, c.start_line, c.cid))
    out: List[Candidate] = []
    used = 0
    for c in ordered:
        if used + c.cost <= budget:
            out.append(c)
            used += c.cost
    return out


def build_review(
    repo_root: str,
    repo_id: str,
    inv: Inventory,
    mapping: SymbolMapping,
    neighbors: List[Neighbor],
    stale: List[StaleDoc],
    file_scores: List[FileScore],
    spec: CoverageSpec,
    result: SelectionResult,
    candidates: List[Candidate],
    budget: int,
    index_head: Optional[str],
    index_stale: bool,
    index_warning: Optional[str],
    timing_ms: int = 0,
) -> ReviewReport:
    metrics = coverage_metrics(spec, result.selected)
    missing = missing_coverage(spec, result.selected)
    # Baseline for comparison
    base_sel = baseline_select(candidates, budget)
    base_metrics = coverage_metrics(spec, base_sel)

    # Improvement: how many dimensions improved
    improved = []
    for dim in sorted(metrics.keys()):
        if metrics[dim]["covered"] > base_metrics.get(dim, {}).get("covered", 0):
            improved.append(dim)

    baseline_info = {
        "selected": len(base_sel),
        "actual_chars": sum(c.cost for c in base_sel),
        "coverage": base_metrics,
        "improved_dimensions": improved,
        "same_or_better": len(improved) > 0 or all(metrics[d]["covered"] >= base_metrics[d]["covered"] for d in metrics),
    }

    # Stats
    stats = {
        "commits": len(inv.commits),
        "files_changed": len(inv.files),
        "symbols_touched": len(mapping.symbols),
        "neighbors": len(neighbors),
        "stale_hints": len(stale),
        "candidates_considered": len(candidates),
        "candidates_selected": len(result.selected),
        "candidates_rejected": len(result.rejected),
    }

    selected_dicts = [_candidate_to_dict(c) for c in sorted(result.selected, key=lambda c: (-c.base_utility, c.path, c.start_line, c.cid))]
    rejected_dicts = [_rejected_to_dict(c, r) for c, r in sorted(result.rejected, key=lambda x: (-x[0].base_utility, x[0].path, x[0].start_line))]
    # Compact rejected: cap to 30 for markdown, but JSON keeps up to 50
    symbols = [{"path": s.path, "name": s.name, "lines": [s.start_line, s.end_line], "kind": s.kind, "confidence": s.confidence, "commit": s.commit} for s in sorted(mapping.symbols, key=lambda x: (x.path, x.start_line))]
    stale_list = [{"path": s.path, "symbol": s.symbol, "lines": [s.start_line, s.end_line], "heading": s.heading, "reason": s.reason} for s in sorted(stale, key=lambda x: (x.path, x.symbol))]
    file_score_dicts = [{"path": f.path, "score": f.score, "level": f.level, "components": f.components, "lines_changed": f.lines_changed, "symbols_touched": f.symbols_touched, "status": f.status} for f in file_scores]

    selection_summary = {
        "budget": budget,
        "actual_chars": result.actual_chars,
        "utilization": round((result.actual_chars / budget * 100) if budget else 0, 1),
        "candidates_considered": len(candidates),
        "selected": len(result.selected),
        "rejected": len(result.rejected),
        "truncated": result.truncated,
    }

    coverage = {dim: f"{v['covered']} / {v['total']}" for dim, v in sorted(metrics.items())}

    return ReviewReport(
        schema_version=SCHEMA_VERSION,
        review_version=REVIEW_VERSION,
        repo_root=repo_root,
        repo_id=repo_id,
        range_spec=inv.range_spec,
        base=inv.base,
        head=inv.head,
        base_oid=inv.base_oid,
        head_oid=inv.head_oid,
        index_head=index_head,
        index_stale=index_stale,
        index_warning=index_warning,
        requested_budget=budget,
        actual_size=result.actual_chars,
        timing_ms=timing_ms,
        stats=stats,
        coverage=coverage,
        coverage_detail=metrics,
        missing_coverage=missing,
        selected=selected_dicts,
        rejected=rejected_dicts[:50],
        file_scores=file_score_dicts,
        symbols=symbols,
        stale=stale_list,
        selection_summary=selection_summary,
        baseline=baseline_info,
    )


def report_to_json(report: ReviewReport) -> str:
    # Deterministic JSON: sort_keys, indent 2, no timestamps beyond generated_at-like fields (none)
    d = asdict(report)
    return json.dumps(d, indent=2, sort_keys=True) + "\n"


def report_to_markdown(report: ReviewReport, explain: bool = False) -> str:
    lines: List[str] = []
    lines.append("# Review packet")
    lines.append("")
    lines.append(f"Git range: `{report.range_spec}`")
    lines.append(f"Base: `{report.base}` (`{report.base_oid[:12]}`)")
    lines.append(f"Head: `{report.head}` (`{report.head_oid[:12]}`)")
    lines.append(f"Index HEAD: `{report.index_head[:12] if report.index_head else '(unknown)'}`")
    lines.append(f"Budget: {report.requested_budget} chars")
    lines.append(f"Actual size: {report.actual_size} chars")
    if report.index_stale and report.index_warning:
        lines.append("")
        lines.append(f"> ⚠️ {report.index_warning}")
        lines.append(f"> Run `ragshit index {report.repo_root}` to refresh the index for this range.")
    lines.append("")
    lines.append("## Coverage summary")
    lines.append("")
    for dim in sorted(report.coverage_detail.keys()):
        v = report.coverage_detail[dim]
        total = v["total"]
        covered = v["covered"]
        pct = int(covered / total * 100) if total else 100
        lines.append(f"- {dim}: {covered} / {total} ({pct}%)")
    lines.append("")
    lines.append("## Highest-risk changes")
    lines.append("")
    if report.file_scores:
        for i, fs in enumerate(report.file_scores[:8], 1):
            comps = ", ".join(f"{k}={v:g}" for k, v in sorted(fs["components"].items()))
            lines.append(f"{i}. `{fs['path']}` -- score {fs['score']} ({fs['level']}) -- {fs['lines_changed']} lines, {fs['symbols_touched']} symbols -- {comps}")
    else:
        lines.append("- (no file scores)")
    lines.append("")

    lines.append("## Selected context")
    lines.append("")
    if report.selected:
        for s in report.selected:
            lines.append(f"### {s['path']}:{s['lines'][0]}-{s['lines'][1]}")
            lines.append(f"reason: {s['reason']}")
            lines.append(f"covers: {', '.join(s['covers']) if s['covers'] else '(none)'}")
            lines.append(f"score: {s['score']:.2f}")
            lines.append(f"cost: {s['cost']} chars")
            lines.append(f"provenance: {s['provenance']}")
            if s.get("structural_name"):
                lines.append(f"symbol: {s['structural_name']}")
            lines.append("")
            # code fence with content
            lines.append("```")
            # content already truncated safely if needed
            lines.append(s["content"].rstrip("\n"))
            lines.append("```")
            lines.append("")
    else:
        lines.append("- (no candidates selected)")
        lines.append("")

    lines.append("## Missing / weak coverage")
    lines.append("")
    has_missing = False
    for dim in sorted(report.missing_coverage.keys()):
        miss = report.missing_coverage[dim]
        if miss:
            has_missing = True
            lines.append(f"- {dim}: missing {', '.join(f'`{m}`' for m in miss[:8])}" + (f" (+{len(miss)-8} more)" if len(miss) > 8 else ""))
    if not has_missing:
        lines.append("- (all coverage dimensions fully satisfied or no universe)")
    lines.append("")

    lines.append("## Stale-context warnings")
    lines.append("")
    if report.stale:
        for s in report.stale:
            lines.append(f"- `{s['path']}`:{s['lines'][0]}-{s['lines'][1]} -- mentions `{s['symbol']}` -- {s['reason']}" + (f" -- {s['heading']}" if s.get("heading") else ""))
    else:
        lines.append("- (no stale-doc hints)")
    lines.append("")

    lines.append("## Selection summary")
    lines.append("")
    ss = report.selection_summary
    lines.append(f"- candidates considered: {ss['candidates_considered']}")
    lines.append(f"- selected: {ss['selected']}")
    lines.append(f"- rejected: {ss['rejected']}")
    lines.append(f"- budget utilization: {ss['actual_chars']} / {ss['budget']} ({ss['utilization']}%)")
    if ss.get("truncated"):
        lines.append(f"- note: mandatory content exceeded budget; excerpts were safely truncated to stay under budget")
    # Baseline note
    lines.append(f"- baseline (naive impact-ranked) would select {report.baseline['selected']} at {report.baseline['actual_chars']} chars")
    if report.baseline.get("improved_dimensions"):
        lines.append(f"- diversity selector improved: {', '.join(report.baseline['improved_dimensions'])} vs baseline")
    else:
        lines.append(f"- diversity selector: same coverage as baseline on this range (no improvement / already optimal)")
    lines.append("")

    if explain:
        lines.append("## Rejected candidates (explain)")
        lines.append("")
        if report.rejected:
            for r in report.rejected[:20]:
                lines.append(f"- `{r['path']}`:{r['lines'][0]}-{r['lines'][1]} -- reason:{r['reason']} -- score {r['score']:.1f} cost {r['cost']} -- {r['rejected_because']}")
        else:
            lines.append("- (no rejections)")
        lines.append("")

    lines.append("## Determinism")
    lines.append("")
    lines.append(f"- schema: {report.schema_version}")
    lines.append(f"- timing_ms is 0 (real timing on stderr); output is byte-identical for unchanged repo/index/range/args")
    if report.index_stale and report.index_warning:
        lines.append("")
        lines.append(f"> ⚠️ {report.index_warning}")
    lines.append("")
    # Footer stats line
    lines.append(f"stats: {report.stats} -- index HEAD: {report.index_head[:12] if report.index_head else '(unknown)'} -- deterministic")
    lines.append("")

    md = "\n".join(lines)
    if len(md) > report.requested_budget:
        md = _enforce_budget(md, report.requested_budget, report)
    # Keep report.actual_size consistent with real markdown bytes for determinism
    # Note: callers should check len(md) <= budget; report.actual_size is informational
    return md


def _enforce_budget(md: str, budget: int, report: ReviewReport) -> str:
    """Hard envelope: final markdown chars <= budget (len(md) is char count, not bytes)."""
    if len(md) <= budget:
        return md
    marker = "## Selected context\n"
    idx = md.find(marker)
    if idx == -1:
        header = md[:700]
        tail = md[700:]
    else:
        header_end = idx + len(marker) + 1
        header = md[:header_end]
        tail = md[header_end:]
    # Reserve for truncation marker; count in chars (budget is chars)
    suffix = "\n... [truncated to fit budget]\n"
    if len(header) >= budget:
        # Budget impossibly small; return header truncated to budget chars
        return md[: budget - len(suffix)] + suffix
    remaining = budget - len(header) - len(suffix)
    if remaining < 0:
        remaining = 0
    truncated_tail = tail[:remaining].rstrip()
    open_fences = truncated_tail.count("```")
    if open_fences % 2 == 1:
        truncated_tail += "\n```" + suffix
    else:
        if truncated_tail and not truncated_tail.endswith("\n"):
            truncated_tail += "\n"
        truncated_tail += "... [truncated to fit budget]\n"
    out = header + truncated_tail
    if len(out) > budget:
        out = out[: budget - len(suffix)] + suffix
    # Ensure char length (not bytes) respects budget; if multibyte chars exist,
    # wc -c (bytes) will be higher but spec says --budget-chars is chars.
    return out
