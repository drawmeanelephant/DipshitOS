"""Incremental indexing behavior and transactional rollback."""

from __future__ import annotations

import pytest

from conftest import commit_all, write_file

from ragshit.config import RagshitConfig
from ragshit.discovery.ignore import IgnoreRules
from ragshit.git.repository import GitRepository
from ragshit.indexing.database import Database
from ragshit.indexing.indexer import Indexer


def _run(repo, config):
    db = Database.open(repo, config)
    try:
        stats = Indexer(db, GitRepository.from_path(repo), config, IgnoreRules(repo)).run()
        return db, stats
    except Exception:
        db.close()
        raise


def test_initial_adds(sample_repo, config):
    db, stats = _run(sample_repo, config)
    assert stats.files_added == 5
    assert stats.files_unchanged == 0
    assert stats.chunks_added > 0
    db.close()


def test_second_run_all_unchanged(sample_repo, config):
    db, stats = _run(sample_repo, config)
    db.close()
    db, stats = _run(sample_repo, config)
    assert stats.files_unchanged == 5
    assert stats.files_added == 0
    assert stats.files_updated == 0
    db.close()


def test_modify_updates_file(sample_repo, config):
    _run(sample_repo, config)
    write_file(sample_repo, "notes.txt", "changed note\n")
    commit_all(sample_repo, "update notes")
    db, stats = _run(sample_repo, config)
    assert stats.files_updated == 1
    assert stats.files_unchanged == 4
    db.close()


def test_delete_removes_file(sample_repo, config):
    _run(sample_repo, config)
    (sample_repo / "notes.txt").unlink()
    commit_all(sample_repo, "delete notes")
    db, stats = _run(sample_repo, config)
    assert stats.files_removed == 1
    assert db.count_files(GitRepository.from_path(sample_repo).repo_id) == 4
    db.close()


def test_parser_failure_rolls_back(monkeypatch, sample_repo, config):
    db, _ = _run(sample_repo, config)
    repo_id = GitRepository.from_path(sample_repo).repo_id
    before_files = db.count_files(repo_id)
    before_chunks = db.count_chunks(repo_id)
    db.close()

    # A changed file forces the reparse path, where the failure happens.
    write_file(sample_repo, "notes.txt", "new content that triggers reparse\n")

    def boom(self, *args, **kwargs):
        raise RuntimeError("parser exploded")

    monkeypatch.setattr(Indexer, "_make_chunks", boom)
    with pytest.raises(RuntimeError):
        _run(sample_repo, config)

    db = Database.open(sample_repo, config)
    assert db.count_files(repo_id) == before_files
    assert db.count_chunks(repo_id) == before_chunks
    db.close()


def test_no_commit_repo_indexes(tmp_path, config):
    from conftest import git, init_repo
    r = tmp_path / "empty"
    init_repo(r)
    write_file(r, "docs/note.md", "# Note\n\nNo commits yet.\n")
    git(r, "add", "docs/note.md")  # staged but never committed
    db, stats = _run(r, config)
    assert stats.files_added >= 1
    repo_id = GitRepository.from_path(r).repo_id
    assert db.count_chunks(repo_id) > 0
    db.close()


def test_detached_head_indexes(sample_repo, config):
    from conftest import git
    git(sample_repo, "checkout", "-q", "--detach")
    db, stats = _run(sample_repo, config)
    repo_obj = GitRepository.from_path(sample_repo)
    assert repo_obj.detached is True
    assert db.count_files(repo_obj.repo_id) == 5
    db.close()
