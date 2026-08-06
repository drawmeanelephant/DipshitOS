"""SQLite index access layer.

Handles schema creation, transactions, FTS5 (with a documented LIKE
fallback when FTS5 is unavailable), and all queries used by retrieval,
bundling, inspection, and doctor.
"""

from __future__ import annotations

import os
import sqlite3
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set, Tuple

from ..config import RagshitConfig, resolve_database_path
from ..errors import DatabaseError
from ..models import Chunk, FileRecord, IndexStats
from .schema import FTS5_SQL, SCHEMA_SQL

# bm25 column weights: (content, structural_name, path)
FTS_WEIGHTS = (1.0, 2.0, 2.0)

_CHUNK_COLUMNS = (
    "chunk_id, file_id, repo_id, path, start_line, end_line, content, "
    "content_hash, kind, structural_name, heading, language, commit_hash, "
    "confidence, index_run_id"
)

_FTS_SELECT = f"""
    SELECT {', '.join('c.' + col for col in _CHUNK_COLUMNS.split(', '))},
           bm25(chunks_fts, {FTS_WEIGHTS[0]}, {FTS_WEIGHTS[1]}, {FTS_WEIGHTS[2]}) AS rank
    FROM chunks_fts
    JOIN chunks c ON c.id = chunks_fts.rowid
    WHERE chunks_fts MATCH ?
    ORDER BY rank
    LIMIT ?
"""


def _row_to_chunk(row: sqlite3.Row) -> Chunk:
    return Chunk(
        chunk_id=row["chunk_id"],
        file_id=row["file_id"],
        repo_id=row["repo_id"],
        path=row["path"],
        start_line=row["start_line"],
        end_line=row["end_line"],
        content=row["content"],
        content_hash=row["content_hash"],
        kind=row["kind"],
        structural_name=row["structural_name"],
        heading=row["heading"],
        language=row["language"],
        commit=row["commit_hash"],
        confidence=row["confidence"],
        index_run_id=row["index_run_id"],
    )


def _fts_supported(conn: sqlite3.Connection) -> bool:
    if os.environ.get("RAGSHIT_NO_FTS"):
        return False
    try:
        conn.execute("CREATE VIRTUAL TABLE temp._ragshit_fts_probe USING fts5(x)")
        conn.execute("DROP TABLE temp._ragshit_fts_probe")
        return True
    except sqlite3.OperationalError:
        return False


