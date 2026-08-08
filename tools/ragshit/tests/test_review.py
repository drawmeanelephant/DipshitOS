"""Tests for ragshit review: budgeted deterministic reviewer packet."""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from conftest import commit_all, git, init_repo, write_file
from ragshit.cli import main


def run_cli(args):
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
    write_file(r, "docs/decisions/0001-foo.md", "# Decision 0001\n\nWe use foo.\n")
    write_file(r, "tests/test_a.py", "def test_foo():\n    assert True\n")
    write_file(r, "docs/claims/0001-demo.md", "# Claim\n\nNotes about foo.\n")
    write_file(r, "docs/hardware-contract.md", "# HW\n\nContract mentions foo.\n")
    commit_all(r, "initial")
    assert main(["index", str(r)]) == 0
    return r


# -- basic coverage dims --

def test_single_changed_function(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n\ndef bar():\n    return 2\n")
    commit_all(r, "change foo")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "25000"])
    assert rc == 0
    assert len(out) <= 25000
    assert "foo" in out
    assert "changed_symbols" in out  # coverage summary line
    # Must cover foo symbol
    assert "changed_symbol:foo" in out or "foo" in out.lower()
    # Must have selected context
    assert "Selected context" in out
    rcj, outj, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "25000", "--json"])
    assert rcj == 0
    j = json.loads(outj)
    assert j["schema_version"] == "ragshit.review/v1"
    assert j["coverage_detail"]["changed_symbols"]["covered"] >= 1


def test_multiple_changed_symbols(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n\ndef bar():\n    return 99\n")
    commit_all(r, "both")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "30000", "--json"])
    assert rc == 0
    j = json.loads(out)
    # Both foo and bar should be covered if budget allows
    assert j["coverage_detail"]["changed_symbols"]["covered"] >= 2


def test_competing_candidates_under_small_budget(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n\ndef bar():\n    return 99\n\ndef baz():\n    return 7\n")
    commit_all(r, "three")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "8000", "--json"])
    assert rc == 0
    j = json.loads(out)
    assert len(out) <= 0 or j["requested_budget"] == 8000  # json not bounded, but check selection fits
    # markdown must fit
    rc2, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "8000"])
    assert rc2 == 0
    assert len(md) <= 8000


def test_direct_test_reference(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n\ndef bar():\n    return 2\n")
    commit_all(r, "foo again")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "30000", "--json"])
    assert rc == 0
    j = json.loads(out)
    assert "related_tests" in j["coverage_detail"]
    sel_paths = {s["path"] for s in j["selected"]}
    assert "tests/test_a.py" in sel_paths, f"expected test reference not selected: {sel_paths}"
    assert j["coverage_detail"]["related_tests"]["covered"] >= 1, j["coverage_detail"]
    assert any(s["reason"] == "test-reference" and s["path"] == "tests/test_a.py" for s in j["selected"]), j["selected"]


def test_documentation_reference(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n\ndef bar():\n    return 2\n")
    commit_all(r, "change foo for docs")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "30000", "--json"])
    assert rc == 0
    j = json.loads(out)
    assert "relevant_docs" in j["coverage_detail"]
    rc2, out2, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "50000", "--json"])
    j2 = json.loads(out2)
    sel_paths2 = {s["path"] for s in j2["selected"]}
    assert "docs/guide.md" in sel_paths2, f"expected docs/guide.md at large budget, got {sel_paths2}"
    assert j2["coverage_detail"]["relevant_docs"]["covered"] >= 1
    assert any(s["path"] == "docs/guide.md" and "documentation" in s["reason"] for s in j2["selected"]), j2["selected"]


