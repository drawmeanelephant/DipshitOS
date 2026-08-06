"""Diff-range parsing and retrieval-oriented diff analysis."""

from __future__ import annotations

import re
from typing import Dict, List, Optional, Tuple

from ..errors import GitError, UsageError
from ..models import Chunk, DiffFile, DiffSummary, RecentCommit
from .repository import GitRepository

_NAME_STATUS = re.compile(r"^([ACDMRTUXB]\d{0,3})\t(.*)$")


def parse_range(repo: GitRepository, range_spec: str) -> Tuple[str, str]:
    """Split 'A..B' (or a single ref, treated as 'ref..HEAD')."""
    spec = range_spec.strip()
    if not spec:
        raise UsageError("empty diff range; expected something like main..HEAD")
    if ".." in spec:
        base, _, head = spec.partition("..")
        base, head = base.strip(), head.strip()
        if not base:
            raise UsageError(f"invalid diff range '{spec}': missing base before '..'")
        if not head:
            head = "HEAD"
    else:
        base, head = spec, "HEAD"
    if repo.run_ok("rev-parse", "--verify", "--quiet", f"{base}^{{commit}}") is None:
        raise GitError(f"cannot resolve base '{base}' to a commit")
    if repo.run_ok("rev-parse", "--verify", "--quiet", f"{head}^{{commit}}") is None:
        raise GitError(f"cannot resolve head '{head}' to a commit")
    return base, head


def diff_summary(repo: GitRepository, range_spec: str) -> DiffSummary:
    """Commits and per-file new-side line ranges for a git range."""
    base, head = parse_range(repo, range_spec)
    summary = DiffSummary(range_spec=range_spec, base=base, head=head)

    log_out = repo.run_ok("log", "--format=%H%x1f%h%x1f%s%x1f%an%x1f%aI", f"{base}..{head}")
    if log_out:
        for line in log_out.splitlines():
            parts = line.split("\x1f")
            if len(parts) >= 5:
                summary.commits.append(RecentCommit(
                    hash=parts[0], short=parts[1], subject=parts[2],
                    author=parts[3], date=parts[4],
                ))

    ns = repo.run("diff", "--name-status", "--unified=0", f"{base}..{head}")
    for line in ns.splitlines():
        if not line:
            continue
        match = _NAME_STATUS.match(line)
        if not match:
            continue
        status, rest = match.group(1), match.group(2)
        path = rest.split("\t")[-1]
        summary.files.append(DiffFile(path=path, status=status))

    # Per-file new-side line ranges from the unified=0 diff.
    patch = repo.run("diff", "--unified=0", f"{base}..{head}")
    current: Optional[DiffFile] = None
    for line in patch.splitlines():
        if line.startswith("diff --git a/"):
            target = line[len("diff --git a/"):].split(" b/", 1)[-1]
            current = next((f for f in summary.files if f.path == target), None)
            continue
        if current is None or not line.startswith("@@"):
            continue
        match = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
        if match:
            start = int(match.group(1))
            count = int(match.group(2) or "1")
            if count > 0:
                current.ranges.append((start, start + count - 1))
    return summary


# ---------------------------------------------------------------------- #
# Heuristic diff analysis (uses the index; relationships are labeled).
# ---------------------------------------------------------------------- #
def _chunks_overlapping(chunks: List[Chunk], ranges: List[Tuple[int, int]]) -> List[Chunk]:
    out = []
    for chunk in chunks:
        for start, end in ranges:
            if chunk.start_line <= end and chunk.end_line >= start:
                out.append(chunk)
                break
    return out


def analyze_diff(db, repo: GitRepository, summary: DiffSummary, limit: int = 10) -> Dict[str, object]:
    """Derive decision docs, affected symbols, nearby tests, and evidence
    artifacts from the diff, using the index. All relationships here are
    heuristic and are labeled as such by the caller."""
    repo_id = repo.repo_id
    changed_paths = [f.path for f in summary.files]
    top_dirs = {p.split("/")[0] for p in changed_paths if "/" in p}

    # 1. Relevant architecture documents (decision/ADR files).
    decisions = []
    decision_paths = db.paths_containing(repo_id, "decision")
    decision_paths |= db.paths_basename_like(repo_id, "ADR%")
    commit_text = " ".join(c.subject.lower() for c in summary.commits)
    mentions_decision = any(
        w in commit_text for w in ("adr", "decision", "milestone", "architecture")
    )
    for path in sorted(decision_paths):
        parts = path.split("/")
        related = path in changed_paths or (len(parts) > 1 and parts[0] in top_dirs)
        if related or mentions_decision:
            chunk = db.best_chunk_for_path(repo_id, path)
            if chunk:
                decisions.append({"path": path, "lines": (chunk.start_line, chunk.end_line)})
        if len(decisions) >= limit:
            break

    # 2. Likely affected symbols (declarations inside changed line ranges).
    symbols = []
    for f in summary.files:
        if not f.ranges:
            continue
        chunks = db.chunks_for_path(repo_id, f.path)
        for chunk in _chunks_overlapping(chunks, f.ranges):
            if chunk.structural_name:
                symbols.append({
                    "symbol": chunk.structural_name,
                    "path": f.path,
                    "lines": (chunk.start_line, chunk.end_line),
                })
    # 3. Nearby tests.
    tests = []
    for f in summary.files:
        stem = f.path.rsplit("/", 1)[-1]
        stem = re.sub(r"^test[_-]|_test$|\.test$", "", stem)
        candidates = db.paths_containing(repo_id, "test")
        for cand in sorted(candidates):
            cand_base = cand.rsplit("/", 1)[-1]
            if cand_base.startswith("test_") and (stem in cand_base or stem in cand):
                tests.append(cand)
            elif "/tests/" in cand and f.path.split("/")[0] == cand.split("/")[0]:
                tests.append(cand)
            if len(tests) >= limit:
                break
        if len(tests) >= limit:
            break

    # 4. Nearby evidence artifacts.
    evidence = []
    for f in summary.files:
        if "/artifacts/" in f.path or f.path.startswith("artifacts/"):
            evidence.append(f.path)
    return {
        "changed_paths": changed_paths,
        "decisions": decisions,
        "symbols": symbols,
        "tests": sorted(set(tests))[:limit],
        "evidence": sorted(set(evidence))[:limit],
    }
