"""Incremental indexer.

Per file:
1. content hash
2. skip when unchanged
3. reparse changed files
4. delete chunks of removed files
5. update git metadata
6. commit only after success (a failed run leaves the index untouched)

Two runs over unchanged sources produce no changed records except the
explicit index_runs metadata row.
"""

from __future__ import annotations

import hashlib
from datetime import datetime, timezone
from typing import List, Optional

from ..config import RagshitConfig
from ..discovery.files import CandidateFile, discover_files
from ..discovery.ignore import IgnoreRules
from ..git.repository import GitRepository
from ..git.status import git_state
from ..models import Chunk, FileRecord, IndexStats
from ..parsing import get_parser
from .database import Database

_CHUNK_ID_SEP = "\x00"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def stable_chunk_id(repo_id: str, path: str, kind: str,
                    structural_name: Optional[str], content_hash: str) -> str:
    """Stable chunk identifier from source properties (not a UUID, not an
    absolute path)."""
    return sha256_bytes(
        (repo_id + _CHUNK_ID_SEP + path + _CHUNK_ID_SEP + kind + _CHUNK_ID_SEP
         + (structural_name or "") + _CHUNK_ID_SEP + content_hash).encode("utf-8")
    )


class Indexer:
    def __init__(self, db: Database, repo: GitRepository, config: RagshitConfig, rules: IgnoreRules):
        self.db = db
        self.repo = repo
        self.config = config
        self.rules = rules

    def _make_chunks(self, repo_id: str, candidate: CandidateFile, file_id: int,
                     head: Optional[str], run_id: int, text: str) -> List[Chunk]:
        result = get_parser(candidate.kind, candidate.language).parse(text, candidate.rel_path)
        chunks: List[Chunk] = []
        for pc in result.chunks:
            content_hash = sha256_bytes(pc.content.encode("utf-8"))
            chunks.append(Chunk(
                chunk_id=stable_chunk_id(
                    repo_id, candidate.rel_path, pc.kind,
                    pc.structural_name, content_hash,
                ),
                file_id=file_id,
                repo_id=repo_id,
                path=candidate.rel_path,
                start_line=pc.start_line,
                end_line=pc.end_line,
                content=pc.content,
                content_hash=content_hash,
                kind=pc.kind,
                structural_name=pc.structural_name,
                heading=pc.heading,
                language=candidate.language,
                commit=head,
                confidence=pc.confidence,
                index_run_id=run_id,
            ))
        return chunks

    def run(self) -> IndexStats:
        import time

        t0 = time.monotonic()
        stats = IndexStats()
        repo_id = self.repo.repo_id
        self.db.ensure_repository(repo_id, str(self.repo.root))

        candidates, skipped = discover_files(self.repo, self.config.index, self.rules)
        stats.files_scanned = len(candidates) + skipped
        stats.files_skipped = skipped

        self.db.begin()
        try:
            run_id = self.db.start_run(repo_id)
            state = git_state(self.repo)
            changed = state.changed_paths | state.staged_paths
            seen: set = set()

            for candidate in candidates:
                seen.add(candidate.rel_path)
                try:
                    raw = candidate.abs_path.read_bytes()
                except OSError:
                    continue
                digest = sha256_bytes(raw)
                existing = self.db.file_record(repo_id, candidate.rel_path)
                if existing is not None and existing.content_hash == digest:
                    stats.files_unchanged += 1
                    continue

                last_commit = (
                    self.repo.file_last_commit(candidate.rel_path)
                    if candidate.rel_path in changed else None
                )
                text = raw.decode("utf-8", errors="replace")
                record = FileRecord(
                    file_id=0,
                    repo_id=repo_id,
                    path=candidate.rel_path,
                    kind=candidate.kind,
                    language=candidate.language,
                    content_hash=digest,
                    byte_size=candidate.byte_size,
                    line_count=len(text.splitlines()),
                    tracked=candidate.rel_path in set(self.repo.tracked_files()),
                    indexed_at=datetime.now(timezone.utc).isoformat(timespec="seconds"),
                    last_commit=last_commit,
                )
                file_id = self.db.upsert_file(record)
                self.db.delete_chunks_for_file(file_id)
                chunks = self._make_chunks(repo_id, candidate, file_id, state.head, run_id, text)
                if chunks:
                    self.db.insert_chunks(chunks)
                stats.chunks_added += len(chunks)
                if existing is None:
                    stats.files_added += 1
                else:
                    stats.files_updated += 1

            for known in self.db.all_file_paths(repo_id):
                if known not in seen:
                    self.db.delete_file(repo_id, known)
                    stats.files_removed += 1

            self.db.set_git_refs(repo_id, self.repo.branch, self.repo.head, self.repo.detached)
            self.db.optimize_fts()
            self.db.commit()
            stats.elapsed_ms = int((time.monotonic() - t0) * 1000)
            # Run metadata is best-effort: the index is already committed.
            try:
                self.db.update_run(run_id, stats, "ok")
            except Exception:
                pass
        except Exception:
            self.db.rollback()
            raise
        return stats