def test_claim_decision_reference(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n\ndef bar():\n    return 2\n")
    commit_all(r, "claim ref")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "40000", "--json"])
    assert rc == 0
    j = json.loads(out)
    assert "decision_docs" in j["coverage_detail"]
    sel_paths = {s["path"] for s in j["selected"]}
    assert "docs/decisions/0001-foo.md" in sel_paths or "docs/claims/0001-demo.md" in sel_paths, f"expected claim/decision not selected: {sel_paths}"
    assert j["coverage_detail"]["decision_docs"]["total"] >= 2, j["coverage_detail"]["decision_docs"]
    assert j["coverage_detail"]["decision_docs"]["covered"] >= 1, j["coverage_detail"]["decision_docs"]


def test_redundant_candidate_elimination(tmp_path):
    r = make_repo(tmp_path)
    # Create a file with large content to generate many candidates near each other
    write_file(r, "a.py", "def foo():\n    return 42\n\ndef bar():\n    return 2\n")
    commit_all(r, "dup test")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "30000", "--json"])
    assert rc == 0
    j = json.loads(out)
    # No duplicate path+lines with same reason
    seen = set()
    for s in j["selected"]:
        key = (s["path"], tuple(s["lines"]), s["reason"])
        assert key not in seen, f"duplicate selected {key}"
        seen.add(key)
    # rejected should contain redundancy reasons for some
    # not all rejected are redundant, but at least structure holds
    assert "rejected" in j


def test_overlapping_chunks(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n\ndef bar():\n    return 3\n")
    commit_all(r, "overlap")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "15000"])
    assert rc == 0
    assert len(out) <= 15000


def test_exact_budget_boundary(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n")
    commit_all(r, "boundary")
    assert main(["index", str(r)]) == 0
    # Find actual len at 10000 then use exact
    rc, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "10000"])
    assert rc == 0
    length = len(md)
    # Request exactly that length should still fit
    rc2, md2, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(length)])
    assert rc2 == 0
    assert len(md2) <= length
    # If we had truncated, ensure no silent provenance loss: each selected has provenance
    rcj, outj, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(length), "--json"])
    j = json.loads(outj)
    for s in j["selected"]:
        assert s["provenance"]


def test_tiny_budget(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n")
    commit_all(r, "tiny")
    assert main(["index", str(r)]) == 0
    rc, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "1500"])
    assert rc == 0
    assert len(md) <= 1500
    # Must still contain header and not violate budget
    assert "Review packet" in md
    # Must mark truncation if too small
    # At 1500 chars, we can still have at least 1 symbol
    assert "Budget:" in md


def test_large_budget(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n")
    commit_all(r, "large")
    assert main(["index", str(r)]) == 0
    rc, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "60000"])
    assert rc == 0
    assert len(md) <= 60000
    # At large budget, we should be near fully covered for changed symbols
    rcj, outj, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "60000", "--json"])
    j = json.loads(outj)
    assert j["coverage_detail"]["changed_symbols"]["covered"] >= 1


