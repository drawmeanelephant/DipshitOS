"""Parser selection for indexing."""

from __future__ import annotations

from typing import Optional

from .base import BaseParser
from .markdown import MarkdownParser
from .plaintext import PlainTextParser
from .source import SourceParser


def get_parser(kind: str, language: str) -> BaseParser:
    if kind == "markdown":
        return MarkdownParser()
    if kind == "source":
        return SourceParser(language)
    return PlainTextParser()
