"""Working-tree status: changed files and per-file changed line ranges."""

from __future__ import annotations

import re
from typing import Dict, List, Optional, Set, Tuple

from ..models import GitState
from .repository import GitRepository

_HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def changed_line_ranges(repo: GitRepository, paths: List[str]) -> Dict[str, List[Tuple[int, int]]]:
    """New-side changed line ranges (1-based inclusive) for *paths*.

    Uses ``git diff --unified=0`` against HEAD when possible; for unborn
    HEAD repositories it combines the index and working-tree diffs.
    """
    if not paths:
        return {}
    if repo.head:
        out = repo.run("diff", "--unified=0", "HEAD", "--", *paths)
    else:
        out = repo.run("diff", "--unified=0", "--", *paths)
        out += "\n" + repo.run("diff", "--cached", "--unified=0", "--", *paths)

    ranges: Dict[str, List[Tuple[int, int]]] = {}
    current: Optional[str] = None
    for line in out.splitlines():
        if line.startswith("+++ b/"):
            current = line[len("+++ b/"):]
            ranges.setdefault(current, [])
            continue
        if current is None or not line.startswith("@@"):
            continue
        match = _HUNK.match(line)
        if match:
            start = int(match.group(1))
            count = int(match.group(2) or "1")
            if count > 0:
                ranges.setdefault(current, []).append((start, start + count - 1))
    return ranges


def git_state(repo: GitRepository, recent_commit_count: int = 10) -> GitState:
    """Snapshot current branch/HEAD, changed paths, ranges, and recency."""
    changed: Set[str] = set()
    staged: Set[str] = set()
    untracked: Set[str] = set()

    for line in repo.status_v2().splitlines():
        if line.startswith("1 "):
            parts = line.split(" ")
            if len(parts) < 9:
                continue
            xy, path = parts[1], parts[8]
            x, y = xy[0], xy[1]
            if x in "MARCDU" or y in "MARCDU":
                changed.add(path)
            if x in "MARCDU":
                staged.add(path)
        elif line.startswith("2 "):
            parts = line.split(" ")
            if len(parts) < 10:
                continue
            xy = parts[1]
            if xy[0] in "MARCDU" or xy[1] in "MARCDU":
                changed.add(parts[8])
                changed.add(parts[9])
                staged.add(parts[8])
        elif line.startswith("u "):
            changed.add(line[2:])
        elif line.startswith("? "):
            untracked.add(line[2:])

    ordered = sorted(changed)
    ranges = changed_line_ranges(repo, ordered) if ordered else {}
    recent_paths = set(repo.recent_paths(recent_commit_count))

    return GitState(
        repo_id=repo.repo_id,
        root=str(repo.root),
        branch=repo.branch,
        head=repo.head,
        detached=repo.detached,
        changed_paths=changed,
        staged_paths=staged,
        untracked_paths=untracked,
        changed_ranges=ranges,
        recent_paths=recent_paths,
    )
