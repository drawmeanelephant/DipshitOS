"""Context bundle assembly and rendering."""

from __future__ import annotations

import json

from conftest import commit_all, write_file

from ragshit.config import RagshitConfig
from ragshit.discovery.ignore import IgnoreRules
from ragshit.git.repository import GitRepository
from ragshit.indexing.database import Database
from ragshit.indexing.indexer import Indexer
from ragshit.rendering.bundle import build_bundle, render_bundle_markdown
from ragshit.rendering.jsonl import render_bundle_jsonl


def _setup(repo, config):
    db = Database.open(repo, config)
    Indexer(db, GitRepository.from_path(repo), config, IgnoreRules(repo)).run()
    return db


def test_bundle_provenance(sample_repo, config):
    db = _setup(sample_repo, config)
    bundle = build_bundle(db, GitRepository.from_path(sample_repo), config,
                          "kernel handoff", 10)
    assert bundle.sources
    for source in bundle.sources:
        assert source.chunk.path
        assert source.chunk.start_line <= source.chunk.end_line
    text = render_bundle_markdown(bundle)
    assert "===== BEGIN SOURCE =====" in text
    assert "===== END SOURCE =====" in text
    assert "## Request" in text
    assert "## Repository state" in text
    assert "## Retrieved sources" in text
    assert "## Missing or unresolved evidence" in text
    db.close()


def test_bundle_budget(sample_repo, config):
    config.bundle.maximum_characters = 800
    db = _setup(sample_repo, config)
    bundle = build_bundle(db, GitRepository.from_path(sample_repo), config,
                          "handoff ExitBootServices", 20)
    assert bundle.total_characters <= 800
    assert bundle.sources  # never empty when candidates exist
    assert bundle.omissions  # something had to be cut
    db.close()


def test_bundle_preserves_exact_matches(sample_repo, config):
    config.bundle.maximum_characters = 600
    db = _setup(sample_repo, config)
    bundle = build_bundle(db, GitRepository.from_path(sample_repo), config,
                          "symbol:BootInfo", 20)
    assert bundle.sources
    assert any(r.chunk.structural_name == "BootInfo" for r in bundle.sources)
    db.close()


def test_bundle_deterministic(sample_repo, config):
    db = _setup(sample_repo, config)
    repo_obj = GitRepository.from_path(sample_repo)
    a = render_bundle_markdown(build_bundle(db, repo_obj, config, "kernel handoff", 10))
    b = render_bundle_markdown(build_bundle(db, repo_obj, config, "kernel handoff", 10))
    assert a == b
    db.close()


def test_bundle_jsonl(sample_repo, config):
    db = _setup(sample_repo, config)
    bundle = build_bundle(db, GitRepository.from_path(sample_repo), config,
                          "handoff", 10)
    obj = json.loads(render_bundle_jsonl(bundle))
    assert obj["request"] == "handoff"
    assert obj["sources"]
    assert obj["sources"][0]["path"]
    assert obj["sources"][0]["lines"]
    db.close()


def test_unresolved_evidence_scan(sample_repo, config):
    db = _setup(sample_repo, config)
    bundle = build_bundle(db, GitRepository.from_path(sample_repo), config,
                          "firmware serial evidence", 10)
    notes = " ".join(bundle.evidence_notes).lower()
    # The fixture ADR contains [inferred], Observed, and 'not yet determined'.
    assert "inferred" in notes or "not yet determined" in notes or "unresolved" in notes
    db.close()


def test_bundle_includes_diff(sample_repo, config):
    write_file(sample_repo, "docs/new.md", "# New\n\nMore kernel handoff details.\n")
    commit_all(sample_repo, "add docs")
    db = _setup(sample_repo, config)
    from ragshit.git.diff import diff_summary
    diff = diff_summary(GitRepository.from_path(sample_repo), "HEAD~1..HEAD")
    bundle = build_bundle(db, GitRepository.from_path(sample_repo), config,
                          "handoff", 10, diff)
    assert bundle.diff_section["range"] == "HEAD~1..HEAD"
    assert any(f["path"] == "docs/new.md" for f in bundle.diff_section["files"])
    db.close()
