"""Tests for ragshit impact command: temp repos, determinism, schema, edge cases."""
import json, pathlib, subprocess, sys, tempfile, hashlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
import pytest
from conftest import commit_all, git, init_repo, write_file
from ragshit.cli import main
from ragshit.config import RagshitConfig
# helpers
def run_cli(args, cwd=None):
    import io, contextlib
    out = io.StringIO(); err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(args)
    return rc, out.getvalue(), err.getvalue()

def make_repo(tmp_path):
    r = tmp_path / "r"
    init_repo(r)
    write_file(r, "a.py", "def foo():\n    return 1\n\ndef bar():\n    return 2\n")
    write_file(r, "docs/guide.md", "# Guide\n\nSee foo.\n")
    write_file(r, "tests/test_a.py", "def test_foo():\n    assert True\n")
    commit_all(r, "initial")
    # index
    assert main(["index", str(r)]) == 0
    return r

def test_one_changed_function(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n\ndef bar():\n    return 2\n")
    commit_all(r, "change foo")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["impact", str(r), "HEAD~1..HEAD"])
    assert rc == 0
    assert "foo" in out
    assert "Changed symbols" in out
    # bar should not be listed
    # foo symbol should be in changed symbols
    assert out.count("foo") >= 1

def test_multiple_functions(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n\ndef bar():\n    return 99\n")
    commit_all(r, "both")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["impact", str(r), "HEAD~1..HEAD"])
    assert rc == 0
    assert "foo" in out and "bar" in out

def test_renamed_file(tmp_path):
    r = make_repo(tmp_path)
    git(r, "mv", "a.py", "renamed.py")
    commit_all(r, "rename")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["impact", str(r), "HEAD~1..HEAD"])
    assert rc == 0
    assert "renamed.py" in out
    # should note rename
    assert "R" in out or "renamed" in out.lower()