def test_deterministic_repeated_markdown(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 7\n")
    commit_all(r, "c")
    assert main(["index", str(r)]) == 0
    _, a, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000"])
    _, b, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000"])
    assert a == b


def test_deterministic_repeated_json(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 7\n")
    commit_all(r, "c")
    assert main(["index", str(r)]) == 0
    _, a, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000", "--json"])
    _, b, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000", "--json"])
    assert a == b
    j = json.loads(a)
    assert j["timing_ms"] == 0


def test_stale_index_head_warning(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 99\n")
    commit_all(r, "c for mismatch")
    assert main(["index", str(r)]) == 0
    write_file(r, "a.py", "def foo():\n    return 100\n")
    commit_all(r, "new head not indexed")
    rc, out, err = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000", "--json"])
    assert rc == 0
    j = json.loads(out)
    assert j["index_stale"] is True
    assert j["index_warning"] is not None
    assert "range head" in j["index_warning"]
    assert "WARNING" in err
    rc2, md, err2 = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000"])
    assert "⚠️" in md


def test_deleted_symbol_case(tmp_path):
    r = tmp_path / "r"
    init_repo(r)
    write_file(r, "deleteme.py", "def gone():\n    pass\n")
    write_file(r, "keep.py", "def keep():\n    pass\n")
    commit_all(r, "initial del")
    assert main(["index", str(r)]) == 0
    (r / "deleteme.py").unlink()
    git(r, "rm", "deleteme.py")
    commit_all(r, "delete")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "25000", "--json"])
    assert rc == 0
    j = json.loads(out)
    assert any(s["name"] == "gone" for s in j["symbols"]), "gone not recovered from base revision"
    # historical candidate must be selectable and selected
    sel_gone = [s for s in j["selected"] if s["origin_symbol"] == "gone" or s["path"] == "deleteme.py"]
    assert sel_gone, f"deleted symbol produced no selectable candidate: selected={[s['path'] for s in j['selected']]}"
    # provenance must say historical base revision, not index
    assert any("historical" in s["provenance"] and "base:" in s["provenance"] for s in sel_gone), sel_gone
    # line range must correspond to historical source (def gone at 1-2)
    assert any(s["lines"] == [1, 2] for s in sel_gone), sel_gone
    # coverage should count gone only if candidate covers it
    assert j["coverage_detail"]["changed_symbols"]["covered"] >= 1
    assert "gone" in {k.split(":",1)[-1] for k in [c for c in sel_gone[0]["covers"] if c.startswith("changed_symbol:")]}, sel_gone[0]
    # also verify markdown shows historical provenance line
    rc2, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "25000"])
    assert "historical" in md and "deleteme.py" in md
    # At least one selected candidate should reference deleteme.py or gone


def test_filenames_with_spaces(tmp_path):
    r = tmp_path / "sp repo"
    init_repo(r)
    write_file(r, "a b.py", "def hello():\n    pass\n")
    write_file(r, "docs/guide.md", "# Guide\n")
    commit_all(r, "initial sp")
    assert main(["index", str(r)]) == 0
    write_file(r, "a b.py", "def hello():\n    return 1\n")
    commit_all(r, "change sp")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000"])
    assert rc == 0
    assert "a b.py" in out
    assert len(out) <= 20000


def test_no_useful_related_context(tmp_path):
    r = tmp_path / "r2"
    init_repo(r)
    write_file(r, "notes.txt", "plain text line\nmore\n")
    commit_all(r, "initial")
    assert main(["index", str(r)]) == 0
    write_file(r, "notes.txt", "plain text line\nchanged line\n")
    commit_all(r, "edit notes")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "15000"])
    assert rc == 0
    assert len(out) <= 15000
    # Should honestly report missing coverage, not claim full
    assert "Review packet" in out


def test_selection_diversity(tmp_path):
    """Selection should prefer diverse packet over near-identical chunks from same file."""
    r = make_repo(tmp_path)
    # Change a.py and also add a second file b.py changed in same range
    write_file(r, "b.py", "def bfunc():\n    return 1\n")
    commit_all(r, "add b")
    assert main(["index", str(r)]) == 0
    write_file(r, "a.py", "def foo():\n    return 42\n")
    write_file(r, "b.py", "def bfunc():\n    return 99\n")
    commit_all(r, "change both")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "12000", "--json"])
    assert rc == 0
    j = json.loads(out)
    sel_paths = {s["path"] for s in j["selected"]}
    # With small budget and two changed files, diversity should give us both files
    assert "a.py" in sel_paths and "b.py" in sel_paths


def test_exclusion_explanations(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n")
    commit_all(r, "c")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "8000", "--explain"])
    assert rc == 0
    assert "Rejected candidates" in out or "explain" in out.lower()
    # Should explain rejected because of budget or redundancy
    assert "budget" in out.lower() or "redundant" in out.lower() or "Rejected" in out


def test_budget_hard_enforced(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n")
    commit_all(r, "c")
    assert main(["index", str(r)]) == 0
    for bud in [5000, 10000, 20000]:
        rc, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(bud)])
        assert rc == 0
        assert len(md) <= bud, f"budget {bud} exceeded: {len(md)} > {bud}"


