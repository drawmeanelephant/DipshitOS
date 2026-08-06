"""Source parsing heuristics."""

from __future__ import annotations

from ragshit.parsing.source import SourceParser


def _names(text, language):
    result = SourceParser(language).parse(text)
    return [c.structural_name for c in result.chunks if c.kind == "symbol"]


def test_zig_symbols():
    text = (
        "const std = @import(\"std\");\n"
        "pub const BootInfo = struct {\n"
        "    base: u64,\n"
        "};\n"
        "pub fn handoff(info: *BootInfo) u64 {\n"
        "    return 0;\n"
        "}\n"
    )
    names = _names(text, "zig")
    assert "BootInfo" in names
    assert "handoff" in names


def test_python_symbols():
    text = "def convert(path):\n    return path\n\nclass Converter:\n    pass\n"
    names = _names(text, "python")
    assert names == ["convert", "Converter"]


def test_c_function():
    text = "static void write_serial(char c)\n{\n    (void)c;\n}\n"
    names = _names(text, "c")
    assert "write_serial" in names


def test_shell_function():
    text = "build_image() {\n    echo hi\n}\n\nVERSION=1\n"
    names = _names(text, "shell")
    assert "build_image" in names
    assert "VERSION" in names


def test_toml_sections():
    text = "[index]\ndatabase = \"x\"\n\n[retrieval]\nlimit = 20\n"
    names = _names(text, "toml")
    assert "index" in names and "retrieval" in names


def test_fallback_windows_when_no_structure():
    text = "\n".join(f"random {i} contents" for i in range(300))
    result = SourceParser("zig").parse(text)
    assert result.chunks and result.chunks[0].kind == "window"
    assert result.chunks[0].confidence == 0.5


def test_whole_file_document_when_small_and_unstructured():
    text = "x = 1\ny = 2\n"
    result = SourceParser("zig").parse(text)
    assert result.chunks[0].kind == "document"
    assert result.chunks[0].confidence == 0.6


def test_leading_comments_attached():
    text = "// Kernel stub\n// handoff milestone\npub fn handoff() u64 {\n    return 0;\n}\n"
    result = SourceParser("zig").parse(text)
    chunk = result.chunks[0]
    assert chunk.start_line == 1
    assert chunk.content.startswith("// Kernel stub")


def test_line_ranges_never_split():
    text = "pub fn a() {\n    x();\n}\n\npub fn b() {\n    y();\n}\n"
    result = SourceParser("zig").parse(text)
    lines = text.splitlines()
    for chunk in result.chunks:
        assert "\n".join(lines[chunk.start_line - 1:chunk.end_line]) == chunk.content
