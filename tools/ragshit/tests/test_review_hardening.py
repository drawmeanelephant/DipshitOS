"""Regression tests for the `ragshit review` dogfood-hardening fixes.

Covers the classes of defects exposed by real dogfood on DipshitOS:

  A — packet-size accounting: every public size value (markdown "Actual size"
      line, markdown "budget utilization" line, JSON actual_size, JSON
      selection_summary.actual_chars) equals len(final rendered markdown).
      The raw sum of candidate block costs keeps a DISTINCT name
      (candidate_cost_chars) and is never overloaded onto actual_chars.
  B — document/decision coverage: a selected candidate contributes to
      relevant_docs / decision_docs when its OWN path is in that dimension,
      even when it entered the pool as changed-symbol / changed-chunk /
      high-risk-file. A directly changed doc/claim must satisfy coverage.
  C — generic-symbol stale filter: a project-name heading change must not
      stale-warn unrelated docs, while a specific identifier must still warn.
  D — shell importance: low-value shell assignments never enter the
      mandatory pool and functions outrank throwaway variables; a local
      assignment inside a function folds into the function chunk.
  G — language-tagged code fences with a safe plain-fence fallback.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from conftest import commit_all, git, init_repo, write_file  # noqa: E402
from ragshit.cli import main  # noqa: E402


def run_cli(args):
    import io, contextlib
    out = io.StringIO(); err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(args)
    return rc, out.getvalue(), err.getvalue()


def _scratch_repo(tmp_path, files):
    """A temp git repo with a .gitignore that keeps the tool's own .ragshit/
    index out of git (so `git add -A` never commits the DB files)."""
    r = tmp_path / "r"
    init_repo(r)
    write_file(r, ".gitignore", ".ragshit/\n")
    for rel, content in files.items():
        write_file(r, rel, content)
    commit_all(r, "initial")
    assert main(["index", str(r)]) == 0
    return r


# --------------------------------------------------------------------------- #
# A — accounting
# --------------------------------------------------------------------------- #

def test_accounting_all_public_size_values_agree(tmp_path):
    """A: 'Actual size', 'budget utilization', JSON actual_size and
    selection_summary.actual_chars all equal len(final markdown), on a
    realistic multi-candidate packet (several files, several docs, shell +
    zig + python)."""
    r = _scratch_repo(tmp_path, {
        "src/core.zig": "pub fn handle_exit() void {\n    return;\n}\n\npub fn install_map() void {\n    return;\n}\n",
        "src/driver.zig": "pub fn poll_device() void {\n    return;\n}\n",
        "tools/build.sh": "#!/usr/bin/env bash\nROOT=\"$(pwd)\"\n\nbuild_all() {\n    echo building\n}\n",
        "docs/guide.md": "# Guide\n\nSee handle_exit.\n",
        "docs/decisions/0001-x.md": "# Decision 0001\n\nWe call handle_exit.\n",
        "docs/claims/0001-demo.md": "# Claim\n\nNotes about poll_device.\n",
        "tests/test_core.zig": 'test "core" {\n    _ = handle_exit;\n}\n',
    })
    # A realistic change: several files at once so candidates compete.
    write_file(r, "src/core.zig", "pub fn handle_exit() void {\n    return 1;\n}\n\npub fn install_map() void {\n    return;\n}\n")
    write_file(r, "src/driver.zig", "pub fn poll_device() void {\n    return 1;\n}\n")
    write_file(r, "tools/build.sh", "#!/usr/bin/env bash\nROOT=\"$(pwd)\"\n\nbuild_all() {\n    echo building now\n}\n")
    write_file(r, "docs/guide.md", "# Guide\n\nSee handle_exit and poll_device.\n")
    commit_all(r, "multi change")
    assert main(["index", str(r)]) == 0

    for budget in [6000, 12000, 30000]:
        rc, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(budget), "--explain"])
        assert rc == 0
        assert len(md) <= budget, f"budget {budget} exceeded: {len(md)}"
        m_actual = re.search(r"^Actual size: (\d+) chars$", md, re.M)
        m_util = re.search(r"^- budget utilization: (\d+) / (\d+) \(([0-9.]+)%\)$", md, re.M)
        assert m_actual, "Actual size line missing"
        assert m_util, "budget utilization line missing"
        # Requirement A3: the two human-readable lines describe the SAME packet.
        assert int(m_actual.group(1)) == len(md), f"Actual size {m_actual.group(1)} != len(md) {len(md)}"
        assert int(m_util.group(1)) == len(md), f"utilization chars {m_util.group(1)} != len(md) {len(md)}"
        assert int(m_util.group(2)) == budget
        assert abs(float(m_util.group(3)) - round(len(md) / budget * 100, 1)) < 0.11
        # Requirement A2: JSON reports the same final markdown length.
        rcj, jtxt, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(budget), "--explain", "--json"])
        assert rcj == 0
        j = json.loads(jtxt)
        assert j["actual_size"] == len(md), f"json actual_size {j['actual_size']} != len(md) {len(md)}"
        assert j["selection_summary"]["actual_chars"] == len(md)
        # Requirement A4: candidate-only cost keeps a distinct explicit name.
        cc = j["selection_summary"]["candidate_cost_chars"]
        assert isinstance(cc, int) and cc >= 0
        assert cc == sum(s["cost"] for s in j["selected"]), "candidate_cost_chars must be the sum of selected block costs"
        # Determinism: repeated runs are byte-identical.
        _, md2, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", str(budget), "--explain"])
        assert md == md2


# --------------------------------------------------------------------------- #
# B — document/decision coverage
# --------------------------------------------------------------------------- #

def test_directly_changed_doc_satisfies_relevant_docs(tmp_path):
    """B: a documentation file DIRECTLY CHANGED and selected as
    changed-symbol must increase relevant_docs coverage (coverage describes
    WHAT is selected, not only WHY the candidate was generated)."""
    r = _scratch_repo(tmp_path, {
        "src/a.py": "def foo():\n    return 1\n",
        "docs/guide.md": "# Guide\n\nold text\n",
    })
    write_file(r, "docs/guide.md", "# Guide\n\nnew text mentions foo\n")
    commit_all(r, "directly change the doc")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000", "--json"])
    assert rc == 0
    j = json.loads(out)
    sel_paths = {s["path"] for s in j["selected"]}
    assert "docs/guide.md" in sel_paths, f"directly changed doc not selected: {sel_paths}"
    sym_sel = [s for s in j["selected"] if s["path"] == "docs/guide.md"]
    assert sym_sel and sym_sel[0]["reason"] == "changed-symbol", sym_sel
    rd = j["coverage_detail"]["relevant_docs"]
    assert rd["total"] >= 1, j["coverage_detail"]
    assert rd["covered"] >= 1, f"selected doc must satisfy relevant_docs: {j['coverage_detail']}"
    assert "docs/guide.md" not in j["missing_coverage"]["relevant_docs"], j["missing_coverage"]["relevant_docs"]


def test_directly_changed_claim_satisfies_decision_docs(tmp_path):
    """B: a DIRECTLY CHANGED claim/ADR satisfies decision_docs, and one
    candidate contributes to several coverage dimensions at once."""
    r = _scratch_repo(tmp_path, {
        "docs/claims/0001-demo.md": "# Claim: demo\n\nold notes\n",
        "src/a.py": "def foo():\n    return 1\n",
    })
    write_file(r, "docs/claims/0001-demo.md", "# Claim: demo\n\nnew notes\n")
    commit_all(r, "change the claim")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000", "--json"])
    assert rc == 0
    j = json.loads(out)
    sel_paths = {s["path"] for s in j["selected"]}
    assert "docs/claims/0001-demo.md" in sel_paths, f"changed claim not selected: {sel_paths}"
    dd = j["coverage_detail"]["decision_docs"]
    assert dd["total"] >= 1 and dd["covered"] >= 1, f"decision_docs {dd}"
    assert "docs/claims/0001-demo.md" not in j["missing_coverage"]["decision_docs"]
    # Multi-dimension: the same candidate also satisfies relevant_docs,
    # changed_symbols and changed_files.
    assert j["coverage_detail"]["relevant_docs"]["covered"] >= 1
    assert j["coverage_detail"]["changed_files"]["covered"] >= 1
    assert j["coverage_detail"]["changed_symbols"]["covered"] >= 1


# --------------------------------------------------------------------------- #
# C — generic-symbol stale filter
# --------------------------------------------------------------------------- #

def test_project_name_heading_does_not_stale_but_specific_identifier_does(tmp_path):
    """C: a README heading named like the project must NOT stale-warn
    unrelated docs; a specific changed identifier must still warn."""
    r = _scratch_repo(tmp_path, {
        "README.md": "# WidgetOS\n",
        "docs/guide.md": "# Guide\n\nWidgetOS is the project. virtio_pci_flush is a function.\n",
        "docs/manual.md": "# Manual\n\nWidgetOS is mentioned here too.\n",
        "src/kernel.zig": "pub fn virtio_pci_flush() void {\n    // body\n}\n",
    })
    git(r, "remote", "add", "origin", "https://github.com/acme/WidgetOS.git")
    # Change the README heading (the project name) AND the specific identifier.
    write_file(r, "README.md", "# WidgetOS\n\nchanged body\n")
    write_file(r, "src/kernel.zig", "pub fn virtio_pci_flush() void {\n    // changed body\n}\n")
    commit_all(r, "change heading + identifier")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000", "--json"])
    assert rc == 0
    j = json.loads(out)
    stale_syms = {s["symbol"] for s in j["stale"]}
    assert "WidgetOS" not in stale_syms, f"project name must not stale-warn: {stale_syms}"
    assert "virtio_pci_flush" in stale_syms, f"specific identifier must still warn: {stale_syms}"
    # WHY is exposed for debugging/tests.
    filtered = {f["symbol"]: f["reasons"] for f in j["stale_filtered"]}
    assert "WidgetOS" in filtered
    assert any("project-name" in reason for reason in filtered["WidgetOS"]), filtered["WidgetOS"]
    # No avalanche: the stale universe stays tiny (only the specific identifier).
    assert j["coverage_detail"]["stale_warnings"]["total"] <= 3, j["coverage_detail"]


# --------------------------------------------------------------------------- #
# D — shell importance
# --------------------------------------------------------------------------- #

def test_shell_function_outranks_throwaway_variables(tmp_path):
    """D: under a small budget the meaningful shell function wins; the local
    assignment inside the function folds into the function chunk and never
    becomes an independent symbol; throwaway variables never dominate."""
    script = (
        "#!/usr/bin/env bash\n"
        'ROOT="$(pwd)"\n'
        "pass=0\n"
        "fail=0\n"
        'id1="$(echo one)"\n'
        'id2="$(echo two)"\n'
        'id3="$(echo three)"\n'
        "\n"
        "run_tests() {\n"
        '    local tmp="$(mktemp -d)"\n'
        '    echo "running"\n'
        "}\n"
        "\n"
        'echo "$ROOT"\n'
    )
    r = _scratch_repo(tmp_path, {"tools/run.sh": script})
    changed = (
        script
        .replace("pass=0", "pass=1")
        .replace("fail=0", "fail=1")
        .replace('id1="$(echo one)"', 'id1="$(echo uno)"')
        .replace('echo "running"', 'echo "running now"')
    )
    write_file(r, "tools/run.sh", changed)
    commit_all(r, "change function + throwaway vars")
    assert main(["index", str(r)]) == 0
    rc, out, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "2500", "--json"])
    assert rc == 0
    j = json.loads(out)
    # The inner assignment is not an independent symbol — it belongs to run_tests.
    sym_names = {s["name"] for s in j["symbols"]}
    assert "tmp" not in sym_names, f"inner assignment must fold into the function: {sym_names}"
    assert "run_tests" in sym_names
    # The meaningful structural context is selected (mandatory), first in utility.
    sel = j["selected"]
    fn_sel = [s for s in sel if s.get("symbol_kind") == "function" and s.get("language") == "shell"]
    assert fn_sel and fn_sel[0]["origin_symbol"] == "run_tests", sel
    # Throwaway variables never dominate: at most two cheap ones fit after the
    # function, and each is low-scored (never mandatory-class ~15).
    low = [s for s in sel if s.get("symbol_kind") == "constant" and s.get("language") == "shell"]
    assert len(low) <= 2, f"low-value shell assignments dominate selection: {low}"
    for c in low:
        assert c["score"] < fn_sel[0]["score"], f"constant {c} outranks the function"
    # Changed-file coverage is not lost (the function carries the file).
    assert j["coverage_detail"]["changed_files"]["covered"] >= 1


def test_low_value_shell_constants_never_mandatory():
    """D (unit): one-line shell assignments never enter the mandatory pool."""
    from ragshit.review.candidates import Candidate
    from ragshit.review.coverage import CoverageSpec
    from ragshit.review.selection import _is_low_value, _mandatory_pool

    def mk(name, symbol_kind):
        return Candidate(
            cid=f"id-{name}", path="tools/x.sh", start_line=1, end_line=2,
            content=f"{name}=1\n", content_hash="h", kind="symbol",
            structural_name=name, heading=None, language="shell", commit="abc",
            reason="changed-symbol", origin_changed_file="tools/x.sh", origin_symbol=name,
            covers=[f"changed_symbol:{name}", "changed_file:tools/x.sh"],
            token_set=frozenset([name]), cost=400, base_utility=10.0,
            components={}, provenance="commit:abc", original_content=f"{name}=1\n",
            symbol_kind=symbol_kind,
        )
    fn = mk("run_tests", "function")
    var = mk("pass", "constant")
    assert _is_low_value(var) and not _is_low_value(fn)
    spec = CoverageSpec(
        changed_symbols={"run_tests", "pass"},
        changed_files={"tools/x.sh"},
        high_risk_files={"tools/x.sh"},
        related_tests=set(), relevant_docs=set(), decision_docs=set(), stale_warnings=set(),
    )
    mandatory = _mandatory_pool([fn, var], spec)
    ids = {c.cid for c in mandatory}
    assert fn.cid in ids, "the function must be mandatory"
    assert var.cid not in ids, "a low-value shell assignment must NOT be mandatory"


# --------------------------------------------------------------------------- #
# G — language-tagged fences
# --------------------------------------------------------------------------- #

def test_language_tagged_fences(tmp_path):
    """G: code fences carry the candidate language; unknown/plaintext falls
    back to a plain fence; output stays deterministic and balanced."""
    r = _scratch_repo(tmp_path, {
        "a.py": "def foo():\n    return 42\n",
        "tools/x.sh": "#!/usr/bin/env bash\nrun() {\n    echo hi\n}\n",
        "docs/guide.md": "# Guide\n\nSee foo.\n",
        "notes.txt": "plain text\n",
    })
    write_file(r, "a.py", "def foo():\n    return 43\n")
    write_file(r, "tools/x.sh", "#!/usr/bin/env bash\nrun() {\n    echo hi again\n}\n")
    write_file(r, "docs/guide.md", "# Guide\n\nSee foo again.\n")
    commit_all(r, "lang fences")
    assert main(["index", str(r)]) == 0
    rc, md, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000"])
    assert rc == 0
    assert "```python" in md
    assert "```shell" in md
    assert "```markdown" in md
    # Balanced fences
    assert md.count("```") % 2 == 0, "unbalanced code fences"
    # Deterministic
    rc2, md2, _ = run_cli(["review", str(r), "HEAD~1..HEAD", "--budget-chars", "20000"])
    assert md == md2
