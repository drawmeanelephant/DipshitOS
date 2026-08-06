"""Context bundle assembly.

A bundle is a self-contained context package for an LLM or reviewer:
request, repository state, retrieval summary, current diff, retrieved
sources with full provenance, and a scan of unresolved-evidence markers.

Budget handling (in order): preserve exact/path/symbol matches, preserve
chunks overlapping the current diff, preserve architecture decisions,
drop low-ranked overlapping duplicates, truncate only as a final resort,
and always report what was omitted. Output carries no timestamps or host
stamps, so two runs over unchanged sources are byte-identical.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from ..config import RagshitConfig
from ..git.repository import GitRepository
from ..git.status import git_state
from ..indexing.database import Database
from ..models import DiffSummary, GitState, RetrievedChunk
from ..retrieval.query import run_query
from .markdown import render_source_block

_UNRESOLVED_MARKERS = re.compile(
    r"(\[inferred\]|unverified|not yet determined|unresolved|root cause|"
    r"known issue|\bTODO\b|\bFIXME\b|no commits)",
    re.IGNORECASE,
)

_EXACT_NAMES = ("path exact", "symbol exact", "heading exact", "phrase match")


@dataclass
class Bundle:
    request: str
    repo_state: Dict[str, object]
    retrieval_summary: Dict[str, object]
    diff_section: Dict[str, object]
    sources: List[RetrievedChunk] = field(default_factory=list)
    omissions: List[str] = field(default_factory=list)
    evidence_notes: List[str] = field(default_factory=list)
    total_characters: int = 0


def _diff_overlaps(result: RetrievedChunk, git: GitState) -> bool:
    for start, end in git.changed_ranges.get(result.chunk.path, []):
        if result.chunk.start_line <= end and result.chunk.end_line >= start:
            return True
    return False


def _tier(result: RetrievedChunk, git: GitState) -> int:
    if any(n in result.components for n in _EXACT_NAMES) or _diff_overlaps(result, git):
        return 0
    if "decision document" in result.components:
        return 1
    return 2


def scan_unresolved_evidence(sources: List[RetrievedChunk]) -> List[str]:
    """Find unresolved-evidence markers inside retrieved source content."""
    notes: List[str] = []
    seen = set()
    for result in sources:
        c = result.chunk
        for line_no, line in enumerate(c.content.splitlines(), c.start_line):
            match = _UNRESOLVED_MARKERS.search(line)
            if not match:
                continue
            key = (c.path, match.group(1).lower())
            if key in seen:
                continue
            seen.add(key)
            snippet = line.strip()[:160]
            notes.append(f"- {c.path}:{line_no} [{match.group(1)}] {snippet}")
    return notes


def build_bundle(
    db: Database,
    repo: GitRepository,
    config: RagshitConfig,
    query_text: str,
    limit: int,
    diff: Optional[DiffSummary] = None,
    git: Optional[GitState] = None,
) -> Bundle:
    if git is None:
        git = git_state(repo)

    # Pull extra candidates so the budget can make real choices.
    results, _ = run_query(db, repo, config.retrieval, query_text, max(limit * 3, 60), git)

    repo_state: Dict[str, object] = {}
    if config.bundle.include_git_status:
        repo_state = {
            "root": str(repo.root),
            "branch": repo.branch,
            "head": repo.head,
            "detached": repo.detached,
            "dirty_files": git.dirty_count,
            "indexed_files": db.count_files(repo.repo_id),
            "indexed_chunks": db.count_chunks(repo.repo_id),
            "fts5": db.fts_available,
        }
    if config.bundle.include_recent_commits:
        repo_state["recent_commits"] = [
            {"hash": c.short, "subject": c.subject}
            for c in repo.recent_commits(config.bundle.recent_commit_count)
        ]

    diff_section: Dict[str, object] = {}
    if diff is not None:
        diff_section = {
            "range": diff.range_spec,
            "commits": [{"short": c.short, "subject": c.subject} for c in diff.commits],
            "files": [
                {"path": f.path, "status": f.status, "ranges": f.ranges}
                for f in diff.files
            ],
        }
    elif config.bundle.include_diff and git.dirty_count:
        diff_section = {
            "working_tree": {
                "changed": sorted(git.changed_paths | git.staged_paths),
                "untracked": sorted(git.untracked_paths),
                "ranges": {k: v for k, v in sorted(git.changed_ranges.items())},
            }
        }

    # Budget assembly.
    budget = config.bundle.maximum_characters
    ordered = sorted(results, key=lambda r: (-r.score, r.chunk.path, r.chunk.start_line, r.chunk.chunk_id))
    tiers = sorted(ordered, key=lambda r: _tier(r, git))
    selected: List[RetrievedChunk] = []
    omissions: List[str] = []
    used = 0

    for result in tiers:
        block_len = len(render_source_block(result, explain=True))
        if used + block_len <= budget:
            selected.append(result)
            used += block_len
        else:
            omissions.append(
                f"omitted '{result.chunk.path}:{result.chunk.start_line}-{result.chunk.end_line}' "
                f"(score {result.score:.2f}) to fit the {budget}-character budget"
            )

    if not selected and ordered:
        # Final resort: include the top result, truncated, and report it.
        # Copy the chunk so the shared index record is never mutated.
        import copy
        top = ordered[0]
        truncated = copy.copy(top.chunk)
        content = top.chunk.content
        if len(content) > budget:
            truncated.content = content[: budget] + "\n[truncated]"
            truncated.end_line = truncated.start_line
            omissions.append(f"truncated '{top.chunk.path}' content to fit the budget")
        selected = [RetrievedChunk(truncated, top.score, dict(top.components))]
        used = len(truncated.content)

    evidence = scan_unresolved_evidence(selected)
    if not evidence:
        evidence = ["No unresolved-evidence markers ([inferred], unresolved, known issue, TODO, ...) found in retrieved sources."]

    summary = {
        "query": query_text,
        "requested_limit": limit,
        "included": len(selected),
        "omitted": len(omissions),
        "total_characters": used,
        "top_scores": [round(r.score, 2) for r in selected[:5]],
    }
    return Bundle(
        request=query_text,
        repo_state=repo_state,
        retrieval_summary=summary,
        diff_section=diff_section,
        sources=selected,
        omissions=omissions,
        evidence_notes=evidence,
        total_characters=used,
    )


def render_bundle_markdown(bundle: Bundle) -> str:
    out = ["# Ragshit context bundle", ""]
    out += ["## Request", "", bundle.request, ""]
    out += ["## Repository state", ""]
    if bundle.repo_state:
        for key, value in bundle.repo_state.items():
            if isinstance(value, list):
                out.append(f"- {key}:")
                for item in value[:10]:
                    if isinstance(item, dict):
                        out.append(f"  - {item.get('short', item.get('hash', item))}: {item.get('subject', '')}")
                    else:
                        out.append(f"  - {item}")
            else:
                out.append(f"- {key}: {value}")
    else:
        out.append("- (git status omitted by configuration)")
    out.append("")
    out += ["## Retrieval summary", ""]
    for key, value in bundle.retrieval_summary.items():
        out.append(f"- {key}: {value}")
    out.append("")
    out += ["## Current diff", ""]
    if bundle.diff_section:
        if "range" in bundle.diff_section:
            out.append(f"- range: {bundle.diff_section['range']}")
            out.append(f"- commits: {len(bundle.diff_section['commits'])}")
            for f in bundle.diff_section["files"]:
                ranges = ", ".join(f"{a}-{b}" for a, b in f["ranges"]) or "all"
                out.append(f"- {f['status']} {f['path']} (lines {ranges})")
        elif "working_tree" in bundle.diff_section:
            wt = bundle.diff_section["working_tree"]
            out.append(f"- working-tree changes: {len(wt['changed'])} file(s)")
            for path in wt["changed"]:
                ranges = wt["ranges"].get(path)
                suffix = f" (lines {', '.join(f'{a}-{b}' for a, b in ranges)})" if ranges else ""
                out.append(f"  - {path}{suffix}")
            if wt["untracked"]:
                out.append(f"- untracked: {', '.join(wt['untracked'])}")
    else:
        out.append("- (no diff in range, working tree clean)")
    out.append("")
    out += ["## Retrieved sources", ""]
    out.append("\n\n".join(render_source_block(r, explain=True) for r in bundle.sources))
    out.append("")
    if bundle.omissions:
        out += ["### Omitted", ""]
        out += bundle.omissions
        out.append("")
    out += ["## Missing or unresolved evidence", ""]
    out += bundle.evidence_notes
    out.append("")
    return "\n".join(out)
