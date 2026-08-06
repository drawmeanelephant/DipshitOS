"""Git repository access — git is the authoritative source of repo state."""

from __future__ import annotations

import hashlib
import subprocess
from pathlib import Path
from typing import List, Optional

from ..errors import GitError, NotARepositoryError
from ..models import RecentCommit

GIT_TIMEOUT = 60


class GitRepository:
    """Thin wrapper around git commands run inside one repository root."""

    def __init__(self, root: Path):
        self.root = root.resolve()

    # ------------------------------------------------------------------ #
    # construction
    # ------------------------------------------------------------------ #
    @classmethod
    def from_path(cls, path: Path) -> "GitRepository":
        """Resolve *path* (a directory inside the repo) to the repo root."""
        p = path.expanduser()
        if not p.exists():
            raise NotARepositoryError(f"path does not exist: {p}")
        try:
            proc = subprocess.run(
                ["git", "-C", str(p), "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, timeout=GIT_TIMEOUT,
            )
        except FileNotFoundError as exc:
            raise GitError("git executable not found on PATH") from exc
        if proc.returncode != 0:
            raise NotARepositoryError(
                f"'{p}' is not inside a Git repository: {proc.stderr.strip()}"
            )
        return cls(Path(proc.stdout.strip()))

    # ------------------------------------------------------------------ #
    # low-level commands
    # ------------------------------------------------------------------ #
    def run(self, *args: str, check: bool = True) -> str:
        cmd = ["git", "-C", str(self.root)] + list(args)
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=GIT_TIMEOUT)
        except subprocess.TimeoutExpired as exc:
            raise GitError(f"git command timed out: {' '.join(cmd)}") from exc
        if check and proc.returncode != 0:
            raise GitError(
                f"git {' '.join(args)} failed ({proc.returncode}): "
                f"{(proc.stderr or proc.stdout).strip()}"
            )
        return proc.stdout

    def run_ok(self, *args: str) -> Optional[str]:
        """Run a command; return stdout on success, None on failure."""
        proc = subprocess.run(
            ["git", "-C", str(self.root)] + list(args),
            capture_output=True, text=True, timeout=GIT_TIMEOUT,
        )
        if proc.returncode != 0:
            return None
        return proc.stdout

    # ------------------------------------------------------------------ #
    # repository facts
    # ------------------------------------------------------------------ #
    @property
    def head(self) -> Optional[str]:
        out = self.run_ok("rev-parse", "HEAD")
        return out.strip() if out else None

    @property
    def branch(self) -> Optional[str]:
        """Current branch name, or None on a detached HEAD / unborn branch."""
        out = self.run_ok("symbolic-ref", "--short", "-q", "HEAD")
        return out.strip() if out else None

    @property
    def detached(self) -> bool:
        return self.branch is None and self.head is not None

    def origin_url(self) -> Optional[str]:
        out = self.run_ok("config", "--get", "remote.origin.url")
        return out.strip() if out else None

    @property
    def repo_id(self) -> str:
        """Stable repository identifier derived from origin URL, else the
        first commit hash, else the directory name. Never an absolute path."""
        url = self.origin_url()
        if url:
            source = "origin:" + url
        else:
            first = self.first_commit_hash()
            source = first if first else "dir:" + self.root.name
        return hashlib.sha256(source.encode("utf-8")).hexdigest()

    def first_commit_hash(self) -> Optional[str]:
        out = self.run_ok("rev-list", "--max-parents=0", "HEAD")
        if not out:
            return None
        lines = out.strip().splitlines()
        return lines[-1].strip() if lines else None

    # ------------------------------------------------------------------ #
    # file lists
    # ------------------------------------------------------------------ #
    def tracked_files(self) -> List[str]:
        out = self.run("ls-files")
        return [ln for ln in out.splitlines() if ln]

    def untracked_files(self) -> List[str]:
        out = self.run("ls-files", "--others", "--exclude-standard")
        return [ln for ln in out.splitlines() if ln]

    def status_v2(self) -> str:
        return self.run("status", "--porcelain=v2")

    # ------------------------------------------------------------------ #
    # history
    # ------------------------------------------------------------------ #
    def recent_commits(self, n: int) -> List[RecentCommit]:
        if n <= 0:
            return []
        out = self.run_ok("log", f"-n{n}", "--format=%H%x1f%h%x1f%s%x1f%an%x1f%aI")
        if not out:
            return []
        commits: List[RecentCommit] = []
        for line in out.splitlines():
            parts = line.split("\x1f")
            if len(parts) < 5:
                continue
            commits.append(RecentCommit(
                hash=parts[0], short=parts[1], subject=parts[2],
                author=parts[3], date=parts[4],
            ))
        return commits

    def recent_paths(self, n: int) -> List[str]:
        """Paths touched by the last *n* commits (used for recency boosts)."""
        if n <= 0:
            return []
        out = self.run_ok("log", f"-n{n}", "--name-only", "--pretty=format:")
        if not out:
            return []
        seen: List[str] = []
        for ln in out.splitlines():
            ln = ln.strip()
            if ln and ln not in seen:
                seen.append(ln)
        return seen

    def file_last_commit(self, path: str) -> Optional[str]:
        out = self.run_ok("log", "-1", "--format=%H", "--", path)
        return out.strip() if out else None
