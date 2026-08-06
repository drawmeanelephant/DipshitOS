"""Markdown rendering of retrieval results."""

from __future__ import annotations

from typing import List, Optional

from ..models import RetrievedChunk


def render_source_block(result: RetrievedChunk, explain: bool = False) -> str:
    c = result.chunk
    lines = ["===== BEGIN SOURCE ====="]
    lines.append(f"path: {c.path}")
    lines.append(f"lines: {c.start_line}-{c.end_line}")
    lines.append(f"kind: {c.kind}")
    if c.structural_name:
        lines.append(f"symbol: {c.structural_name}")
    if c.heading:
        lines.append(f"heading: {c.heading}")
    if c.language:
        lines.append(f"language: {c.language}")
    if c.commit:
        lines.append(f"commit: {c.commit}")
    lines.append(f"score: {result.score:.2f}")
    if explain:
        for name in sorted(result.components):
            value = result.components[name]
            if value:
                lines.append(f"  {name}: +{value:.2f}")
    lines.append("===== CONTENT =====")
    lines.append(c.content.rstrip("\n"))
    lines.append("===== END SOURCE =====")
    return "\n".join(lines)


def render_query_markdown(results: List[RetrievedChunk], explain: bool = False,
                          query_text: Optional[str] = None) -> str:
    out = ["# Ragshit query results", ""]
    if query_text:
        out += [f"Query: `{query_text}`", ""]
    out.append(f"{len(results)} result(s)")
    out.append("")
    out.append("\n\n".join(render_source_block(r, explain) for r in results))
    out.append("")
    return "\n".join(out)
