"""Source parsers: conservative structural heuristics per language.

No compiler parser. Declarations are found with per-language regular
expressions; a declaration's chunk runs from its line (plus preceding
comment lines) to the next declaration or the end of its brace block.
When no structure is found, overlapping line windows are used and parser
confidence drops.
"""

from __future__ import annotations

import re
from typing import List, Optional, Tuple

from .base import BaseParser, ParsedChunk, ParseResult, window_chunks

_DECL_PATTERNS = {
    "zig": [
        (r"^\s*pub\s+(?:export\s+)?(?:inline\s+)?(?:threadlocal\s+)?fn\s+([A-Za-z_]\w*)", "function"),
        (r"^\s*(?:extern\s+)?(?:export\s+)?fn\s+([A-Za-z_]\w*)", "function"),
        (r"^\s*pub\s+(?:const|var)\s+([A-Za-z_]\w*)", "constant"),
        (r"^\s*pub\s+const\s+([A-Za-z_]\w*)\s*=\s*(struct|enum|union|error|fn)\b", "type"),
        (r"^\s*const\s+([A-Za-z_]\w*)\s*=\s*(struct|enum|union|error|fn)\b", "type"),
        (r'^\s*test\s+"([^"]+)"', "test"),
    ],
    "swift": [
        (r"^\s*(?:@\w+\s+)*(?:open|public|internal|fileprivate|private|static|final|mutating|nonisolated|async\s+)*func\s+([A-Za-z_]\w*)", "function"),
        (r"^\s*(?:@\w+\s+)*(?:open|public|internal|fileprivate|private|final\s+)*(class|struct|enum|protocol|extension)\s+([A-Za-z_]\w*)", "type"),
        (r"^\s*(?:open|public|internal|fileprivate|private|static)\s+(?:let|var)\s+([A-Za-z_]\w*)", "constant"),
    ],
    "python": [
        (r"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)", "function"),
        (r"^\s*class\s+([A-Za-z_]\w*)", "type"),
    ],
    "shell": [
        (r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*\{?\s*$", "function"),
        (r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(?!=)", "constant"),
    ],
    "c": [
        (r"^\s*#\s*(define|undef|pragma)\s+([A-Za-z_]\w*)", "macro"),
        (r"^\s*(?:typedef\s+)?(struct|union|enum)\s+([A-Za-z_]\w*)", "type"),
        (r"^[\w\s\*]+?\b([A-Za-z_]\w*)\s*\([^;]*$", "function"),
    ],
    "assembly": [
        (r'^\s*\.(?:section|text|data|bss|rodata|globl|global)\b\s*(?:"?([^"\s]+)"?)?', "section"),
        (r"^([A-Za-z_.$][\w.$]*):", "label"),
    ],
    "linker": [
        (r"^(SECTIONS|MEMORY|PHDRS|VERSION)\b", "section"),
        (r"^ENTRY\s*\(\s*([A-Za-z_]\w*)", "entry"),
        (r"^\s*(\.\w+)\s*:", "output-section"),
    ],
    "toml": [
        (r"^\[([^\]]+)\]", "section"),
        (r"^([A-Za-z_][\w.-]*)\s*=", "key"),
    ],
    "yaml": [
        (r"^([A-Za-z_][\w-]*)\s*:", "key"),
    ],
}

_BRACED_LANGUAGES = {"zig", "swift", "c"}
_CONTROL_GUARD = re.compile(r"^\s*(for|if|while|switch|return|sizeof|catch|do)\b")
_COMMENT_PREFIXES = ("#", "//", ";")

# Shell structural importance (fix D): a function opener `name() {` starts a
# body block; assignments inside the body belong to the enclosing function
# chunk, never becoming independent declaration units. The block closes at the
# first `}` line. Trailing `#` comments are tolerated; `name()` with the brace
# on the NEXT line is a documented limitation (kept at the old behavior).
_SHELL_FUNC_OPEN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*\{\s*(?:#.*)?$")
_SHELL_BLOCK_CLOSE = re.compile(r"^\}\s*(?:#.*)?$")
_SHELL_DECL_FUNC = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\)\s*\{?\s*$")
_SHELL_DECL_ASSIGN = re.compile(r"^(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*=(?!=)")


def shell_decl_kind(text: str) -> Optional[str]:
    """Classify the leading shell declaration of a chunk: ``"function"``,
    ``"constant"`` (assignment), or ``None``. Scans past comment and command
    lines (a chunk may open with the file header before its first
    declaration) until the first declaration line, mirroring the parser's own
    decl patterns so classification can never drift from what produced the
    chunk. Used by impact/review to weight shell symbols: functions are
    meaningful structural context, one-line assignments are low-value
    bookkeeping."""
    if not text:
        return None
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if _SHELL_DECL_FUNC.match(s):
            return "function"
        if _SHELL_DECL_ASSIGN.match(s):
            return "constant"
    return None


def _braced_end(lines: List[str], start: int) -> Optional[int]:
    """Index of the line where the brace block opened at *start* closes."""
    depth = 0
    opened = False
    for i in range(start, len(lines)):
        for ch in lines[i]:
            if ch == "{":
                depth += 1
                opened = True
            elif ch == "}":
                depth -= 1
        if opened and depth <= 0:
            return i
    return None


def _find_decls(language: str, lines: List[str]) -> List[Tuple[int, str, str]]:
    decls: List[Tuple[int, str, str]] = []
    in_shell_func = False
    for i, line in enumerate(lines):
        if language == "c" and _CONTROL_GUARD.match(line):
            continue
        if language == "shell":
            # Fix D: inside a function body, swallow everything (assignments
            # like `tmp="$(mktemp -d)"` stay part of the function chunk) so
            # the function — not the throwaway variable — is the structural
            # unit a changed line maps to.
            if in_shell_func:
                if _SHELL_BLOCK_CLOSE.match(line):
                    in_shell_func = False
                continue
            m = _SHELL_FUNC_OPEN.match(line)
            if m:
                decls.append((i, m.group(1), "function"))
                in_shell_func = True
                continue
        for pattern, kind in _DECL_PATTERNS.get(language, []):
            match = re.match(pattern, line)
            if match:
                name = match.group(1) if match.lastindex else match.group(0).strip()
                if kind == "type" and match.lastindex and match.lastindex > 1:
                    # swift/c: the name is the second capture group.
                    name = match.group(match.lastindex)
                decls.append((i, name, kind))
                break
    return decls


class SourceParser(BaseParser):
    def __init__(self, language: str):
        self.language = language

    @property
    def name(self) -> str:
        return self.language

    def parse(self, text: str, path: Optional[str] = None) -> ParseResult:
        lines = text.splitlines()
        decls = _find_decls(self.language, lines)

        if not decls:
            if len(lines) <= 120:
                return ParseResult(
                    [ParsedChunk(1, len(lines), text, "document",
                                 structural_name=path, confidence=0.6)],
                    self.language, 0.6,
                )
            return ParseResult(window_chunks(lines), self.language, 0.5)

        chunks: List[ParsedChunk] = []
        for k, (line_idx, name, kind) in enumerate(decls):
            end = decls[k + 1][0] - 1 if k + 1 < len(decls) else len(lines) - 1
            if kind in ("function", "type") and self.language in _BRACED_LANGUAGES:
                braced = _braced_end(lines, line_idx)
                if braced is not None:
                    end = min(end, braced)
            chunks.append(ParsedChunk(
                line_idx + 1, end + 1, "\n".join(lines[line_idx:end + 1]),
                "symbol", structural_name=name, confidence=0.9,
            ))

        # Attach contiguous leading comment lines to the first declaration.
        first = decls[0][0]
        if first > 0:
            lead = lines[:first]
            if lead and any(l.strip().startswith(_COMMENT_PREFIXES) for l in lead):
                head = chunks[0]
                chunks[0] = ParsedChunk(
                    1, head.end_line,
                    "\n".join(lead) + "\n" + head.content,
                    head.kind, structural_name=head.structural_name,
                    heading=head.heading, confidence=head.confidence,
                )
        return ParseResult(chunks, self.language, 0.9)
