"""Git tracked-file discovery and ignore behavior."""

from __future__ import annotations

from conftest import commit_all, git, write_file

from ragshit.discovery.files import discover_files
from ragshit.discovery.ignore import IgnoreRules
from ragshit.git.repository import GitRepository


def _paths(repo, config, root=None):
    repo_obj = GitRepository.from_path(repo if root is None else root)
    rules = IgnoreRules(repo_obj.root)
    files, skipped = discover_files(repo_obj, config.index, rules)
    return {f.rel_path for f in files}, skipped


def test_tracked_files_discovered(sample_repo, config):
    paths, _ = _paths(sample_repo, config)
    assert "docs/decisions/0001-demo.md" in paths
    assert "kernel/src/main.zig" in paths
    assert "tools/convert.py" in paths
    assert "notes.txt" in paths
    assert ".gitignore" in paths


def test_untracked_excluded_by_default(sample_repo, config):
    write_file(sample_repo, "extra.md", "# extra\n")
    paths, _ = _paths(sample_repo, config)
    assert "extra.md" not in paths


def test_untracked_included_when_enabled(sample_repo, config):
    write_file(sample_repo, "extra.md", "# extra\n")
    config.index.include_untracked = True
    paths, _ = _paths(sample_repo, config)
    assert "extra.md" in paths


def test_gitignore_respected_for_untracked(sample_repo, config):
    write_file(sample_repo, "build/out.txt", "ignored\n")
    config.index.include_untracked = True
    paths, _ = _paths(sample_repo, config)
    assert "build/out.txt" not in paths  # build/ is gitignored


def test_tracked_override_gitignore(sample_repo, config):
    from conftest import git
    write_file(sample_repo, "keep.tmp", "tracked despite *.tmp\n")
    git(sample_repo, "add", "-f", "keep.tmp")  # *.tmp is gitignored; force-add
    commit_all(sample_repo, "add tmp")
    paths, _ = _paths(sample_repo, config)
    assert "keep.tmp" in paths  # tracked files override .gitignore


def test_ragshitignore_excludes_tracked(sample_repo, config):
    write_file(sample_repo, ".ragshitignore", "kernel/\n")
    paths, _ = _paths(sample_repo, config)
    assert "kernel/src/main.zig" not in paths  # .ragshitignore always wins


def test_binary_files_skipped(sample_repo, config):
    write_file(sample_repo, "blob.dat", "A\x00B\x00C")
    commit_all(sample_repo, "add binary")
    paths, _ = _paths(sample_repo, config)
    assert "blob.dat" not in paths


def test_empty_tracked_file_indexed(sample_repo, config):
    # Empty tracked files (e.g. .gitkeep) must still be recorded so
    # doctor's freshness check sees every tracked file indexed.
    write_file(sample_repo, "empty.txt", "")
    commit_all(sample_repo, "add empty file")
    paths, _ = _paths(sample_repo, config)
    assert "empty.txt" in paths


def test_size_limit(sample_repo, config):
    write_file(sample_repo, "huge.md", "x" * 5000)
    commit_all(sample_repo, "add huge")
    config.index.max_file_bytes = 1000
    paths, _ = _paths(sample_repo, config)
    assert "huge.md" not in paths


def test_symlinks_skipped_by_default(sample_repo, config):
    (sample_repo / "link.md").symlink_to("notes.txt")
    commit_all(sample_repo, "add symlink")
    paths, _ = _paths(sample_repo, config)
    assert "link.md" not in paths


def test_gitignored_patterns_basename_and_dir(sample_repo, config):
    write_file(sample_repo, "sub/out.tmp", "x\n")
    write_file(sample_repo, "sub/deep/out.tmp", "x\n")
    config.index.include_untracked = True
    paths, _ = _paths(sample_repo, config)
    assert "sub/out.tmp" not in paths
    assert "sub/deep/out.tmp" not in paths


def test_negation_rule(sample_repo, config):
    write_file(sample_repo, ".ragshitignore", "*.log\n!important.log\n")
    write_file(sample_repo, "a.log", "ignored\n")
    write_file(sample_repo, "important.log", "kept\n")
    config.index.include_untracked = True
    paths, _ = _paths(sample_repo, config)
    assert "a.log" not in paths
    assert "important.log" in paths
