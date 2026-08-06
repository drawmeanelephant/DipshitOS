"""Gitignore-style ignore rules for discovery.

Two pattern sources exist:
* ``.gitignore`` — git's own rules, honored for untracked files.
* ``.ragshitignore`` — Ragshit's rules; these override everything,
  including tracked-file eligibility.

Tracked files normally remain eligible even when a broad ``.gitignore``
rule would match; only ``.ragshitignore`` can exclude a tracked file.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import List, Optional

from ..config import IGNORE_FILENAME


class _Rule:
    __slots__ = ("regex", "negated", "anchored", "dir_only")

    def __init__(self, regex: re.Pattern, negated: bool, anchored: bool, dir_only: bool):
        self.regex = regex
        self.negated = negated
        self.anchored = anchored
        self.dir_only = dir_only


def _translate(pattern: str) -> str:
    """gitignore glob -> regex. '*' does not cross '/'; '**' crosses it."""
    out: List[str] = []
    i = 0
    n = len(pattern)
    while i < n:
        c = pattern[i]
        if c == "*":
            if i + 1 < n and pattern[i + 1] == "*":
                if i + 2 < n and pattern[i + 2] == "/":
                    out.append("(?:.*/)?")
                    i += 3
                    continue
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            j = pattern.find("]", i + 1)
            if j == -1:
                out.append(re.escape(c))
            else:
                out.append("[" + pattern[i + 1:j] + "]")
                i = j
        else:
            out.append(re.escape(c))
        i += 1
    return "".join(out)


def _compile(pattern: str) -> Optional[_Rule]:
    p = pattern.strip()
    if not p or p.startswith("#"):
        return None
    negated = p.startswith("!")
    if negated:
        p = p[1:]
    dir_only = p.endswith("/")
    if dir_only:
        p = p.rstrip("/")
    anchored = p.startswith("/")
    if anchored:
        p = p[1:]
    if not p:
        return None
    return _Rule(re.compile("^" + _translate(p) + "$"), negated, anchored, dir_only)


def _read_rules(path: Path) -> List[_Rule]:
    rules: List[_Rule] = []
    if not path.exists():
        return rules
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return rules
    for line in text.splitlines():
        rule = _compile(line)
        if rule is not None:
            rules.append(rule)
    return rules


def _matches(rules: List[_Rule], rel_path: str) -> bool:
    parts = rel_path.split("/")
    ignored = False
    for rule in rules:
        hit = False
        if rule.anchored:
            if rule.dir_only:
                hit = any(rule.regex.match("/".join(parts[:k])) for k in range(1, len(parts) + 1))
            else:
                hit = bool(rule.regex.match(rel_path))
        else:
            if rule.dir_only:
                hit = any(rule.regex.match("/".join(parts[:k])) for k in range(1, len(parts) + 1))
            else:
                hit = bool(rule.regex.match(rel_path)) or any(
                    rule.regex.match(part) for part in parts
                )
        if hit:
            ignored = not rule.negated
    return ignored


class IgnoreRules:
    """Combined .gitignore + .ragshitignore matcher."""

    def __init__(self, root: Path):
        self.root = root
        self.git_rules = _read_rules(root / ".gitignore")
        self.rag_rules = _read_rules(root / IGNORE_FILENAME)

    def gitignored(self, rel_path: str) -> bool:
        return _matches(self.git_rules, rel_path)

    def ragshitignored(self, rel_path: str) -> bool:
        return _matches(self.rag_rules, rel_path)

    def is_ignored(self, rel_path: str) -> bool:
        return self.ragshitignored(rel_path) or self.gitignored(rel_path)
