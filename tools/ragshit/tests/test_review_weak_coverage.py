"""Regression tests: decision-useful coverage under hard budget truncation.

Claim 0176 — a structurally large changed symbol must not be reported as
fully/usefully covered merely because one nearly content-free prefix line
survived mandatory-budget truncation (the one-line-`virtio_pci_init` shape).

Two acceptable outcomes after truncation, both enforced here:

  A — the rendered excerpt actually contains useful structural identity (the
      signature/heading) PLUS the actual changed-line neighborhood, and the
      symbol counts as covered; or
  B — the coverage report explicitly marks the symbol weak
      (`weak: true`, listed in missing_coverage, never counted identically
      to useful coverage).

The forbidden outcome is: truncated-to-prefix excerpt + ordinary full
coverage credit. Also verified: anchor-aware truncation works per chunk
type (source / markdown / shell) without a magic fixed line count, and weak
coverage never counts identically to useful coverage.
"""
import hashlib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from conftest import commit_all, init_repo, write_file  # noqa: E402
from ragshit.cli import main  # noqa: E402


def run_cli(args):
    import io, contextlib
    out = io.StringIO(); err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(args)
    return rc, out.getvalue(), err.getvalue()


def _scratch_repo(tmp_path, files):
    r = tmp_path / "r"
    init_repo(r)
    write_file(r, ".gitignore", ".ragshit/\n")
    for rel, content in files.items():
        write_file(r, rel, content)
    commit_all(r, "initial")
    assert main(["index", str(r)]) == 0
    return r


# --------------------------------------------------------------------------- #
# Synthetic end-to-end: large changed function, changed line far from start,
# enough mandatory candidates to force truncation, tight budget.
# --------------------------------------------------------------------------- #
def _big_repo(tmp_path):
    big = "def big_function():\n" + "".join(f"    x{i} = {i}\n" for i in range(1, 151)) + "    return 0\n"
    files = {"src/big.py": big}
    for i in range(8):
        files[f"src/f{i}.py"] = f"def func_{i}():\n    return {i}\n"
    r = _scratch_repo(tmp_path, files)
    # change deep in big_function's body (line 121) plus the other functions
    big2 = big.replace("    x120 = 120\n", "    x120 = 999\n")
    write_file(r, "src/big.py", big2)
    for i in range(8):
        write_file(r, f"src/f{i}.py", f"def func_{i}():\n    return {i + 100}\n")
    commit_all(r, "change")
    assert main(["index", str(r)]) == 0
    return r


def test_large_changed_symbol_never_useless_prefix(tmp_path):
    """Forced truncation of a ~152-line changed function with the real change
    at line 121: either the excerpt shows signature + changed line (A), or the
    symbol is explicitly weak and never counted as useful coverage (B)."""
    r = _big_repo(tmp_path)
    budget = 6000
    rc, jtxt, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(budget), "--json"])
    assert rc == 0
    j = json.loads(jtxt)
    # The scenario must actually force mandatory truncation.
    assert j["selection_summary"]["truncated"] is True, \
        f"scenario did not force truncation: {j['selection_summary']}"
    # big_function is mandatory, so it must be selected (possibly weak).
    big = [s for s in j["selected"] if s.get("origin_symbol") == "big_function"]
    assert big, "big_function must be selected (mandatory changed symbol)"
    s = big[0]
    if s.get("weak"):
        # B: explicit weak coverage — never counted identically to useful.
        assert "big_function" in j["missing_coverage"]["changed_symbols"], \
            f"weak big_function still counted covered: {j['missing_coverage']}"
        assert j["coverage_detail"]["changed_symbols"]["covered"] < \
            j["coverage_detail"]["changed_symbols"]["total"], j["coverage_detail"]
    else:
        # A: useful excerpt — structural identity AND the changed line.
        assert "def big_function" in s["content"], f"signature lost: {s['content']!r}"
        assert "x120 = 999" in s["content"], \
            f"changed line (121) not represented: {s['content']!r}"
    # Never the one-line-prefix shape for a large symbol.
    assert s["lines"][1] - s["lines"][0] + 1 >= 2, \
        f"large symbol excerpt collapsed to a single line: {s['lines']} {s['content']!r}"