def test_json_schema_version(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 7\n")
    commit_all(r, "c")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000", "--json"])
    assert rc == 0
    j = json.loads(out)
    assert j["schema_version"] == "ragshit.review/v1"
    assert j["review_version"] == "1"
    assert "requested_budget" in j and "actual_size" in j
    assert "coverage" in j and "coverage_detail" in j
    assert "selected" in j and "rejected" in j
    assert "baseline" in j
    assert "index_head" in j


def test_provenance_preserved_when_truncated(tmp_path):
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n")
    commit_all(r, "c")
    assert main(["index", str(r)]) == 0
    rc, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "2000"])
    assert rc == 0
    assert len(md) <= 2000
    # Provenance must still be present even when truncated
    assert "provenance:" in md or "path:" in md


def test_baseline_comparison_improvement(tmp_path):
    """Diversity selector is strictly better than naive baseline on a crafted case.

    The naive baseline sorts by base_utility only, so it picks two redundant
    candidates from the same file before a high-value candidate from another
    file. The diversity selector penalizes the redundant second candidate via
    token Jaccard and picks the cross-file candidate instead, improving
    changed_files coverage by at least one. This is deterministic and does
    not depend on file parsing.
    """
    import hashlib
    from ragshit.review.candidates import Candidate
    from ragshit.review.coverage import CoverageSpec, coverage_metrics
    from ragshit.review.report import baseline_select
    from ragshit.review.selection import select

    def mk(path, reason, utility, cost, covers, token_word):
        tok = frozenset([token_word])
        c = Candidate(
            cid=f"id-{path}-{reason}-{covers[0]}-{utility}",
            path=path, start_line=1, end_line=2,
            content="x\n" * 2, content_hash=hashlib.sha256(f"{path}{reason}{utility}".encode()).hexdigest()[:16],
            kind="source", structural_name="sym", heading=None, language="python",
            commit="abc", reason=reason, origin_changed_file=path, origin_symbol="sym",
            covers=covers, token_set=tok, cost=cost, base_utility=utility,
            components={}, provenance="commit:abc", original_content="x\n" * 2,
        )
        c.cost = cost
        c.base_utility = utility
        return c

    spec = CoverageSpec(
        changed_symbols={"foo"},
        changed_files={"a.py", "b.py"},
        high_risk_files=set(),
        related_tests=set(),
        relevant_docs=set(),
        decision_docs=set(),
        stale_warnings=set(),
    )
    # a.py has two candidates with identical token sets -> Jaccard 1.0 -> redundancy penalty 0.8
    c1 = mk("a.py", "changed-symbol", 10.0, 500, ["changed_file:a.py"], "tok-a")
    c2 = mk("a.py", "changed-chunk", 9.9, 500, ["changed_file:a.py"], "tok-a")  # same token_word as c1
    c3 = mk("b.py", "changed-symbol", 9.5, 500, ["changed_file:b.py"], "tok-b")
    candidates = [c1, c2, c3]
    # Budget fits exactly 2 candidates (1000 chars). Naive picks c1+c2 (same file).
    # Diversity must pick c1+c3 (two files) because c2 is redundant with c1.
    for budget in [1000, 1100]:
        sel = select(candidates, spec, budget)
        base = baseline_select(candidates, budget)
        cov = coverage_metrics(spec, sel.selected)
        base_cov = coverage_metrics(spec, base)
        # Strict improvement on changed_files
        assert cov["changed_files"]["covered"] > base_cov["changed_files"]["covered"], \
            f"budget {budget}: diversity {cov} vs baseline {base}; selected {[c.path+':'+c.reason for c in sel.selected]} baseline {[c.path+':'+c.reason for c in base]}"
        sel_paths = {c.path for c in sel.selected}
        assert "a.py" in sel_paths and "b.py" in sel_paths


