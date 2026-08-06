"""Shared test fixtures.

All repositories created here are temporary and configure their own local
author identity so tests never depend on the developer's global git
config.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures" / "sample-repo"
sys.path.insert(0, str(ROOT / "src"))

import pytest  # noqa: E402


def git(repo: Path, *args: str, check: bool = True) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo)] + list(args),
        capture_output=True, text=True,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


def init_repo(repo: Path) -> None:
    repo.mkdir(parents=True, exist_ok=True)
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test User")


def write_file(repo: Path, rel: str, content: str) -> None:
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def commit_all(repo: Path, message: str = "commit") -> None:
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)


@pytest.fixture
def repo(tmp_path):
    """An empty git repository (unborn HEAD) with local author config."""
    r = tmp_path / "repo"
    init_repo(r)
    return r


@pytest.fixture
def sample_repo(tmp_path):
    """A git repository populated from tests/fixtures/sample-repo."""
    r = tmp_path / "repo"
    init_repo(r)
    for path in sorted(FIXTURES.rglob("*")):
        if path.is_file():
            write_file(r, path.relative_to(FIXTURES).as_posix(),
                       path.read_text(encoding="utf-8"))
    commit_all(r, "initial")
    return r


@pytest.fixture
def config():
    from ragshit.config import RagshitConfig
    return RagshitConfig()