def test_every_truncated_changed_symbol_is_anchor_aware_or_weak(tmp_path):
    """General invariant across the whole synthetic packet: a truncated
    changed-symbol excerpt is either explicitly weak (listed as missing) or
    keeps structural identity AND overlaps the changed-line neighborhood."""
    r = _big_repo(tmp_path)
    rc, jtxt, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "6000", "--json"])
    assert rc == 0
    j = json.loads(jtxt)
    for s in j["selected"]:
        if s["reason"] != "changed-symbol":
            continue
        if s.get("weak"):
            syms = [c.split(":", 1)[1] for c in s["covers"] if c.startswith("changed_symbol:")]
            for sym in syms:
                assert sym in j["missing_coverage"]["changed_symbols"], \
                    f"weak {sym} still counted covered"
            continue
        if "truncated" not in s["content"]:
            continue
        name = s.get("origin_symbol") or s.get("structural_name")
        # document symbols are named by their file path, which never appears
        # inside the file's content; identity = retained opening line + path
        if name and name != s["path"]:
            assert re.search(rf"\b{re.escape(name)}\b", s["content"]), \
                f"truncated non-weak excerpt lost structural identity: {s['path']}:{s['lines']}"
        anchors = s.get("anchor_ranges") or []
        if anchors:
            rs, re_ = s["lines"]
            assert any(rs <= er and re_ >= sr for sr, er in anchors), \
                f"truncated non-weak excerpt misses changed region: {s['path']}:{s['lines']} anchors={anchors}"


def test_weak_coverage_reported_in_json_and_markdown(tmp_path):
    """Weak/truncated coverage is explicit in both JSON and Markdown."""
    r = _big_repo(tmp_path)
    rc, jtxt, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "6000", "--json"])
    assert rc == 0
    j = json.loads(jtxt)
    assert isinstance(j.get("weak"), list)
    for s in j["selected"]:
        assert "weak" in s and "weak_reason" in s, "selected candidates must carry weak flags"
    rc2, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "6000"])
    assert rc2 == 0
    assert len(md) <= 6000
    assert "Weak / truncated coverage" in md or "weak" in md.lower()


# --------------------------------------------------------------------------- #
# Anchor-aware truncation per chunk type (source / markdown / shell) — the
# line-preservation rules are structural, not a magic fixed count.
# --------------------------------------------------------------------------- #
from ragshit.review.candidates import Candidate  # noqa: E402


def _unit_candidate(path, content, anchor_ranges, kind="symbol", language="python",
                    name="sym", start_line=1, reason="changed-symbol"):
    return Candidate(
        cid=f"id-{path}-{start_line}", path=path, start_line=start_line,
        end_line=start_line + len(content.splitlines()) - 1,
        content=content, content_hash=hashlib.sha256(content.encode()).hexdigest()[:16],
        kind=kind, structural_name=name, heading=None, language=language,
        commit="abc", reason=reason, origin_changed_file=path, origin_symbol=name,
        covers=[f"changed_symbol:{name}", "changed_file:" + path],
        token_set=frozenset([name]), cost=99999, base_utility=10.0,
        components={}, provenance="commit:abc index:abc", original_content=content,
        anchor_ranges=anchor_ranges,
    )


def test_truncator_source_chunk_keeps_signature_and_changed_region(tmp_path):
    """Source chunk: a zig/python-style function with the change deep in the
    body — the excerpt must keep the signature AND the actual changed line."""
    from ragshit.review.selection import _truncate_excerpt_line_aware
    body = "".join(f"    const v{i} = {i};\n" for i in range(1, 121))
    content = f"pub fn big() void {{\n{body}    _ = changed_here;\n}}"
    # changed line 122 ("    _ = changed_here;") inside chunk lines 1..123
    c = _unit_candidate("src/a.zig", content, [(122, 122)], kind="symbol",
                        language="zig", name="big")
    truncated = _truncate_excerpt_line_aware(c, 260)
    assert "pub fn big() void {" in truncated.content, truncated.content
    assert "changed_here" in truncated.content, \
        f"changed region lost: {truncated.content!r}"
    assert truncated.weak is False, truncated.weak_reason
    assert truncated.start_line == 1, truncated
    assert truncated.end_line >= 122, truncated