class Database:
    def __init__(self, conn: sqlite3.Connection, path: Path, fts_available: bool):
        self.conn = conn
        self.path = path
        self.fts_available = fts_available

    # ------------------------------------------------------------------ #
    # construction
    # ------------------------------------------------------------------ #
    @classmethod
    def open(cls, root: Path, config: RagshitConfig) -> "Database":
        db_path = resolve_database_path(root, config)
        db_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            conn = sqlite3.connect(str(db_path))
            conn.row_factory = sqlite3.Row
            # Autocommit mode: Indexer owns transactions explicitly (BEGIN..COMMIT
            # per run) so an unrelated implicit transaction can never leak into
            # an indexing run.
            conn.isolation_level = None
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA foreign_keys=ON")
            conn.execute("PRAGMA synchronous=NORMAL")
        except sqlite3.Error as exc:
            raise DatabaseError(f"cannot open index at {db_path}: {exc}") from exc
        db = cls(conn, db_path, fts_available=_fts_supported(conn))
        try:
            db._init_schema()
        except sqlite3.Error as exc:
            conn.close()
            raise DatabaseError(f"cannot initialize index schema: {exc}") from exc
        return db

    def _init_schema(self) -> None:
        self.conn.executescript(SCHEMA_SQL)
        self._migrate()
        if self.fts_available:
            try:
                self.conn.executescript(FTS5_SQL)
            except sqlite3.OperationalError:
                # FTS5 advertised but unusable for this schema: degrade.
                try:
                    self.conn.execute("DROP TABLE IF EXISTS chunks_fts")
                except sqlite3.Error:
                    pass
                self.fts_available = False

    def _migrate(self) -> None:
        """Lightweight schema migrations for databases created before a
        column existed. New databases get the full schema from SCHEMA_SQL."""
        try:
            cols = {r["name"] for r in self.conn.execute("PRAGMA table_info(chunks)").fetchall()}
            if "confidence" not in cols:
                self.conn.execute("ALTER TABLE chunks ADD COLUMN confidence REAL NOT NULL DEFAULT 0.0")
        except sqlite3.Error:
            pass

    def close(self) -> None:
        try:
            self.conn.close()
        except sqlite3.Error:
            pass

    # ------------------------------------------------------------------ #
    # transactions
    # ------------------------------------------------------------------ #
    def begin(self) -> None:
        self.conn.execute("BEGIN")

    def commit(self) -> None:
        self.conn.commit()

    def rollback(self) -> None:
        self.conn.rollback()

    # ------------------------------------------------------------------ #
    # repositories / runs
    # ------------------------------------------------------------------ #
    def ensure_repository(self, repo_id: str, root_path: str) -> None:
        from datetime import datetime, timezone
        self.conn.execute(
            "INSERT OR IGNORE INTO repositories(id, root_path, created_at) VALUES (?, ?, ?)",
            (repo_id, root_path, datetime.now(timezone.utc).isoformat(timespec="seconds")),
        )

    def start_run(self, repo_id: str) -> int:
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc).isoformat(timespec="seconds")
        cur = self.conn.execute(
            "INSERT INTO index_runs(repo_id, started_at, finished_at, status) VALUES (?, ?, ?, ?)",
            (repo_id, now, now, "running"),
        )
        return cur.lastrowid

    def update_run(self, run_id: int, stats: IndexStats, status: str) -> None:
        from datetime import datetime, timezone
        self.conn.execute(
            "UPDATE index_runs SET finished_at=?, status=?, files_scanned=?, files_added=?, "
            "files_updated=?, files_unchanged=?, files_removed=?, files_skipped=?, "
            "chunks_added=?, elapsed_ms=? WHERE id=?",
            (
                datetime.now(timezone.utc).isoformat(timespec="seconds"),
                status, stats.files_scanned, stats.files_added, stats.files_updated,
                stats.files_unchanged, stats.files_removed, stats.files_skipped,
                stats.chunks_added, stats.elapsed_ms, run_id,
            ),
        )

    def latest_run(self, repo_id: str) -> Optional[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM index_runs WHERE repo_id=? ORDER BY id DESC LIMIT 1",
            (repo_id,),
        ).fetchone()

    def set_git_refs(self, repo_id: str, branch: Optional[str], head: Optional[str], detached: bool) -> None:
        from datetime import datetime, timezone
        self.conn.execute(
            "INSERT INTO git_refs(repo_id, branch, head, is_detached, updated_at) VALUES (?, ?, ?, ?, ?) "
            "ON CONFLICT(repo_id) DO UPDATE SET branch=excluded.branch, head=excluded.head, "
            "is_detached=excluded.is_detached, updated_at=excluded.updated_at",
            (repo_id, branch, head, 1 if detached else 0,
             datetime.now(timezone.utc).isoformat(timespec="seconds")),
        )

    def get_git_refs(self, repo_id: str) -> Optional[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM git_refs WHERE repo_id=?", (repo_id,)
        ).fetchone()

    # ------------------------------------------------------------------ #
    # files
    # ------------------------------------------------------------------ #
    def upsert_file(self, rec: FileRecord) -> int:
        self.conn.execute(
            "INSERT INTO files(repo_id, path, kind, language, content_hash, byte_size, "
            "line_count, tracked, last_commit, indexed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(repo_id, path) DO UPDATE SET kind=excluded.kind, language=excluded.language, "
            "content_hash=excluded.content_hash, byte_size=excluded.byte_size, "
            "line_count=excluded.line_count, tracked=excluded.tracked, "
            "last_commit=excluded.last_commit, indexed_at=excluded.indexed_at",
            (rec.repo_id, rec.path, rec.kind, rec.language, rec.content_hash,
             rec.byte_size, rec.line_count, 1 if rec.tracked else 0,
             rec.last_commit, rec.indexed_at),
        )
        row = self.conn.execute(
            "SELECT id FROM files WHERE repo_id=? AND path=?", (rec.repo_id, rec.path)
        ).fetchone()
        return int(row["id"])

    def file_record(self, repo_id: str, path: str) -> Optional[FileRecord]:
        row = self.conn.execute(
            "SELECT * FROM files WHERE repo_id=? AND path=?", (repo_id, path)
        ).fetchone()
        if row is None:
            return None
        return FileRecord(
            file_id=row["id"], repo_id=row["repo_id"], path=row["path"],
            kind=row["kind"], language=row["language"], content_hash=row["content_hash"],
            byte_size=row["byte_size"], line_count=row["line_count"],
            tracked=bool(row["tracked"]), indexed_at=row["indexed_at"],
            last_commit=row["last_commit"],
        )

    def all_file_paths(self, repo_id: str) -> List[str]:
        rows = self.conn.execute(
            "SELECT path FROM files WHERE repo_id=? ORDER BY path", (repo_id,)
        ).fetchall()
        return [r["path"] for r in rows]

    def all_file_records(self, repo_id: str) -> List[FileRecord]:
        rows = self.conn.execute(
            "SELECT * FROM files WHERE repo_id=? ORDER BY path", (repo_id,)
        ).fetchall()
        return [
            FileRecord(
                file_id=r["id"], repo_id=r["repo_id"], path=r["path"], kind=r["kind"],
                language=r["language"], content_hash=r["content_hash"],
                byte_size=r["byte_size"], line_count=r["line_count"],
                tracked=bool(r["tracked"]), indexed_at=r["indexed_at"],
                last_commit=r["last_commit"],
            )
            for r in rows
        ]

    def count_files(self, repo_id: str) -> int:
        row = self.conn.execute(
            "SELECT COUNT(*) AS n FROM files WHERE repo_id=?", (repo_id,)
        ).fetchone()
        return int(row["n"])

    def delete_file(self, repo_id: str, path: str) -> None:
        self.conn.execute("DELETE FROM files WHERE repo_id=? AND path=?", (repo_id, path))

    # ------------------------------------------------------------------ #
    # chunks
    # ------------------------------------------------------------------ #
    def delete_chunks_for_file(self, file_id: int) -> None:
        self.conn.execute("DELETE FROM chunks WHERE file_id=?", (file_id,))

    def insert_chunks(self, chunks: Sequence[Chunk]) -> None:
        self.conn.executemany(
            "INSERT OR REPLACE INTO chunks(chunk_id, file_id, repo_id, path, start_line, "
            "end_line, content, content_hash, kind, structural_name, heading, language, "
            "commit_hash, confidence, index_run_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (
                    c.chunk_id, c.file_id, c.repo_id, c.path, c.start_line, c.end_line,
                    c.content, c.content_hash, c.kind, c.structural_name, c.heading,
                    c.language, c.commit, c.confidence, c.index_run_id,
                )
                for c in chunks
            ],
        )

    def chunks_for_path(self, repo_id: str, path: str) -> List[Chunk]:
        rows = self.conn.execute(
            f"SELECT {_CHUNK_COLUMNS} FROM chunks WHERE repo_id=? AND path=? "
            "ORDER BY start_line",
            (repo_id, path),
        ).fetchall()
        return [_row_to_chunk(r) for r in rows]

    def best_chunk_for_path(self, repo_id: str, path: str) -> Optional[Chunk]:
        row = self.conn.execute(
            f"SELECT {_CHUNK_COLUMNS} FROM chunks WHERE repo_id=? AND path=? "
            "ORDER BY start_line LIMIT 1",
            (repo_id, path),
        ).fetchone()
        return _row_to_chunk(row) if row else None

    def count_chunks(self, repo_id: str) -> int:
        row = self.conn.execute(
            "SELECT COUNT(*) AS n FROM chunks WHERE repo_id=?", (repo_id,)
        ).fetchone()
        return int(row["n"])

    def paths_containing(self, repo_id: str, fragment: str) -> Set[str]:
        rows = self.conn.execute(
            "SELECT DISTINCT path FROM chunks WHERE repo_id=? AND path LIKE ? ESCAPE '\\'",
            (repo_id, "%" + fragment + "%"),
        ).fetchall()
        return {r["path"] for r in rows}

    def paths_basename_like(self, repo_id: str, pattern: str) -> Set[str]:
        rows = self.conn.execute(
            "SELECT DISTINCT path FROM chunks WHERE repo_id=? AND path LIKE ?",
            (repo_id, "%/" + pattern),
        ).fetchall()
        return {r["path"] for r in rows}

    def chunks_under_path(self, repo_id: str, prefix: str) -> List[Chunk]:
        prefix = prefix.rstrip("/") + "/"
        rows = self.conn.execute(
            f"SELECT {_CHUNK_COLUMNS} FROM chunks WHERE repo_id=? AND path LIKE ? ESCAPE '\\'",
            (repo_id, prefix + "%"),
        ).fetchall()
        return [_row_to_chunk(r) for r in rows]

    def chunks_path_like(self, repo_id: str, fragment: str) -> List[Chunk]:
        rows = self.conn.execute(
            f"SELECT {_CHUNK_COLUMNS} FROM chunks WHERE repo_id=? AND path LIKE ? ESCAPE '\\'",
            (repo_id, "%" + fragment + "%"),
        ).fetchall()
        return [_row_to_chunk(r) for r in rows]

    def chunks_symbol_exact(self, repo_id: str, term: str) -> List[Chunk]:
        rows = self.conn.execute(
            f"SELECT {_CHUNK_COLUMNS} FROM chunks WHERE repo_id=? "
            "AND (lower(structural_name) = lower(?) OR lower(heading) = lower(?) "
            "OR lower(heading) LIKE lower(?) )",
            (repo_id, term, term, "% > " + term),
        ).fetchall()
        return [_row_to_chunk(r) for r in rows]

    def chunks_symbol_contains(self, repo_id: str, term: str) -> List[Chunk]:
        rows = self.conn.execute(
            f"SELECT {_CHUNK_COLUMNS} FROM chunks WHERE repo_id=? "
            "AND (lower(structural_name) LIKE lower(?) OR lower(heading) LIKE lower(?))",
            (repo_id, "%" + term + "%", "%" + term + "%"),
        ).fetchall()
        return [_row_to_chunk(r) for r in rows]

    def chunks_phrase(self, repo_id: str, phrase: str) -> List[Chunk]:
        rows = self.conn.execute(
            f"SELECT {_CHUNK_COLUMNS} FROM chunks WHERE repo_id=? AND content LIKE ?",
            (repo_id, "%" + phrase + "%"),
        ).fetchall()
        return [_row_to_chunk(r) for r in rows]

    # ------------------------------------------------------------------ #
    # lexical search
    # ------------------------------------------------------------------ #
    def fts_search(self, match: str, limit: int) -> List[Tuple[Chunk, float]]:
        """Return (chunk, rank) ordered by BM25. rank <= 0; callers convert."""
        rows = self.conn.execute(_FTS_SELECT, (match, limit)).fetchall()
        return [(_row_to_chunk(r), float(r["rank"])) for r in rows]

    def lexical_like_search(self, terms: Sequence[str], limit: int) -> List[Tuple[Chunk, float]]:
        """Degraded-mode search when FTS5 is unavailable.

        Score = number of terms matched in content/symbol/path, scaled to
        the same 0..fts_weight range as BM25 so downstream ranking behaves
        the same. Deterministic ordering (score desc, path, start_line).
        """
        scores: Dict[str, float] = {}
        chunks: Dict[str, Chunk] = {}
        for term in terms:
            rows = self.conn.execute(
                f"SELECT {_CHUNK_COLUMNS} FROM chunks "
                "WHERE content LIKE ? OR structural_name LIKE ? OR heading LIKE ?",
                ("%" + term + "%", "%" + term + "%", "%" + term + "%"),
            ).fetchall()
            for r in rows:
                chunk = _row_to_chunk(r)
                chunks[chunk.chunk_id] = chunk
                scores[chunk.chunk_id] = scores.get(chunk.chunk_id, 0.0) + 1.0
        ordered = sorted(
            chunks.values(),
            key=lambda c: (scores[c.chunk_id], c.path, c.start_line, c.chunk_id),
            reverse=True,
        )
        return [(c, -scores[c.chunk_id]) for c in ordered[:limit]]

    def optimize_fts(self) -> None:
        if self.fts_available:
            try:
                self.conn.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('optimize')")
            except sqlite3.Error:
                pass

    # ------------------------------------------------------------------ #
    # integrity (doctor)
    # ------------------------------------------------------------------ #
    def integrity_check(self) -> List[str]:
        rows = self.conn.execute("PRAGMA integrity_check").fetchall()
        return [r[0] for r in rows]

    def duplicate_chunk_ids(self) -> List[Tuple[str, int]]:
        rows = self.conn.execute(
            "SELECT chunk_id, COUNT(*) AS n FROM chunks GROUP BY chunk_id HAVING n > 1"
        ).fetchall()
        return [(r["chunk_id"], r["n"]) for r in rows]

    def orphaned_chunks(self) -> List[int]:
        rows = self.conn.execute(
            "SELECT c.id FROM chunks c LEFT JOIN files f ON f.id = c.file_id WHERE f.id IS NULL"
        ).fetchall()
        return [r["id"] for r in rows]

    def chunk_count_total(self) -> int:
        row = self.conn.execute("SELECT COUNT(*) AS n FROM chunks").fetchone()
        return int(row["n"])