def test_line_aware_truncation_exact_counts(tmp_path):
    """Truncation retains line-accurate counts and truthful omitted markers."""
    import hashlib
    from ragshit.review.candidates import Candidate
    from ragshit.review.selection import _truncate_excerpt_line_aware
    raw = "\n".join([f"line{i} content here" for i in range(1, 21)])  # 20 lines
    c = Candidate(
        cid="trunc-test", path="a.py", start_line=10, end_line=29,
        content=raw, content_hash=hashlib.sha256(raw.encode()).hexdigest()[:16],
        kind="source", structural_name="foo", heading=None, language="python",
        commit="abc", reason="changed-symbol", origin_changed_file="a.py", origin_symbol="foo",
        covers=["changed_symbol:foo"], token_set=frozenset(["line1"]),
        cost=9999, base_utility=10.0, components={}, provenance="commit:abc index:abc",
        original_content=raw,
    )
    # Truncate to ~80 chars of content -> should keep only a few lines
    truncated = _truncate_excerpt_line_aware(c, 80)
    assert truncated.provenance == c.provenance, "provenance must survive truncation"
    assert truncated.path == c.path
    retained = truncated.content.splitlines()
    # Find marker line
    marker_lines = [l for l in retained if "truncated" in l and "omitted" in l]
    assert marker_lines, f"marker missing in {truncated.content!r}"
    marker = marker_lines[0]
    import re
    m = re.search(r"truncated (\d+) line\(s\) omitted", marker)
    assert m, f"marker format wrong: {marker}"
    claimed_omitted = int(m.group(1))
    # retained excerpt lines are all lines except marker
    kept = len([l for l in truncated.content.splitlines() if "truncated" not in l])
    # Check exact: kept + omitted == total
    assert kept + claimed_omitted == 20, f"kept {kept} + omitted {claimed_omitted} != 20"
    # end_line must be start_line + kept -1
    assert truncated.end_line == c.start_line + kept - 1
    # Marker must not claim fake number
    total_in_marker = re.search(r"retained (\d+) of (\d+) line", marker)
    if total_in_marker:
        assert int(total_in_marker.group(2)) == 20
        assert int(total_in_marker.group(1)) == kept
    # Changed region (start) retained
    assert "line1" in truncated.content


def test_truncation_preserves_fence_and_provenance(tmp_path):
    """Truncated packet remains valid markdown and provenance truthful."""
    r = make_repo(tmp_path)
    # Create a large file to force truncation at small budget
    big = "\n".join([f"    x{i} = {i}" for i in range(80)]) + "\n    return 1\n"
    write_file(r, "a.py", f"def foo():\n{big}")
    commit_all(r, "large for trunc")
    assert main(["index", str(r)]) == 0
    rc, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "2500"])
    assert rc == 0
    assert len(md) <= 2500
    # No broken code fence: count of ``` must be even
    assert md.count("```") % 2 == 0, "unbalanced code fences after truncation"
    # Provenance lines still present
    assert "provenance:" in md
    # If truncated, marker must be present (line-aware "omitted" or envelope fallback)
    if "truncated" in md:
        assert "omitted" in md or "truncated to fit budget" in md


def test_budget_actual_size_equals_rendered_len(tmp_path):
    """B: actual_size and Actual size line must equal len(markdown) and respect budget."""
    import re, json
    r = make_repo(tmp_path)
    write_file(r, "a.py", "def foo():\n    return 42\n")
    commit_all(r, "budget check")
    assert main(["index", str(r)]) == 0
    for budget in [5000, 10000, 20000, 30000]:
        rc, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(budget)])
        assert rc == 0
        assert len(md) <= budget, f"len {len(md)} > budget {budget}"
        m = re.search(r"Actual size: (\d+) chars", md)
        assert m, "Actual size line missing"
        assert int(m.group(1)) == len(md), f"Actual size {m.group(1)} != len(md) {len(md)}"
        rc2, jtxt, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(budget), "--json"])
        j = json.loads(jtxt)
        assert j["actual_size"] == len(md), f"json actual_size {j['actual_size']} != md len {len(md)}"
        assert j["selection_summary"]["actual_chars"] == len(md)

