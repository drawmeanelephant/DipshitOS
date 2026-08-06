"""Plain text and log parser: bounded, overlap-free windowing."""

from __future__ import annotations

from typing import List, Optional

from .base import BaseParser, ParsedChunk, ParseResult, window_chunks

WHOLE_FILE_LIMIT = 120


class PlainTextParser(BaseParser):
    name = "plaintext"

    def parse(self, text: str, path: Optional[str] = None) -> ParseResult:
        lines = text.splitlines()
        if len(lines) <= WHOLE_FILE_LIMIT:
            return ParseResult(
                [ParsedChunk(1, len(lines), text, "document",
                             structural_name=path, confidence=0.7)],
                "plaintext", 0.7,
            )
        return ParseResult(window_chunks(lines, kind="window"), "plaintext", 0.5)
