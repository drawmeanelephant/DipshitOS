"""Indexing: schema, records, stable chunk ids, FTS degradation."""

from __future__ import annotations

import sqlite3

from conftest import commit_all, write_file

from ragshit.config import RagshitConfig, resolve_database_path
from ragshit.discovery.ignore import IgnoreRules
from ragshit.git.repository import GitRepository
from ragshit.indexing.database import Database
from ragshit.indexing.indexer import Indexer, stable_chunk_id


def _index(repo, config=None):
    """Index and return an OPEN database (callers close it)."""
    config = config or RagshitConfig()
    repo_obj = GitRepository.from_path(repo)
    db = Database.open(repo, config)
    stats = Indexer(db, repo_obj, config, IgnoreRules(repo)).run()
    return db, stats, repo_obj


def test_schema_tables(sample_repo, config):
    db, _, repo_obj = _index(sample_repo, config)
    names = {
        r[0] for r in db.conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
    }
    assert {"repositories", "files", "chunks", "git_refs", "index_runs"} <= names
    if db.fts_available:
        assert "chunks_fts" in names
    db.close()


def test_file_records(sample_repo, config):
    db, _, repo_obj = _index(sample_repo, config)
    rec = db.file_record(repo_obj.repo_id, "kernel/src/main.zig")
    assert rec is not None
    assert rec.kind == "source"
    assert rec.language == "zig"
    assert rec.tracked is True
    assert len(rec.content_hash) == 64
    assert rec.line_count > 0
    db.close()


def test_chunk_records(sample_repo, config):
    db, _, repo_obj = _index(sample_repo, config)
    chunks = db.chunks_for_path(repo_obj.repo_id, "docs/decisions/0001-demo.md")
    assert len(chunks) >= 3  # title + sections
    content = "\n".join(c.content for c in chunks)
    assert "ExitBootServices" in content  # decision content preserved
    assert "D1. No ExitBootServices" in content
    assert any(c.heading and "Decisions" in c.heading for c in chunks)  # ancestry
    assert all(c.commit for c in chunks)  # commit at indexing time
    assert all(c.language == "markdown" for c in chunks)
    db.close()


def test_wal_mode(sample_repo, config):
    db, _, _ = _index(sample_repo, config)
    mode = db.conn.execute("PRAGMA journal_mode").fetchone()[0]
    assert mode == "wal"
    db.close()


def test_stable_chunk_id_function():
    a = stable_chunk_id("repo1", "a.md", "section", "Title", "hash1")
    b = stable_chunk_id("repo1", "a.md", "section", "Title", "hash1")
    c = stable_chunk_id("repo2", "a.md", "section", "Title", "hash1")
    d = stable_chunk_id("repo1", "b.md", "section", "Title", "hash1")
    assert a == b
    assert a != c
    assert a != d


def test_stable_ids_across_runs(sample_repo, config):
    db, _, repo_obj = _index(sample_repo, config)
    first = {r["chunk_id"] for r in db.conn.execute("SELECT chunk_id FROM chunks").fetchall()}
    db.close()
    db2, _, _ = _index(sample_repo, config)
    second = {r["chunk_id"] for r in db2.conn.execute("SELECT chunk_id FROM chunks").fetchall()}
    db2.close()
    assert first == second


def test_fts_available_by_default(sample_repo, config):
    db, _, _ = _index(sample_repo, config)
    assert db.fts_available is True
    db.close()


def test_fts_degradation(monkeypatch, sample_repo):
    monkeypatch.setenv("RAGSHIT_NO_FTS", "1")
    config = RagshitConfig()
    repo_obj = GitRepository.from_path(sample_repo)
    db = Database.open(sample_repo, config)
    Indexer(db, repo_obj, config, IgnoreRules(sample_repo)).run()
    assert db.fts_available is False
    # Indexing still works without FTS5.
    assert db.count_chunks(repo_obj.repo_id) > 0
    db.close()


def test_repository_id_not_absolute_path(sample_repo, config):
    _, _, repo_obj = _index(sample_repo, config)
    assert str(sample_repo) not in repo_obj.repo_id
