"""VirelaiOS acceptance, wired into pytest.

Skipped unless the RAGSHIT_ACCEPTANCE_REPO environment variable points at
a local VirelaiOS checkout:

    RAGSHIT_ACCEPTANCE_REPO=/path/to/DipshitOS python -m pytest
"""

from __future__ import annotations

import os

import pytest

from tests.acceptance.acceptance import EXPECTATIONS, main as run_acceptance

REPO = os.environ.get("RAGSHIT_ACCEPTANCE_REPO")


@pytest.mark.skipif(not REPO, reason="set RAGSHIT_ACCEPTANCE_REPO to run VirelaiOS acceptance")
def test_virelaios_acceptance():
    assert run_acceptance([REPO]) == 0


def test_expectations_are_path_fragments_not_baked_elsewhere():
    """Acceptance expectations (VirelaiOS-specific paths) must not leak into
    the core engine. Full path fragments are compared, not basenames, so
    generic words like 'roadmap' remain legal in the ranking vocabulary."""
    import ragshit.retrieval.query as query_mod
    import ragshit.retrieval.ranking as ranking_mod
    source = open(query_mod.__file__).read() + open(ranking_mod.__file__).read()
    assert "drawmeanelephant" not in source
    for expectation in EXPECTATIONS:
        for frag in expectation["expected"]:
            assert frag not in source
