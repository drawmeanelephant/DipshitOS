"""Real-repository dogfood assertions for `ragshit review` (fix F).

Runs `ragshit review` against the DipshitOS checkout that CONTAINS this
test (auto-detected via `git rev-parse --show-toplevel`), so the suite
regression-guards the exact classes of defects this hardening pass fixed:

  A accounting: the rendered markdown length, the "Actual size" header line,
    the "budget utilization" body line, JSON actual_size and
    selection_summary.actual_chars all agree.
  B coverage: a selected doc-like path is never reported missing from
    relevant_docs — coverage reflects WHAT is selected, not only WHY.
  C stale filter: the project name never produces stale-hint avalanches and
    the stale universe stays small.
  D shell importance: low-value shell assignments never dominate selection
    (they are low-scored when selected, never mandatory-class).

The assertions are invariants, not exact numbers: they must hold on any
reasonably sized DipshitOS range without depending on specific claim
numbers or fragile history. Skipped outside a DipshitOS checkout (e.g. a
bare ragshit checkout elsewhere).
"""
from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys

import pytest

HERE = pathlib.Path(__file__).resolve().parent  # tools/ragshit/tests
ROOT = HERE.parent.parent.parent  # repo root (DipshitOS)


def _dipshitos_root() -> pathlib.Path | None:
    try:
        proc = subprocess.run(
            ["git", "-C", str(HERE), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=20,
        )
        if proc.returncode != 0:
            return None
        root = pathlib.Path(proc.stdout.strip())
        if (root / "docs" / "claims").is_dir() and (root / "kernel").is_dir() \
                and (root / "tools" / "ragshit").is_dir() and (root / "AGENTS.md").is_file():
            return root
    except Exception:
        return None
    return None


DIPSHITOS = _dipshitos_root()


def _run(args) -> tuple[int, str, str]:
    import io, contextlib
    out = io.StringIO(); err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        from ragshit.cli import main
        rc = main(args)
    return rc, out.getvalue(), err.getvalue()


def _pick_range(repo: pathlib.Path) -> str:
    """HEAD~5..HEAD when the history is deep enough, else HEAD~1..HEAD."""
    for candidate in ("HEAD~5..HEAD", "HEAD~1..HEAD"):
        proc = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "-q", "--verify", candidate.split("..")[0]],
            capture_output=True, timeout=20,
        )
        if proc.returncode == 0:
            return candidate
    return "HEAD~1..HEAD"


