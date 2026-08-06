"""Doctor: verify a repository's Ragshit setup end to end.

Returns non-zero when any required check fails. Warnings (FTS5 absence)
degrade behavior but do not fail the check.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple

from .config import RagshitConfig, resolve_database_path
from .discovery.files import discover_files
from .discovery.ignore import IgnoreRules
from .errors import DatabaseError, GitError, NotARepositoryError, RagshitError
from .git.repository import GitRepository
from .git.status import git_state
from .indexing.database import Database


@dataclass
class Check:
    name: str
    ok: bool
    severity: str  # "required" | "warning"
    message: str


def _ok(name: str, message: str) -> Check:
    return Check(name, True, "required", message)


def _warn(name: str, message: str) -> Check:
    return Check(name, True, "warning", message)


def _fail(name: str, message: str) -> Check:
    return Check(name, False, "required", message)


def run_doctor(root: Path, config: RagshitConfig) -> Tuple[List[Check], bool]:
    checks: List[Check] = []

    # 1. Path is a git repository (also proves git is on PATH).
    try:
        repo = GitRepository.from_path(root)
    except (NotARepositoryError, GitError) as exc:
        checks.append(_fail("git repository", str(exc)))
        return checks, False
    checks.append(_ok("git repository", f"root: {repo.root}"))

    try:
        proc_version = repo.run_ok("--version")
    except Exception:
        proc_version = None
    checks.append(_ok("git available", proc_version.strip() if proc_version else "git responds"))

    # 2. Configuration parses.
    cfg_path = root / ".ragshit.toml"
    if cfg_path.exists():
        checks.append(_ok("configuration", f"{cfg_path} parses"))
    else:
        checks.append(_ok("configuration", "no .ragshit.toml (defaults in effect)"))

    # 3. Database readable.
    db_path = resolve_database_path(root, config)
    if not db_path.exists():
        checks.append(_fail("database", f"no index at {db_path}; run 'ragshit index' first"))
        return checks, False
    try:
        db = Database.open(root, config)
        integrity = db.integrity_check()
        if integrity and integrity == ["ok"]:
            checks.append(_ok("database", f"readable ({db.count_files(repo.repo_id)} files, "
                                           f"{db.count_chunks(repo.repo_id)} chunks)"))
        else:
            checks.append(_fail("database", f"integrity check failed: {integrity}"))
    except DatabaseError as exc:
        checks.append(_fail("database", str(exc)))
        return checks, False

    # 4. SQLite FTS5 support (warning: documented degraded mode).
    if db.fts_available:
        checks.append(_ok("sqlite FTS5", "available; lexical search uses BM25"))
    else:
        checks.append(_warn("sqlite FTS5", "unavailable; lexical search degrades to LIKE"))

    # 5. Ignored paths behave as expected. Discovery hard-excludes .git/
    # always; .ragshit/ must additionally be covered by an ignore rule so
    # the index can never become a candidate (e.g. via `git add -A`).
    rules = IgnoreRules(repo.root)
    if rules.is_ignored(".ragshit/index.sqlite3"):
        checks.append(_ok("ignore behavior", ".git/ and .ragshit/ paths are never eligible"))
    else:
        checks.append(_fail(
            "ignore behavior",
            ".ragshit/ is not covered by .gitignore or .ragshitignore — the index could become a candidate",
        ))

    # 6. Index matches current HEAD and working tree. The expected set is
    # the discovery candidate set — files discovery skips for a documented
    # reason (binary, oversized, symlink, ignore rule) must not fail the
    # check, while every indexable tracked file must be present.
    refs = db.get_git_refs(repo.repo_id)
    if refs is None:
        checks.append(_fail("index freshness", "no index run recorded for this repository"))
        db.close()
        return checks, False
    state = git_state(repo)
    head_ok = (refs["head"] == state.head)
    candidates, _ = discover_files(repo, config.index, rules)
    expected = {c.rel_path for c in candidates}
    missing_indexed = expected - set(db.all_file_paths(repo.repo_id))
    if head_ok and not missing_indexed:
        checks.append(_ok("index freshness", "HEAD and the discovery candidate set match the index"))
    else:
        problems = []
        if not head_ok:
            problems.append(f"indexed at {refs['head'] or '(unborn)'}, HEAD is now {state.head}")
        if missing_indexed:
            problems.append(f"{len(missing_indexed)} file(s) not indexed: {', '.join(sorted(missing_indexed)[:5])}")
        checks.append(_fail("index freshness", "; ".join(problems)))

    # 7. No missing referenced files (stale index rows).
    missing = []
    for rec in db.all_file_records(repo.repo_id):
        if not (repo.root / rec.path).exists():
            missing.append(rec.path)
    if missing:
        checks.append(_fail("referenced files", f"indexed but missing from disk: {', '.join(missing[:5])}"))
    else:
        checks.append(_ok("referenced files", "all indexed files exist on disk"))

    # 8. No duplicate chunk identifiers.
    dups = db.duplicate_chunk_ids()
    if dups:
        checks.append(_fail("chunk identifiers", f"duplicate chunk ids: {dups[:5]}"))
    else:
        checks.append(_ok("chunk identifiers", "no duplicate chunk ids"))

    # 9. No orphaned database records.
    orphans = db.orphaned_chunks()
    if orphans:
        checks.append(_fail("orphaned records", f"chunks without files: {orphans[:5]}"))
    else:
        checks.append(_ok("orphaned records", "no orphaned chunk records"))

    db.close()
    failed = [c for c in checks if not c.ok and c.severity == "required"]
    return checks, not failed
