"""Data models shared across Ragshit.

All line numbers are 1-based and inclusive. Paths are repository-relative
POSIX-style strings; absolute local paths are never used as identifiers.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple


@dataclass
class FileRecord:
    """An indexed file record."""

    file_id: int
    repo_id: str
    path: str
    kind: str  # markdown | source | plaintext
    language: str  # zig | swift | python | shell | c | assembly | linker | toml | yaml | json | markdown | plaintext
    content_hash: str
    byte_size: int
    line_count: int
    tracked: bool
    indexed_at: str
    last_commit: Optional[str] = None


@dataclass
class Chunk:
    """An indexed, source-addressable chunk."""

    chunk_id: str
    file_id: int
    repo_id: str
    path: str
    start_line: int
    end_line: int
    content: str
    content_hash: str
    kind: str  # section | symbol | document | window | comment | key
    structural_name: Optional[str] = None
    heading: Optional[str] = None
    language: str = ""
    commit: Optional[str] = None
    confidence: float = 0.0
    index_run_id: int = 0


@dataclass
class RecentCommit:
    """A commit summary for display."""

    hash: str
    short: str
    subject: str
    author: str
    date: str


@dataclass
class GitState:
    """Snapshot of repository state relevant to retrieval."""

    repo_id: str
    root: str
    branch: Optional[str]
    head: Optional[str]
    detached: bool
    changed_paths: Set[str] = field(default_factory=set)
    staged_paths: Set[str] = field(default_factory=set)
    untracked_paths: Set[str] = field(default_factory=set)
    changed_ranges: Dict[str, List[Tuple[int, int]]] = field(default_factory=dict)
    recent_paths: Set[str] = field(default_factory=set)

    @property
    def dirty_count(self) -> int:
        return len(self.changed_paths | self.staged_paths | self.untracked_paths)


@dataclass
class DiffFile:
    """A file changed in a diff range, with new-side line ranges."""

    path: str
    status: str  # A | M | D | Rxxx | Cxxx
    ranges: List[Tuple[int, int]] = field(default_factory=list)


@dataclass
class DiffSummary:
    """Parsed git diff range."""

    range_spec: str
    base: Optional[str]
    head: Optional[str]
    commits: List[RecentCommit] = field(default_factory=list)
    files: List[DiffFile] = field(default_factory=list)

    @property
    def empty(self) -> bool:
        return not self.commits and not self.files


@dataclass
class IndexStats:
    """Counters reported by an indexing run."""

    files_scanned: int = 0
    files_added: int = 0
    files_updated: int = 0
    files_unchanged: int = 0
    files_removed: int = 0
    files_skipped: int = 0
    chunks_added: int = 0
    elapsed_ms: int = 0


@dataclass
class RetrievedChunk:
    """A chunk with its final score and per-signal explanation."""

    chunk: Chunk
    score: float
    components: Dict[str, float] = field(default_factory=dict)

    @property
    def path(self) -> str:
        return self.chunk.path

    @property
    def start_line(self) -> int:
        return self.chunk.start_line

    @property
    def end_line(self) -> int:
        return self.chunk.end_line


@dataclass
class QuerySpec:
    """Parsed retrieval query."""

    terms: List[str] = field(default_factory=list)
    phrases: List[str] = field(default_factory=list)
    path_filters: List[str] = field(default_factory=list)
    kind_filters: List[str] = field(default_factory=list)
    symbol_filters: List[str] = field(default_factory=list)
    changed: Optional[bool] = None

    @property
    def empty(self) -> bool:
        return not (self.terms or self.phrases or self.path_filters
                    or self.kind_filters or self.symbol_filters)
