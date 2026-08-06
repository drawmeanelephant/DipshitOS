"""Parser base types and shared line-window chunking.

All parsers emit :class:`ParsedChunk` objects with 1-based inclusive line
ranges. A line is never split: chunk boundaries always fall on line
boundaries.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional

DEFAULT_WINDOW = 120
DEFAULT_OVERLAP = 20


@dataclass
class ParsedChunk:
    start_line: int
    end_line: int
    content: str
    kind: str
    structural_name: Optional[str] = None
    heading: Optional[str] = None
    confidence: float = 1.0


@dataclass
class ParseResult:
    chunks: List[ParsedChunk]
    parser: str
    confidence: float


class BaseParser:
    name = "base"

    def parse(self, text: str, path: Optional[str] = None) -> ParseResult:
        raise NotImplementedError


def window_chunks(
    lines: List[str],
    window: int = DEFAULT_WINDOW,
    overlap: int = DEFAULT_OVERLAP,
    kind: str = "window",
    confidence: float = 0.5,
) -> List[ParsedChunk]:
    """Overlapping line windows. Never splits a line."""
    n = len(lines)
    if n == 0:
        return []
    if overlap >= window:
        overlap = 0
    chunks: List[ParsedChunk] = []
    start = 0
    while start < n:
        end = min(start + window, n)
        chunks.append(ParsedChunk(
            start + 1, end, "\n".join(lines[start:end]), kind, confidence=confidence,
        ))
        if end == n:
            break
        start = max(start + window - overlap, start + 1)
    return chunks
