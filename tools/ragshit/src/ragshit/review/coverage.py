"""Coverage model for review packets.

Dimensions are deterministic sets derived from impact analysis.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Set, Tuple

from ..impact.inventory import Inventory
from ..impact.symbols import SymbolMapping
from ..impact.neighborhood import Neighbor
from ..impact.scoring import FileScore
from ..impact.stale import StaleDoc
from .candidates import Candidate


@dataclass
class CoverageSpec:
    changed_symbols: Set[str] = field(default_factory=set)
    changed_files: Set[str] = field(default_factory=set)
    high_risk_files: Set[str] = field(default_factory=set)
    related_tests: Set[str] = field(default_factory=set)
    relevant_docs: Set[str] = field(default_factory=set)
    decision_docs: Set[str] = field(default_factory=set)
    stale_warnings: Set[str] = field(default_factory=set)

    @classmethod
    def from_impact(cls, inv: Inventory, mapping: SymbolMapping, neighbors, stale, file_scores: List[FileScore]) -> "CoverageSpec":
        changed_symbols = {s.name for s in mapping.symbols}
        changed_files = {f.path for f in inv.files}
        high_risk_files = {fs.path for fs in file_scores if fs.level in ("critical", "high")}
        related_tests = {n.path for n in neighbors if n.reason == "test-reference"}
        relevant_docs = {n.path for n in neighbors if n.reason in ("documentation-reference", "claim-reference", "decision-reference") or n.path.startswith("docs/") and n.reason in ("direct-symbol", "documentation-reference")}
        # Also docs from stale
        for s in stale:
            relevant_docs.add(s.path)
        # Include hardware-contract if it was added
        decision_docs = {p for p in relevant_docs if p.startswith("docs/decisions/") or p.startswith("docs/claims/") or p == "docs/hardware-contract.md"}
        stale_warnings = {f"{s.path}:{s.symbol}" for s in stale}
        return cls(
            changed_symbols=changed_symbols,
            changed_files=changed_files,
            high_risk_files=high_risk_files,
            related_tests=related_tests,
            relevant_docs=relevant_docs,
            decision_docs=decision_docs,
            stale_warnings=stale_warnings,
        )

    def as_dict(self) -> Dict[str, List[str]]:
        return {
            "changed_symbols": sorted(self.changed_symbols),
            "changed_files": sorted(self.changed_files),
            "high_risk_files": sorted(self.high_risk_files),
            "related_tests": sorted(self.related_tests),
            "relevant_docs": sorted(self.relevant_docs),
            "decision_docs": sorted(self.decision_docs),
            "stale_warnings": sorted(self.stale_warnings),
        }


def _candidate_covers_keys(c: Candidate) -> Set[str]:
    keys: Set[str] = set()
    for cov in c.covers:
        if cov.startswith("changed_symbol:"):
            keys.add(f"changed_symbols:{cov.split(':',1)[1]}")
        elif cov.startswith("changed_file:"):
            keys.add(f"changed_files:{cov.split(':',1)[1]}")
        elif cov.startswith("high_risk:"):
            keys.add(f"high_risk_files:{cov.split(':',1)[1]}")
        elif cov.startswith("test:"):
            keys.add(f"related_tests:{cov.split(':',1)[1]}")
        elif cov.startswith("doc:"):
            keys.add(f"relevant_docs:{cov.split(':',1)[1]}")
            p = cov.split(":", 1)[1]
            if p.startswith("docs/decisions/") or p.startswith("docs/claims/") or p == "docs/hardware-contract.md":
                keys.add(f"decision_docs:{p}")
        elif cov.startswith("stale:"):
            # cov is stale:path:symbol
            rest = cov.split(":", 1)[1]
            # rest = path:symbol (path may contain colons? not in repo)
            # reconstruct key as stale_warnings:path:symbol
            keys.add(f"stale_warnings:{rest}")
    return keys


def coverage_metrics(spec: CoverageSpec, selected: List[Candidate]) -> Dict[str, Dict[str, int]]:
    """Return per-dimension covered/total."""
    all_keys: Dict[str, Set[str]] = {
        "changed_symbols": {f"changed_symbols:{s}" for s in spec.changed_symbols},
        "changed_files": {f"changed_files:{p}" for p in spec.changed_files},
        "high_risk_files": {f"high_risk_files:{p}" for p in spec.high_risk_files},
        "related_tests": {f"related_tests:{p}" for p in spec.related_tests},
        "relevant_docs": {f"relevant_docs:{p}" for p in spec.relevant_docs},
        "decision_docs": {f"decision_docs:{p}" for p in spec.decision_docs},
        "stale_warnings": {f"stale_warnings:{s}" for s in spec.stale_warnings},
    }
    covered: Dict[str, Set[str]] = {k: set() for k in all_keys}
    for c in selected:
        for k in _candidate_covers_keys(c):
            dim = k.split(":", 1)[0]
            # handle stale key which has dimension stale_warnings
            if dim == "stale_warnings" or dim in covered:
                # Normalize dim name
                real_dim = dim
                if real_dim in covered and k in all_keys.get(real_dim, set()):
                    covered[real_dim].add(k)
                elif real_dim == "stale_warnings" and k in all_keys.get("stale_warnings", set()):
                    covered[real_dim].add(k)
                # else candidate covers something not in spec -> counts as extra but not in metric denominator
    metrics: Dict[str, Dict[str, int]] = {}
    for dim, universe in sorted(all_keys.items()):
        metrics[dim] = {"covered": len(covered[dim] & universe), "total": len(universe)}
    return metrics


def missing_coverage(spec: CoverageSpec, selected: List[Candidate]) -> Dict[str, List[str]]:
    metrics = coverage_metrics(spec, selected)
    # For each dimension list missing items deterministically
    out: Dict[str, List[str]] = {}
    covered_map = {}
    # Build covered per dim
    all_sets = {
        "changed_symbols": {f"changed_symbols:{s}" for s in spec.changed_symbols},
        "related_tests": {f"related_tests:{p}" for p in spec.related_tests},
        "relevant_docs": {f"relevant_docs:{p}" for p in spec.relevant_docs},
        "decision_docs": {f"decision_docs:{p}" for p in spec.decision_docs},
        "high_risk_files": {f"high_risk_files:{p}" for p in spec.high_risk_files},
        "changed_files": {f"changed_files:{p}" for p in spec.changed_files},
        "stale_warnings": {f"stale_warnings:{s}" for s in spec.stale_warnings},
    }
    # collect covered
    covered: Dict[str, Set[str]] = {k: set() for k in all_sets}
    for c in selected:
        for k in _candidate_covers_keys(c):
            dim = k.split(":", 1)[0]
            if dim in covered and k in all_sets.get(dim, set()):
                covered[dim].add(k)
    for dim in sorted(all_sets.keys()):
        missing = sorted(all_sets[dim] - covered[dim])
        # Strip prefix for readability
        stripped = [m.split(":", 1)[1] for m in missing]
        out[dim] = stripped
    return out
