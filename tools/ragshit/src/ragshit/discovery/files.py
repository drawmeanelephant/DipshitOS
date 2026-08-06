"""File discovery: which tracked/untracked files get indexed."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple

from ..config import IndexConfig
from ..git.repository import GitRepository
from .ignore import IgnoreRules

SUFFIX_KINDS = {
    ".zig": ("source", "zig"),
    ".swift": ("source", "swift"),
    ".py": ("source", "python"),
    ".sh": ("source", "shell"),
    ".bash": ("source", "shell"),
    ".zsh": ("source", "shell"),
    ".c": ("source", "c"),
    ".h": ("source", "c"),
    ".s": ("source", "assembly"),
    ".S": ("source", "assembly"),
    ".ld": ("source", "linker"),
    ".toml": ("source", "toml"),
    ".yaml": ("source", "yaml"),
    ".yml": ("source", "yaml"),
    ".json": ("source", "json"),
    ".md": ("markdown", "markdown"),
    ".markdown": ("markdown", "markdown"),
    ".txt": ("plaintext", "plaintext"),
    ".log": ("plaintext", "plaintext"),
}

SOURCE_LANGUAGES = {"zig", "swift", "python", "shell", "c", "assembly",
                    "linker", "toml", "yaml", "json"}


@dataclass
class CandidateFile:
    rel_path: str
    abs_path: Path
    kind: str
    language: str
    byte_size: int


def detect_kind(rel_path: str, first_line: str = "") -> Tuple[str, str]:
    suffix = Path(rel_path).suffix
    if suffix in SUFFIX_KINDS:
        kind, language = SUFFIX_KINDS[suffix]
    elif first_line.startswith("#!"):
        if "sh" in first_line or "bash" in first_line:
            kind, language = "source", "shell"
        else:
            kind, language = "plaintext", "plaintext"
    else:
        kind, language = "plaintext", "plaintext"
    return kind, language


def discover_files(
    repo: GitRepository,
    config: IndexConfig,
    rules: IgnoreRules,
) -> Tuple[List[CandidateFile], int]:
    """Return (candidates, skipped_count). Binary files, oversized files,
    and symlinks are skipped. Generated binary suffixes are additionally
    covered by the default .ragshitignore."""
    tracked = set(repo.tracked_files())
    candidates: List[Tuple[str, bool]] = [(p, True) for p in tracked]
    if config.include_untracked:
        for p in repo.untracked_files():
            if p not in tracked:
                candidates.append((p, False))

    result: List[CandidateFile] = []
    skipped = 0
    for rel, is_tracked in candidates:
        if rel.startswith(".git/") or rel == ".git":
            skipped += 1
            continue
        # .ragshitignore always wins.
        if rules.ragshitignored(rel):
            skipped += 1
            continue
        # .gitignore applies to untracked files; tracked files override it.
        if not is_tracked and rules.gitignored(rel):
            skipped += 1
            continue
        abs_path = repo.root / rel
        try:
            if abs_path.is_symlink() and not config.follow_symlinks:
                skipped += 1
                continue
            size = abs_path.stat().st_size
        except OSError:
            skipped += 1
            continue
        if size > config.max_file_bytes:
            skipped += 1
            continue
        # Empty files are still recorded (doctor's freshness check compares
        # the index against every tracked file); they simply produce no
        # chunks. Empty content is also not binary by definition.
        try:
            with open(abs_path, "rb") as fh:
                head = fh.read(8192)
        except OSError:
            skipped += 1
            continue
        if b"\x00" in head:
            skipped += 1
            continue
        first_line = head.decode("utf-8", "replace").splitlines()[0] if head else ""
        kind, language = detect_kind(rel, first_line)
        result.append(CandidateFile(
            rel_path=rel, abs_path=abs_path,
            kind=kind, language=language, byte_size=size,
        ))
    return result, skipped