@pytest.mark.skipif(DIPSHITOS is None, reason="not running inside a DipshitOS checkout")
def test_review_dogfood_invariants():
    repo = DIPSHITOS
    from ragshit.cli import main
    # Fresh deterministic index of the current checkout.
    assert main(["index", str(repo)]) == 0
    rng = _pick_range(repo)
    budget = 40000

    rc, md, _ = _run(["review", str(repo), rng, "--budget-chars", str(budget), "--explain"])
    assert rc == 0, md[:500]
    rcj, jtxt, _ = _run(["review", str(repo), rng, "--budget-chars", str(budget), "--explain", "--json"])
    assert rcj == 0, jtxt[:500]
    j = json.loads(jtxt)

    # --- A: accounting ---------------------------------------------------- #
    assert len(md) <= budget, f"packet {len(md)} > budget {budget}"
    m_actual = re.search(r"^Actual size: (\d+) chars$", md, re.M)
    m_util = re.search(r"^- budget utilization: (\d+) / \d+ \(([0-9.]+)%\)$", md, re.M)
    assert m_actual and m_util, "Actual size / budget utilization lines missing"
    assert int(m_actual.group(1)) == len(md), "Actual size header != len(md)"
    assert int(m_util.group(1)) == len(md), "budget utilization body line != len(md)"
    assert abs(float(m_util.group(2)) - round(len(md) / budget * 100, 1)) < 0.11
    assert j["actual_size"] == len(md), "json actual_size != len(md)"
    assert j["selection_summary"]["actual_chars"] == len(md), "json actual_chars != len(md)"
    assert isinstance(j["selection_summary"]["candidate_cost_chars"], int)
    # envelope must not be silently relied on at a normal budget
    assert j["envelope_fallback_used"] is False

    # --- B: USEFULLY selected docs are never "missing" from relevant_docs -- #
    # (claim 0176: a weak/truncated doc excerpt is explicitly NOT useful
    # coverage, so it is exempt from this invariant — it is listed as weak.)
    sel_paths = {s["path"] for s in j["selected"] if not s.get("weak")}
    doc_paths = {p for p in sel_paths if p.startswith("docs/") or p.endswith((".md", ".markdown"))}
    missing_relevant = set(j["missing_coverage"].get("relevant_docs", []))
    overlap = doc_paths & missing_relevant
    assert not overlap, f"selected doc(s) reported missing from relevant_docs: {sorted(overlap)}"
    if doc_paths and j["coverage_detail"]["relevant_docs"]["total"] > 0:
        assert j["coverage_detail"]["relevant_docs"]["covered"] >= 1, j["coverage_detail"]

    # --- E: weak/truncated coverage never counts as useful (claim 0176) ---- #
    # A structurally large changed symbol must not be reported as usefully
    # covered merely because a one-line prefix survived truncation: a
    # truncated excerpt is either explicitly weak (never counted as covered,
    # listed in missing_coverage) or keeps structural identity AND overlaps
    # the changed-line neighborhood.
    for s in j["selected"]:
        if s.get("weak"):
            syms = [c.split(":", 1)[1] for c in s["covers"] if c.startswith("changed_symbol:")]
            for sym in syms:
                assert sym in j["missing_coverage"]["changed_symbols"], \
                    f"weak {sym} still counted as covered: {s['path']}:{s['lines']}"
            continue
        if s["reason"] != "changed-symbol" or "truncated" not in s["content"]:
            continue
        # useful truncated excerpt: structural identity retained. Prefer a
        # word-boundary match, but fall back to verbatim containment for
        # symbols that end in punctuation (e.g. a markdown heading ending in
        # ')' has no trailing word boundary). A document symbol is named by
        # its own file path, which never appears inside the file's content —
        # its identity is the retained opening line (guaranteed by non-weak)
        # plus the path in the packet metadata, so it is exempt.
        name = s.get("origin_symbol") or s.get("structural_name")
        if name and name != s["path"]:
            assert (
                re.search(rf"\b{re.escape(name)}\b", s["content"])
                or re.search(re.escape(name), s["content"])
            ), f"truncated non-weak changed-symbol excerpt lost identity: {s['path']}:{s['lines']}"
        # and the retained line range overlaps the changed region
        anchors = s.get("anchor_ranges") or []
        if anchors:
            rs, re_ = s["lines"]
            assert any(rs <= er and re_ >= sr for sr, er in anchors), \
                f"truncated non-weak excerpt misses changed region: {s['path']}:{s['lines']} anchors={anchors}"
    # No one-line-`virtio_pci_init` shape: a truncated excerpt of a large
    # symbol that does NOT represent its changed region must be weak, and a
    # packet with weak symbols must not report ordinary complete coverage.
    weak_syms = set()
    for s in j["selected"]:
        if s["reason"] != "changed-symbol":
            continue
        rng = next((c for c in s["covers"] if c.startswith("symbol_range:")), None)
        if not rng:
            continue
        m = re.search(r"symbol_range:.*:(\d+)-(\d+)$", rng)
        if not m:
            continue
        st, en = int(m.group(1)), int(m.group(2))
        retained = s["lines"][1] - s["lines"][0] + 1
        anchors = s.get("anchor_ranges") or []
        overlaps_region = any(s["lines"][0] <= er and s["lines"][1] >= sr for sr, er in anchors)
        if en - st + 1 >= 40 and retained <= 1 and "truncated" in s["content"] and not overlaps_region:
            assert s.get("weak"), \
                f"large symbol {s['path']}:{st}-{en} truncated to {retained} line(s), not weak, still counted covered"
        if s.get("weak"):
            weak_syms.update(c.split(":", 1)[1] for c in s["covers"] if c.startswith("changed_symbol:"))
    if weak_syms:
        cov = j["coverage_detail"]["changed_symbols"]
        assert cov["covered"] < cov["total"], \
            f"100% changed-symbol coverage claimed while weak symbols exist: {weak_syms}"

    # --- C: no project-name stale avalanche --------------------------------- #
    stale_syms = {s["symbol"] for s in j["stale"]}
    # project name derived the same conservative way the filter uses
    proc = subprocess.run(
        ["git", "-C", str(repo), "remote", "get-url", "origin"],
        capture_output=True, text=True, timeout=20,
    )
    if proc.returncode == 0 and proc.stdout.strip():
        m = re.search(r"([^/]+?)(?:\.git)?$", proc.stdout.strip().replace("\\", "/").rstrip("/"))
        project = (m.group(1) if m else None) or ""
    else:
        project = repo.name
    assert project.lower() not in {s.lower() for s in stale_syms}, \
        f"project name {project!r} created stale hints: {stale_syms}"
    assert len(j["stale"]) <= 12, f"stale universe exploded: {len(j['stale'])} hints"

    # --- D: low-value shell assignments never dominate ---------------------- #
    low = [s for s in j["selected"] if s.get("symbol_kind") == "constant" and s.get("language") == "shell"]
    for c in low:
        # mandatory-class changed-symbol weight is ~15; a penalized constant is <= 9
        assert c["score"] < 10, f"low-value shell assignment scored as mandatory: {c}"
    assert len(low) <= 4, f"low-value shell assignments dominate selection: {low}"
