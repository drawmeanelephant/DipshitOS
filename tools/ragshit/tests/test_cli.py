"""CLI behavior: exit codes and output shapes."""

from __future__ import annotations

import json

import pytest

from conftest import commit_all, write_file

from ragshit.cli import main


def test_version(capsys):
    with pytest.raises(SystemExit) as exc:
        main(["--version"])
    assert exc.value.code == 0
    assert "ragshit" in capsys.readouterr().out


def test_unknown_command_exits_2(capsys):
    with pytest.raises(SystemExit) as exc:
        main(["frobnicate", "."])
    assert exc.value.code == 2


def test_init_writes_config(repo, capsys):
    assert main(["init", str(repo)]) == 0
    assert (repo / ".ragshit.toml").exists()
    assert (repo / ".ragshitignore").exists()


def test_index_and_query(sample_repo, capsys):
    assert main(["index", str(sample_repo)]) == 0
    out = capsys.readouterr().out
    assert "files added:     5" in out
    assert main(["query", str(sample_repo), "kernel handoff", "--limit", "3"]) == 0
    query_out = capsys.readouterr().out
    assert "===== BEGIN SOURCE =====" in query_out
    assert "===== END SOURCE =====" in query_out


def test_query_jsonl(sample_repo, capsys):
    main(["index", str(sample_repo)])
    capsys.readouterr()
    assert main(["query", str(sample_repo), "handoff", "--format", "jsonl"]) == 0
    out = capsys.readouterr().out
    line = json.loads(out.splitlines()[0])
    assert line["path"]
    assert line["lines"][1] >= line["lines"][0]


def test_query_explain(sample_repo, capsys):
    main(["index", str(sample_repo)])
    capsys.readouterr()
    main(["query", str(sample_repo), "kernel handoff", "--explain"])
    out = capsys.readouterr().out
    assert "score: " in out


def test_bundle_writes_file(sample_repo, capsys, tmp_path):
    main(["index", str(sample_repo)])
    capsys.readouterr()
    out_file = tmp_path / "ctx.md"
    assert main(["bundle", str(sample_repo), "kernel handoff",
                 "--output", str(out_file)]) == 0
    assert out_file.exists()
    assert "===== BEGIN SOURCE =====" in out_file.read_text(encoding="utf-8")


def test_doctor_fails_without_index(sample_repo, capsys):
    assert main(["doctor", str(sample_repo)]) == 1
    out = capsys.readouterr().out
    assert "no index" in out  # doctor reports to stdout
    assert "[FAIL]" in out


def test_doctor_passes_after_index(sample_repo, capsys):
    assert main(["index", str(sample_repo)]) == 0
    capsys.readouterr()
    assert main(["doctor", str(sample_repo)]) == 0
    out = capsys.readouterr().out
    assert "all required checks passed" in out
    assert "[OK]" in out


def test_doctor_tolerates_discovery_skips(sample_repo, capsys):
    """Files discovery skips for a documented reason (binary here) must not
    fail doctor's freshness check — the expected set is the discovery
    candidate set, not raw tracked files."""
    write_file(sample_repo, "blob.dat", "A\x00B\x00C")
    commit_all(sample_repo, "add tracked binary")
    assert main(["index", str(sample_repo)]) == 0
    capsys.readouterr()
    assert main(["doctor", str(sample_repo)]) == 0
    assert "all required checks passed" in capsys.readouterr().out


def test_query_without_index_fails(sample_repo, capsys):
    assert main(["query", str(sample_repo), "anything"]) == 1
    assert "no index" in capsys.readouterr().err


def test_non_repository_fails(tmp_path, capsys):
    assert main(["index", str(tmp_path)]) == 1
    assert "not inside a Git repository" in capsys.readouterr().err


def test_inspect(sample_repo, capsys):
    main(["index", str(sample_repo)])
    capsys.readouterr()
    assert main(["inspect", str(sample_repo), "kernel/src/main.zig"]) == 0
    out = capsys.readouterr().out
    assert "path:     kernel/src/main.zig" in out
    assert "chunks:" in out


def test_inspect_missing_file_fails(sample_repo, capsys):
    main(["index", str(sample_repo)])
    capsys.readouterr()
    assert main(["inspect", str(sample_repo), "nope.txt"]) == 1
    assert "not in the index" in capsys.readouterr().err


def test_status(sample_repo, capsys):
    main(["index", str(sample_repo)])
    capsys.readouterr()
    assert main(["status", str(sample_repo)]) == 0
    out = capsys.readouterr().out
    assert "files, " in out
    assert "FTS5:" in out


def test_diff_command(sample_repo, capsys):
    main(["index", str(sample_repo)])
    write_file(sample_repo, "docs/new.md", "# New\n\nKernel handoff addition.\n")
    commit_all(sample_repo, "add new doc")
    capsys.readouterr()
    assert main(["diff", str(sample_repo), "HEAD~1..HEAD"]) == 0
    out = capsys.readouterr().out
    assert "Changed files" in out
    assert "docs/new.md" in out