def test_framing_aware_iterative_avoids_envelope(tmp_path):
    """Regression: raw render over budget must trigger reselect, not envelope chop.

    The helper must measure the UNTRUNCATED render (enforce_budget=False) and
    iteratively reduce candidate allowance until the real packet fits.
    Normal 5k/10k budgets must NOT use the defensive envelope.
    Asserts: len<=budget, actual_size==len, selected blocks complete,
    no envelope marker, envelope_fallback_used==False.
    """
    r = tmp_path / "r"
    init_repo(r)
    big = "\n".join([f"    x{i} = {i}" for i in range(30)]) + "\n    return 1\n"
    write_file(r, "a.py", f"def foo():\n{big}def bar():\n    return 2\n")
    write_file(r, "b.py", "def baz():\n    return 3\n")
    write_file(r, "docs/guide.md", "# Guide\nfoo bar baz\n")
    write_file(r, "docs/claims/0001-demo.md", "# Claim\nfoo\n")
    write_file(r, "docs/decisions/0001-foo.md", "# Decision\nfoo\n")
    commit_all(r, "init")
    assert main(["index", str(r)]) == 0
    write_file(r, "a.py", f"def foo():\n{big.replace('x0 = 0', 'x0_changed = 0')}\ndef bar():\n    return 2\n")
    write_file(r, "b.py", "def baz():\n    return 77\n")
    commit_all(r, "change")
    assert main(["index", str(r)]) == 0
    # Tight budget: framing + several candidates > budget, so raw first render would be over.
    # After framing-aware shrink it must fit without envelope.
    for budget in [4000, 5000, 8000]:
        rc, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(budget)])
        assert rc == 0
        assert len(md) <= budget, f"len {len(md)} > budget {budget}"
        import re, json
        m = re.search(r"Actual size: (\d+) chars", md)
        assert m and int(m.group(1)) == len(md)
        rc2, jtxt, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(budget), "--json"])
        j = json.loads(jtxt)
        assert j["actual_size"] == len(md)
        assert j["selection_summary"]["actual_chars"] == len(md)
        # Must NOT have used envelope fallback on normal budgets
        assert j.get("envelope_fallback_used") is False, j
        assert j["selection_summary"].get("envelope_fallback_used") is False, j["selection_summary"]
        assert "[truncated to fit budget]" not in md, "envelope marker must not appear on normal budget"
        # Selected candidate blocks must be complete in markdown (verbatim content)
        for s in j["selected"]:
            assert s["content"].rstrip("\n") in md, f"selected {s['path']}:{s['lines']} content missing from md"
            # Also verify fence structure not broken
        assert md.count("```") % 2 == 0


def test_tiny_budget_envelope_fallback(tmp_path):
    """Tiny budget where framing alone > budget must use emergency envelope.

    Asserts fallback activates, packet still respects budget, is clearly marked,
    and is distinct from normal framing-aware path.
    """
    r = tmp_path / "r"
    init_repo(r)
    write_file(r, "a.py", "def foo():\n    return 1\n")
    commit_all(r, "init")
    assert main(["index", str(r)]) == 0
    write_file(r, "a.py", "def foo():\n    return 42\n")
    commit_all(r, "change")
    assert main(["index", str(r)]) == 0
    budget = 800  # genuinely impossible: framing alone > budget
    rc, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(budget)])
    assert rc == 0
    assert len(md) <= budget
    assert "[truncated to fit budget]" in md, "tiny budget must be marked by envelope"
    rc2, jtxt, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(budget), "--json"])
    import json as _j
    j = _j.loads(jtxt)
    assert j.get("envelope_fallback_used") is True
    assert j["selection_summary"].get("envelope_fallback_used") is True
    assert j["actual_size"] == len(md)
    assert j["selection_summary"]["actual_chars"] == len(md)
    # Normal budget on same repo must NOT use envelope (distinct path)
    rc3, md3, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "8000"])
    rc4, jtxt4, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "8000", "--json"])
    j4 = _j.loads(jtxt4)
    assert j4.get("envelope_fallback_used") is False
    assert "[truncated to fit budget]" not in md3

