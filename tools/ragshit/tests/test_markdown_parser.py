"""Markdown heading chunking."""

from __future__ import annotations

from ragshit.parsing.markdown import MarkdownParser

PARSER = MarkdownParser()


def test_heading_chunks_and_ranges():
    text = "# A\n\nbody a\n\n## B\n\nbody b\n"
    result = PARSER.parse(text)
    sections = [c for c in result.chunks if c.kind == "section"]
    assert len(sections) == 2
    assert sections[0].structural_name == "A"
    assert sections[0].start_line == 1
    assert sections[0].end_line == 4
    assert sections[1].structural_name == "B"
    assert sections[1].heading == "A > B"  # ancestry preserved


def test_heading_ancestry_chain():
    # Leaf body is large enough to stop the small-section merge, so the
    # three-level ancestry is preserved as separate chunks.
    leaf_body = "\n".join(f"detail {i}" for i in range(14))
    text = f"# Top\n\n## Mid\n\n### Leaf\n\n{leaf_body}\n"
    result = PARSER.parse(text)
    leaves = [c for c in result.chunks if c.kind == "section" and c.structural_name == "Leaf"]
    assert leaves and leaves[0].heading == "Top > Mid > Leaf"


def test_code_fence_not_split():
    text = "# Head\n\n```zig\n# not a heading\n```\n\ntail\n"
    result = PARSER.parse(text)
    sections = [c for c in result.chunks if c.kind == "section"]
    assert len(sections) == 1
    assert "```zig" in sections[0].content
    assert "# not a heading" in sections[0].content


def test_document_top_chunk():
    text = "preamble line\n\n# Head\n\nbody\n"
    result = PARSER.parse(text)
    kinds = [c.kind for c in result.chunks]
    assert "document" in kinds
    doc = next(c for c in result.chunks if c.kind == "document")
    assert doc.start_line == 1
    assert doc.end_line == 2


def test_no_headings_whole_document():
    text = "just text\nmore text\n"
    result = PARSER.parse(text)
    assert len(result.chunks) == 1
    assert result.chunks[0].kind == "document"


def test_no_headings_long_document_windows():
    text = "\n".join(f"line {i}" for i in range(300))
    result = PARSER.parse(text)
    assert len(result.chunks) > 1
    assert all(c.kind == "window" for c in result.chunks)


def test_small_sections_merged():
    text = "# Top\n\n## A\n\nshort a\n\n## B\n\nshort b\n"
    result = PARSER.parse(text)
    sections = [c for c in result.chunks if c.kind == "section"]
    # A and B (tiny, with a tiny parent) merge into Top: 1 section total,
    # and no duplicate children are emitted.
    assert len(sections) == 1
    assert sections[0].heading == "Top"
    assert "short a" in sections[0].content and "short b" in sections[0].content


def test_adr_sections_stay_granular():
    # Decision sections with real bodies must NOT merge into their parent.
    d1_body = "\n".join(f"The kernel keeps using Boot Services ({i})." for i in range(12))
    d2_body = "\n".join(f"Register arguments on entry ({i})." for i in range(12))
    text = (
        "# ADR 0001: Something\n\nStatus: accepted\n\n## Context\n\n"
        "A handoff contract.\n\n## Decisions\n\n### D1. No ExitBootServices\n\n"
        + d1_body + "\n\n### D2. Handoff ABI\n\n" + d2_body +
        "\n\n## Evidence\n\nObserved on the host.\n"
    )
    result = PARSER.parse(text)
    sections = [c for c in result.chunks if c.kind == "section"]
    leaves = [c.structural_name for c in sections]
    assert "D1. No ExitBootServices" in leaves
    assert "D2. Handoff ABI" in leaves
    d1 = next(c for c in sections if c.structural_name == "D1. No ExitBootServices")
    assert d1.heading == "ADR 0001: Something > Decisions > D1. No ExitBootServices"


def test_line_ranges_match_content():
    text = "# A\n\n## B\n\nx\n\n## C\n\ny\n"
    result = PARSER.parse(text)
    for chunk in result.chunks:
        lines = text.splitlines()
        expected = "\n".join(lines[chunk.start_line - 1:chunk.end_line])
        assert chunk.content == expected  # never splits a line
