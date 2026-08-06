"""JSONL rendering: one JSON object per line, machine-consumable."""

from __future__ import annotations

import json
from typing import List

from ..models import RetrievedChunk
from .bundle import Bundle


def _result_obj(result: RetrievedChunk, explain: bool = False) -> dict:
    c = result.chunk
    obj = {
        "path": c.path,
        "lines": [c.start_line, c.end_line],
        "kind": c.kind,
        "language": c.language,
        "score": result.score,
        "content": c.content,
    }
    if c.structural_name:
        obj["symbol"] = c.structural_name
    if c.heading:
        obj["heading"] = c.heading
    if c.commit:
        obj["commit"] = c.commit
    if explain:
        obj["explain"] = {k: v for k, v in sorted(result.components.items()) if v}
    return obj


def render_query_jsonl(results: List[RetrievedChunk], explain: bool = False) -> str:
    return "\n".join(json.dumps(_result_obj(r, explain)) for r in results) + "\n"


def render_bundle_jsonl(bundle: Bundle) -> str:
    obj = {
        "request": bundle.request,
        "repository_state": bundle.repo_state,
        "retrieval_summary": bundle.retrieval_summary,
        "current_diff": bundle.diff_section,
        "sources": [_result_obj(r, True) for r in bundle.sources],
        "omissions": bundle.omissions,
        "unresolved_evidence": bundle.evidence_notes,
        "total_characters": bundle.total_characters,
    }
    return json.dumps(obj, indent=2) + "\n"
