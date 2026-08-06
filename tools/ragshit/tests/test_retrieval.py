"""Retrieval behavior: exact matches, filters, degraded mode, edge cases."""

from __future__ import annotations

import pytest

from conftest import commit_all, git, write_file

from ragshit.config import RagshitConfig
from ragshit.discovery.ignore import IgnoreRules
from ragshit.errors import QuerySyntaxError
from ragshit.git.repository import GitRepository
from ragshit.indexing.database import Database
from ragshit.indexing.indexer import Indexer
from ragshit.retrieval.query import parse_query, run_query


def _setup(repo, config=None):
    config = config or RagshitConfig()
    db = Database.open(repo, config)
    Indexer(db, GitRepository.from_path(repo), config, IgnoreRules(repo)).run()
    return db, config


def _query(db, repo, config, text, limit=10):
    return run_query(db, GitRepository.from_path(repo), config.retrieval, text, limit)


def test_exact_path_ranks_top(sample_repo, config):
    db, config = _setup(sample_repo, config)
    results, _ = _query(db, sample_repo, config, "docs/decisions/0001-demo.md")
    assert results
    assert results[0].path == "docs/decisions/0001-demo.md"
    assert "path exact" in results[0].components
    db.close()


def test_exact_symbol_match(sample_repo, config):
    db, config = _setup(sample_repo, config)
    results, _ = _query(db, sample_repo, config, "symbol:BootInfo")
    assert results
    assert any(r.chunk.structural_name == "BootInfo" for r in results)
    assert any("symbol exact" in r.components for r in results)
    db.close()


def test_quoted_phrase_match(sample_repo, config):
    db, config = _setup(sample_repo, config)
    results, _ = _query(db, sample_repo, config, '"kernel handoff"')
    assert results
    assert any("kernel handoff" in r.chunk.content.lower() for r in results)
    db.close()


def test_kind_filter(sample_repo, config):
    db, config = _setup(sample_repo, config)
    results, _ = _query(db, sample_repo, config, "handoff kind:zig")
    assert results
    assert all(r.chunk.language == "zig" for r in results)
    db.close()


def test_path_filter(sample_repo, config):
    db, config = _setup(sample_repo, config)
    results, _ = _query(db, sample_repo, config, "handoff path:docs/")
    assert results
    assert all(r.path.startswith("docs/") for r in results)
    db.close()


def test_invalid_kind_filter_errors():
    with pytest.raises(QuerySyntaxError):
        parse_query("hello kind:banana")
    with pytest.raises(QuerySyntaxError):
        parse_query("hello foo:bar")
    with pytest.raises(QuerySyntaxError):
        parse_query("hello changed:maybe")
    with pytest.raises(QuerySyntaxError):
        parse_query("   ")


def test_changed_filter(sample_repo, config):
    db, config = _setup(sample_repo, config)
    write_file(sample_repo, "notes.txt", "modified line\n")
    results_true, _ = _query(db, sample_repo, config, "notes changed:true")
    assert results_true
    assert all(r.path == "notes.txt" for r in results_true)
    results_false, _ = _query(db, sample_repo, config, "notes changed:false")
    assert all(r.path != "notes.txt" for r in results_false)
    db.close()


def test_detached_head_query(sample_repo, config):
    git(sample_repo, "checkout", "-q", "--detach")
    db, config = _setup(sample_repo, config)
    results, _ = _query(db, sample_repo, config, "handoff")
    assert results
    db.close()


def test_no_commit_repo_query(tmp_path, config):
    from conftest import git, init_repo
    r = tmp_path / "norepo"
    init_repo(r)
    write_file(r, "docs/note.md", "# Note\n\nUncommitted plan.\n")
    git(r, "add", "docs/note.md")  # staged but never committed
    db, config = _setup(r, config)
    results, _ = _query(db, r, config, "plan")
    assert results
    db.close()


def test_fts_unavailable_fallback(monkeypatch, sample_repo, config):
    monkeypatch.setenv("RAGSHIT_NO_FTS", "1")
    db, config = _setup(sample_repo, config)
    assert db.fts_available is False
    results, _ = _query(db, sample_repo, config, "kernel handoff")
    assert results  # LIKE fallback still finds content
    db.close()


def test_limit_respected(sample_repo, config):
    db, config = _setup(sample_repo, config)
    results, _ = _query(db, sample_repo, config, "handoff", limit=2)
    assert len(results) <= 2
    db.close()


def test_score_components_exposed(sample_repo, config):
    db, config = _setup(sample_repo, config)
    results, _ = _query(db, sample_repo, config, "docs/decisions/0001-demo.md", limit=1)
    assert results
    assert results[0].score > 0
    assert "path exact" in results[0].components
    db.close()