def test_truncator_markdown_chunk_keeps_heading_and_changed_region(tmp_path):
    """Markdown section: the heading line must survive plus the changed line."""
    from ragshit.review.selection import _truncate_excerpt_line_aware
    lines = ["# Driver transport", "", "intro", "more context",
             "changed sentence here", "tail", "tail2", "tail3", "tail4", "tail5"]
    content = "\n".join(lines)
    c = _unit_candidate("docs/guide.md", content, [(5, 5)], kind="section",
                        language="markdown", name="Driver transport")
    truncated = _truncate_excerpt_line_aware(c, 90)
    assert "# Driver transport" in truncated.content, truncated.content
    assert "changed sentence here" in truncated.content, \
        f"changed region lost: {truncated.content!r}"
    assert truncated.weak is False, truncated.weak_reason


def test_truncator_shell_chunk_keeps_function_opener_and_changed_region(tmp_path):
    """Shell function: the `name() {` opener must survive plus the changed line."""
    from ragshit.review.selection import _truncate_excerpt_line_aware
    body = "".join(f"    echo line {i}\n" for i in range(1, 61))
    content = f"run_tests() {{\n{body}    echo CHANGED\n}}"
    # changed line 62 ("    echo CHANGED") inside chunk lines 1..63
    c = _unit_candidate("tools/x.sh", content, [(62, 62)], kind="symbol",
                        language="shell", name="run_tests")
    truncated = _truncate_excerpt_line_aware(c, 200)
    assert "run_tests() {" in truncated.content, truncated.content
    assert "CHANGED" in truncated.content, f"changed region lost: {truncated.content!r}"
    assert truncated.weak is False, truncated.weak_reason


def test_truncator_marks_weak_when_signature_cannot_survive(tmp_path):
    """When the budget cannot even keep the structural identity line, the
    excerpt is explicitly weak — it must never count as useful coverage."""
    from ragshit.review.selection import _truncate_excerpt_line_aware
    content = "pub fn a_very_long_function_name_that_takes_many_chars() void {\n" + \
        "    const x = 1;\n    _ = x;\n    // body\n    _ = changed_here;\n}\n"
    c = _unit_candidate("src/a.zig", content, [(5, 5)], language="zig", name="a_very_long_function_name_that_takes_many_chars")
    truncated = _truncate_excerpt_line_aware(c, 30)  # tiny allowance: signature line alone is 60+ chars
    assert truncated.weak is True, truncated.content
    assert truncated.weak_reason, "weak reason must explain why"


def test_truncator_weak_when_changed_region_cannot_survive(tmp_path):
    """Signature fits but the deep changed region does not: weak, because the
    change is not represented (option B), never ordinary coverage."""
    from ragshit.review.selection import _truncate_excerpt_line_aware
    lines = ["pub fn big() void {"] + [f"    const v{i} = {i};" for i in range(1, 41)] + ["}"]
    content = "\n".join(lines)
    # changed line is deep (line 40); allowance fits only the signature line
    c = _unit_candidate("src/a.zig", content, [(40, 40)], language="zig", name="big")
    truncated = _truncate_excerpt_line_aware(c, 60)
    assert truncated.weak is True, truncated.content
    assert "pub fn big() void {" in truncated.content, truncated.content
    assert "changed region" in truncated.weak_reason, truncated.weak_reason


def test_weak_candidate_never_counts_as_covered(tmp_path):
    """Unit: a weak candidate contributes to NO covered dimension; a useful
    truncated candidate still does."""
    from ragshit.review.candidates import Candidate
    from ragshit.review.coverage import CoverageSpec, coverage_metrics
    weak = _unit_candidate("src/a.py", "def x():\n    pass\n", [(1, 1)], name="x")
    weak.weak = True
    weak.weak_reason = "excerpt lost the changed-line neighborhood"
    useful = _unit_candidate("src/b.py", "def y():\n    pass\n", [(1, 1)], name="y")
    spec = CoverageSpec(
        changed_symbols={"x", "y"}, changed_files={"src/a.py", "src/b.py"},
        high_risk_files=set(), related_tests=set(), relevant_docs=set(),
        decision_docs=set(), stale_warnings=set(),
    )
    m = coverage_metrics(spec, [weak, useful])
    assert m["changed_symbols"]["covered"] == 1, m
    assert m["changed_symbols"]["weak"] == 1, m
    assert m["changed_files"]["covered"] == 1, m


def test_weak_coverage_deterministic(tmp_path):
    """Repeated runs produce byte-identical packets including weak flags."""
    r = _big_repo(tmp_path)
    _, a, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "6000", "--json"])
    _, b, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "6000", "--json"])
    assert a == b