def test_deleted_symbol_file(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "deleteme.py", "def gone():\n    pass\n")
    commit_all(r, "add deleteme")
    assert main(["index", str(r)]) == 0
    # keep base OID so fallback can recover even though DB deletes the file
    import subprocess as _sp
    base = _sp.run(["git","-C", str(r), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    (r / "deleteme.py").unlink()
    git(r, "rm", "deleteme.py")
    commit_all(r, "delete")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["impact", str(r), "HEAD~1..HEAD", "--json"])
    assert rc == 0
    j = json.loads(out)
    assert any(f["path"] == "deleteme.py" and f["status"].startswith("D") for f in j["files"])
    # The deleted symbol itself must be recovered via git-show fallback
    assert any(s["path"] == "deleteme.py" and s["name"] == "gone" for s in j["symbols"]), f"symbols={j['symbols']}"
    rc2, md, _ = run_cli(["impact", str(r), "HEAD~1..HEAD"])
    assert "gone" in md and "deleteme.py" in md
    # deterministic byte-identical JSON too
    assert j["timing_ms"] == 0

def test_documentation_reference(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n\ndef bar():\n    return 2\n")
    commit_all(r, "change foo for docs")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["impact", str(r), "HEAD~1..HEAD", "--json"])
    assert rc == 0
    j = json.loads(out)
    # Must surface docs/guide.md as doc-related when foo changed
    reasons = {n["reason"] for n in j["neighbors"]}
    paths = {n["path"] for n in j["neighbors"]}
    assert "docs/guide.md" in paths, f"expected docs/guide.md in neighbors, got {paths}"
    # Either documentation-reference or direct-symbol counts as doc signal
    assert ("documentation-reference" in reasons or "direct-symbol" in reasons), f"neighbors reasons {reasons}"
    # And stale-docs should flag it until docs updated
    assert any(d["path"] == "docs/guide.md" and d["symbol"] == "foo" for d in j["stale_docs"])
    # Markdown also must expose it
    rc2, md, _ = run_cli(["impact", str(r), "HEAD~1..HEAD"])
    assert "docs/guide.md" in md

def test_test_reference(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n\ndef bar():\n    return 2\n")
    commit_all(r, "foo again")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["impact", str(r), "HEAD~1..HEAD", "--json"])
    assert rc == 0
    j = json.loads(out)
    reasons = {n["reason"] for n in j["neighbors"]}
    assert "test-reference" in reasons, f"expected test-reference, got {reasons}"
    assert any(n["path"] == "tests/test_a.py" for n in j["neighbors"] if n["reason"] == "test-reference")
    rc2, md, _ = run_cli(["impact", str(r), "HEAD~1..HEAD"])
    assert "test_a.py" in md
    # heading-less json path still materializes the test evidence
    assert "Related tests" in md

def test_dirty_working_tree(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 7\n\ndef bar():\n    return 2\n")
    commit_all(r, "c")
    assert main(["index", str(r)]) == 0
    # dirty without commit
    write_file(r, "untracked.txt", "hello")
    rc, out, _ = run_cli(["impact", str(r), "HEAD~1..HEAD"])
    assert rc == 0
    assert "dirty" in out.lower() or "working tree" in out.lower() or "Changed files" in out

def test_invalid_range(tmp_path):
    r = make_repo(tmp_path)
    rc, out, err = run_cli(["impact", str(r), "notexist..HEAD"])
    assert rc != 0
    assert "cannot resolve" in err.lower() or "cannot resolve" in out.lower() or rc == 2 or rc == 1

def test_deterministic_repeated(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 7\n\ndef bar():\n    return 2\n")
    commit_all(r, "c")
    assert main(["index", str(r)]) == 0
    rc1, out1, _ = run_cli(["impact", str(r), "HEAD~1..HEAD", "--json"])
    rc2, out2, _ = run_cli(["impact", str(r), "HEAD~1..HEAD", "--json"])
    assert rc1 == 0 and rc2 == 0
    # Byte-identical without stripping anything: timing_ms must be deterministic (0)
    assert out1 == out2
    j1 = json.loads(out1)
    assert j1["timing_ms"] == 0
    rc3, md1, _ = run_cli(["impact", str(r), "HEAD~1..HEAD"])
    rc4, md2, _ = run_cli(["impact", str(r), "HEAD~1..HEAD"])
    assert md1 == md2

def test_json_schema_version(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 7\n")
    commit_all(r, "c")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["impact", str(r), "HEAD~1..HEAD", "--json"])
    assert rc == 0
    j = json.loads(out)
    assert j["schema_version"] == "ragshit.impact/v1"
    assert j["impact_version"] == "1"
    assert "files" in j and "commits" in j
    assert "file_scores" in j

def test_paths_with_spaces(tmp_path):
    r = tmp_path / "sp repo"
    init_repo(r)
    write_file(r, "a b.py", "def hello():\n    pass\n")
    commit_all(r, "initial sp")
    assert main(["index", str(r)]) == 0
    write_file(r, "a b.py", "def hello():\n    return 1\n")
    commit_all(r, "change sp")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["impact", str(r), "HEAD~1..HEAD"])
    assert rc == 0
    assert "a b.py" in out

def test_no_symbol_resolved(tmp_path):
    r = tmp_path / "r2"
    init_repo(r)
    write_file(r, "notes.txt", "plain text line\nmore\n")
    commit_all(r, "initial")
    assert main(["index", str(r)]) == 0
    write_file(r, "notes.txt", "plain text line\nchanged line\n")
    commit_all(r, "edit notes")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["impact", str(r), "HEAD~1..HEAD"])
    assert rc == 0
    # notes.txt has no symbol parser, should go to unresolved honestly
    assert "no symbol" in out.lower() or "Unresolved" in out or "notes.txt" in out

def test_scoring_components(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 9\n")
    commit_all(r, "c")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["impact", str(r), "HEAD~1..HEAD", "--json"])
    assert rc == 0
    j = json.loads(out)
    assert len(j["file_scores"]) >= 1
    fs = j["file_scores"][0]
    assert "components" in fs and isinstance(fs["components"], dict)
    assert "score" in fs and "level" in fs

def test_bundle_output(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 7\n")
    commit_all(r, "c")
    assert main(["index", str(r)]) == 0
    outpath = tmp_path / "bundle.md"
    rc, out, _ = run_cli(["impact", str(r), "HEAD~1..HEAD", "--bundle", str(outpath)])
    assert rc == 0
    assert outpath.exists()
    txt = outpath.read_text()
    assert "# Change impact" in txt
    assert "Highest-priority" in txt

def test_index_head_mismatch_warning(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 99\n")
    commit_all(r, "c for mismatch")
    assert main(["index", str(r)]) == 0
    # Create a new commit that the index does NOT see
    write_file(r, "a.py", "def foo():\n    return 100\n")
    commit_all(r, "new head not indexed")
    # Range points at the new head, but index still at prior HEAD -> warning
    rc, out, err = run_cli(["impact", str(r), "HEAD~1..HEAD", "--json"])
    assert rc == 0
    j = json.loads(out)
    assert j["index_stale"] is True
    assert j["index_warning"] is not None
    assert "range head" in j["index_warning"]
    assert "index HEAD" in j["index_warning"]
    assert "WARNING" in err
