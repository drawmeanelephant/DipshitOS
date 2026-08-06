"""Ranking: signal components and deterministic tie-breaking."""

from __future__ import annotations

from conftest import commit_all, write_file

from ragshit.config import RagshitConfig
from ragshit.discovery.ignore import IgnoreRules
from ragshit.git.repository import GitRepository
from ragshit.indexing.database import Database
from ragshit.indexing.indexer import Indexer
from ragshit.models import Chunk, GitState, QuerySpec, RetrievedChunk
from ragshit.rendering.markdown import render_source_block
from ragshit.retrieval.ranking import rank_candidates, sort_results
from ragshit.retrieval.query import run_query


def _chunk(path, start, end, symbol=None, heading=None, chunk_id="c"):
    return Chunk(
        chunk_id=chunk_id, file_id=1, repo_id="r", path=path,
        start_line=start, end_line=end, content="x" * 10,
        content_hash="h", kind="symbol", structural_name=symbol,
        heading=heading, language="zig", commit="abc",
    )


def test_changed_file_boost_and_line_overlap(sample_repo, config):
    db = Database.open(sample_repo, config)
    Indexer(db, GitRepository.from_path(sample_repo), config, IgnoreRules(sample_repo)).run()
    write_file(sample_repo, "kernel/src/main.zig", "pub fn handoff(info: *BootInfo) u64 {\n    _ = info;\n    return 1;\n}\n")
    git = GitState(
        repo_id="r", root=str(sample_repo), branch="main", head="h",
        detached=False, changed_paths={"kernel/src/main.zig"},
        changed_ranges={"kernel/src/main.zig": [(1, 4)]},
    )
    results, _ = run_query(
        db, GitRepository.from_path(sample_repo), config.retrieval,
        "handoff", 5, git,
    )
    modified = [r for r in results if "modified file" in r.components]
    assert modified
    assert any("changed-line overlap" in r.components for r in modified)
    db.close()


def test_tie_break_deterministic():
    a = RetrievedChunk(_chunk("b.md", 5, 9, chunk_id="z"), 1.0, {})
    b = RetrievedChunk(_chunk("a.md", 1, 3, chunk_id="a"), 1.0, {})
    c = RetrievedChunk(_chunk("a.md", 10, 12, chunk_id="b"), 1.0, {})
    ordered = sort_results([a, b, c])
    assert [r.chunk.path for r in ordered] == ["a.md", "a.md", "b.md"]
    assert ordered[0].chunk.start_line == 1  # start line breaks the tie
    assert ordered[1].chunk.start_line == 10


def test_symbol_exact_beats_fts():
    rc = RagshitConfig().retrieval
    q = QuerySpec(terms=["handoff"])
    git = GitState(repo_id="r", root=".", branch=None, head=None, detached=False)
    exact = _chunk("a.md", 1, 2, symbol="handoff", heading="handoff", chunk_id="1")
    fts_only = _chunk("b.md", 1, 2, symbol="other", heading="other", chunk_id="2")
    ranked = rank_candidates(
        rc, q, {exact.chunk_id: exact, fts_only.chunk_id: fts_only},
        {exact.chunk_id: 3.0, fts_only.chunk_id: 7.0}, git,
    )
    by_id = {r.chunk.chunk_id: r for r in ranked}
    assert by_id["1"].score > by_id["2"].score
    assert by_id["1"].components.get("symbol exact") == rc.symbol_match_boost


def test_explain_rendering():
    rc = RagshitConfig().retrieval
    q = QuerySpec(terms=["handoff"], path_filters=["a.md"])
    git = GitState(repo_id="r", root=".", branch=None, head=None, detached=False)
    chunk = _chunk("a.md", 1, 2, symbol="handoff", chunk_id="1")
    ranked = rank_candidates(rc, q, {"1": chunk}, {"1": 3.72}, git)
    text = render_source_block(ranked[0], explain=True)
    assert "score: " in text
    assert "symbol exact: +5.00" in text
    assert "path exact: +4.00" in text
    assert "FTS rank: +3.72" in text
