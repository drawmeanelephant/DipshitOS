"""Markdown parser: chunk by heading hierarchy with ancestry."""

from __future__ import annotations

import re
from typing import List, Optional

from .base import BaseParser, ParsedChunk, ParseResult, window_chunks

_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
# Merging policy: a parent section absorbs its subsections only when the
# parent's own body is tiny, every subsection is tiny, and the whole
# subtree is small — so ADR-style decision sections stay granular.
MERGE_PARENT_MAX = 3
MERGE_CHILD_MAX = 10
MERGE_TOTAL_MAX = 40


class MarkdownParser(BaseParser):
    name = "markdown"

    def parse(self, text: str, path: Optional[str] = None) -> ParseResult:
        lines = text.splitlines()
        headings = self._find_headings(lines)
        if not headings:
            if len(lines) <= 120:
                return ParseResult(
                    [ParsedChunk(1, len(lines), text, "document",
                                 structural_name=path, confidence=0.8)],
                    "markdown", 0.8,
                )
            return ParseResult(window_chunks(lines), "markdown", 0.5)

        chunks: List[ParsedChunk] = []
        # Document top (content before the first heading).
        first_heading_line = headings[0][0]
        if first_heading_line > 0:
            top = lines[:first_heading_line]
            if any(line.strip() for line in top):
                chunks.append(ParsedChunk(
                    1, first_heading_line, "\n".join(top),
                    "document", structural_name=path, confidence=0.8,
                ))

        stack: List[tuple] = []  # (level, title)
        for idx, (line_idx, level, title) in enumerate(headings):
            while stack and stack[-1][0] >= level:
                stack.pop()
            end = headings[idx + 1][0] - 1 if idx + 1 < len(headings) else len(lines) - 1
            ancestry = " > ".join(t for _, t in stack)
            heading = " > ".join([ancestry, title]) if ancestry else title
            chunks.append(ParsedChunk(
                line_idx + 1, end + 1, "\n".join(lines[line_idx:end + 1]),
                "section", structural_name=title, heading=heading, confidence=0.95,
            ))
            stack.append((level, title))

        merged = self._merge_small_sections(chunks)
        return ParseResult(merged, "markdown", 0.95)

    @staticmethod
    def _find_headings(lines: List[str]) -> List[tuple]:
        """(line_index_0based, level, title) pairs, skipping fenced code."""
        headings: List[tuple] = []
        fence: Optional[str] = None
        for i, line in enumerate(lines):
            stripped = line.strip()
            if fence is not None:
                if stripped.startswith(fence):
                    fence = None
                continue
            if stripped.startswith("```") or stripped.startswith("~~~"):
                fence = stripped[:3]
                continue
            match = _HEADING.match(stripped)
            if match:
                headings.append((i, len(match.group(1)), match.group(2).strip()))
        return headings

    @staticmethod
    def _merge_small_sections(
        chunks: List[ParsedChunk],
        parent_max: int = MERGE_PARENT_MAX,
        child_max: int = MERGE_CHILD_MAX,
        total_max: int = MERGE_TOTAL_MAX,
    ) -> List[ParsedChunk]:
        """Merge a heading's own body with its subsections when the whole
        subtree is small, so short neighboring sections stay together.
        Merged children are never emitted twice."""
        merged_away = set()
        out: List[ParsedChunk] = []
        for i, chunk in enumerate(chunks):
            if chunk.kind != "section":
                out.append(chunk)
                continue
            if id(chunk) in merged_away:
                continue
            prefix = chunk.heading + " > "
            children: List[ParsedChunk] = []
            for j in range(i + 1, len(chunks)):
                cand = chunks[j]
                if cand.kind != "section" or not cand.heading:
                    continue
                if cand.heading.startswith(prefix):
                    children.append(cand)
                elif cand.heading.startswith(chunk.heading + " "):
                    continue
                else:
                    break
            if children:
                parent_lines = chunk.end_line - chunk.start_line + 1
                child_lines = [c.end_line - c.start_line + 1 for c in children]
                total = parent_lines + sum(child_lines)
                if (parent_lines <= parent_max
                        and all(ln <= child_max for ln in child_lines)
                        and total <= total_max):
                    content = chunk.content + "\n" + "\n".join(c.content for c in children)
                    out.append(ParsedChunk(
                        chunk.start_line, children[-1].end_line, content,
                        "section", structural_name=chunk.structural_name,
                        heading=chunk.heading, confidence=chunk.confidence,
                    ))
                    for c in children:
                        merged_away.add(id(c))
                    continue
            out.append(chunk)
        return out
