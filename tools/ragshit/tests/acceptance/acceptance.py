#!/usr/bin/env python3
"""DipshitOS acceptance verification for Ragshit.

Runs the seven milestone acceptance queries against a local DipshitOS
checkout and checks that the expected files appear in the top-N results.
Expectations live only here — never in the core retrieval engine.

Usage:
    python tests/acceptance/acceptance.py /path/to/DipshitOS [--top 10] [--ragshit PATH]

Exit code 0 when every query surfaces its expected paths.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]  # .../ragshit/tests/acceptance -> ragshit/

EXPECTATIONS = [
    {
        # The m1 prompt contains the phrase verbatim; ADR 0002 records the
        # ExitBootServices decision. These are the two direct sources.
        "query": "ExitBootServices retry behavior",
        "expected": ["m1-kernel-handoff-prompt", "decisions/0002-kernel-handoff"],
    },
    {
        "query": "kernel handoff x3",
        "expected": ["decisions/0002-kernel-handoff", "hardware-contract", "roadmap.md"],
    },
    {
        "query": "KERNEL.TXT corruption root cause",
        "expected": ["decisions/0002-kernel-handoff", "roadmap.md"],
    },
    {
        "query": "Apple Virtualization serial console",
        "expected": ["hardware-contract", "vm-runner"],
    },
    {
        "query": "observed versus inferred hardware assumptions",
        "expected": ["hardware-contract", "AGENTS"],
    },
    {
        "query": "milestone two non-goals",
        "expected": ["roadmap.md", "architecture.md"],
    },
    {
        # Coupling note: hardware-contract stays in the top-N only because
        # the DipshitOS repo's .ragshitignore excludes tools/ragshit/ from
        # the OS index (the tool's README/sources contain this query string
        # as an example and would crowd it out). If that exclusion is
        # removed or the directory renamed, re-check this expectation.
        "query": "ExitBootServices memory ownership",
        "expected": ["decisions/0002-kernel-handoff", "hardware-contract"],
    },
]


def run_ragshit(ragshit: str, repo: str, *args: str, timeout: int = 120) -> subprocess.CompletedProcess:
    """Run `ragshit <command> <repo> <rest...>` (repo comes right after the
    subcommand, matching the CLI's PATH-first convention)."""
    env = dict(os.environ)
    env["PYTHONPATH"] = str(ROOT / "src")
    argv = list(args)
    cmd = [sys.executable, "-m", "ragshit", argv[0], repo] + argv[1:]
    if ragshit:
        cmd = [str(ragshit), argv[0], repo] + argv[1:]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", help="path to a local DipshitOS checkout")
    parser.add_argument("--top", type=int, default=10, help="check the top-N results")
    parser.add_argument("--ragshit", default="", help="path to the ragshit executable (default: python -m ragshit)")
    args = parser.parse_args(argv)

    repo = Path(args.repo).resolve()
    if not (repo / ".git").exists():
        print(f"acceptance: not a git repository: {repo}", file=sys.stderr)
        return 2

    proc = run_ragshit(args.ragshit, str(repo), "index")
    if proc.returncode != 0:
        print(f"acceptance: ragshit index failed:\n{proc.stdout}\n{proc.stderr}", file=sys.stderr)
        return 1

    failures = 0
    print(f"Ragshit acceptance — {repo}")
    print(f"checking top {args.top} results per query\n")
    for expectation in EXPECTATIONS:
        query = expectation["query"]
        proc = run_ragshit(args.ragshit, str(repo), "query", query,
                           "--limit", str(args.top), "--format", "jsonl")
        if proc.returncode != 0:
            print(f"[FAIL] {query!r}: query failed: {proc.stderr.strip()}")
            failures += 1
            continue
        paths = []
        for line in proc.stdout.splitlines():
            try:
                obj = json.loads(line)
                paths.append(obj.get("path", ""))
            except json.JSONDecodeError:
                continue
        missing = [e for e in expectation["expected"] if not any(e in p for p in paths)]
        top = ", ".join(paths[:3]) or "(no results)"
        if missing:
            failures += 1
            print(f"[FAIL] {query!r}")
            print(f"  expected: {expectation['expected']}")
            print(f"  missing:  {missing}")
            print(f"  top:      {top}")
        else:
            print(f"[PASS] {query!r}")
            print(f"  top:      {top}")

    print()
    if failures:
        print(f"acceptance: {failures}/{len(EXPECTATIONS)} query set(s) FAILED")
        return 1
    print(f"acceptance: all {len(EXPECTATIONS)} query sets passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
