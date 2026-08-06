"""Ragshit command-line interface.

Commands:
    init     create .ragshit.toml and .ragshitignore
    index    build/refresh the local SQLite index
    status   show repository and index state
    query    retrieve chunks for a query
    bundle   assemble a deterministic context bundle
    diff     retrieval-oriented summary of a git range
    inspect  show indexed metadata for one file
    doctor   verify repository, index, and configuration

Every command exits non-zero on failure; errors are printed to stderr.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Optional

from . import __version__
from .config import RagshitConfig, resolve_database_path, write_default_config
from .discovery.ignore import IgnoreRules
from .doctor import run_doctor
from .errors import DatabaseError, RagshitError
from .git.diff import analyze_diff, diff_summary
from .git.repository import GitRepository
from .git.status import git_state
from .indexing.database import Database
from .indexing.indexer import Indexer
from .rendering import jsonl as jsonl_render
from .rendering.bundle import build_bundle, render_bundle_markdown
from .rendering.markdown import render_query_markdown
from .retrieval.query import run_query


# ---------------------------------------------------------------------- #
# helpers
# ---------------------------------------------------------------------- #
def resolve_repo(path_arg: str) -> GitRepository:
    return GitRepository.from_path(Path(path_arg or "."))


def load_config(repo: GitRepository) -> RagshitConfig:
    return RagshitConfig.from_file(repo.root)


def open_db(repo: GitRepository, config: RagshitConfig, require_index: bool = True) -> Database:
    if require_index and not resolve_database_path(repo.root, config).exists():
        raise DatabaseError(
            f"no index found; run 'ragshit index' in {repo.root} first"
        )
    return Database.open(repo.root, config)


def clamp_limit(value: Optional[int], config: RagshitConfig) -> int:
    if value is None:
        return config.retrieval.default_limit
    return max(1, min(value, config.retrieval.maximum_limit))


# ---------------------------------------------------------------------- #
# commands
# ---------------------------------------------------------------------- #
def cmd_init(args: argparse.Namespace) -> int:
    repo = resolve_repo(args.path)
    write_default_config(repo.root)
    requested = Path(args.path or ".").resolve()
    if requested != repo.root:
        print(f"ragshit init: note: '{args.path}' is inside the repository; "
              f"configuration is per-repository and was written at the root")
    print(f"ragshit init: wrote {repo.root / '.ragshit.toml'}")
    print(f"ragshit init: wrote {repo.root / '.ragshitignore'}")
    print("next: run 'ragshit index' to build the index")
    return 0


def cmd_index(args: argparse.Namespace) -> int:
    repo = resolve_repo(args.path)
    config = load_config(repo)
    db = Database.open(repo.root, config)
    rules = IgnoreRules(repo.root)
    try:
        stats = Indexer(db, repo, config, rules).run()
    except RagshitError:
        raise
    except Exception as exc:
        # Indexer.run already rolls back the pre-commit transaction before
        # re-raising; the index is never left half-updated.
        raise DatabaseError(f"indexing failed (transaction rolled back): {exc}") from exc
    finally:
        db.close()
    print(f"indexed {repo.root}")
    print(f"  files scanned:   {stats.files_scanned}")
    print(f"  files added:     {stats.files_added}")
    print(f"  files updated:   {stats.files_updated}")
    print(f"  files unchanged: {stats.files_unchanged}")
    print(f"  files removed:   {stats.files_removed}")
    print(f"  files skipped:   {stats.files_skipped}")
    print(f"  chunks added:    {stats.chunks_added}")
    print(f"  elapsed:         {stats.elapsed_ms} ms")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    repo = resolve_repo(args.path)
    config = load_config(repo)
    db = open_db(repo, config)
    try:
        state = git_state(repo)
        refs = db.get_git_refs(repo.repo_id)
        run = db.latest_run(repo.repo_id)
        print(f"repository: {repo.root}")
        print(f"branch:     {repo.branch or '(detached)'}"
              f"{' (detached)' if repo.detached else ''}")
        print(f"HEAD:       {repo.head or '(unborn)'}")
        print(f"index:      {db.count_files(repo.repo_id)} files, "
              f"{db.count_chunks(repo.repo_id)} chunks")
        if run is not None:
            print(f"last run:   {run['finished_at']} [{run['status']}] "
                  f"{run['elapsed_ms']} ms")
        if refs is not None:
            fresh = refs["head"] == repo.head
            print(f"freshness:  {'current' if fresh else 'STALE'} "
                  f"(indexed HEAD {refs['head'] or '(unborn)'})")
        print(f"FTS5:       {'available (BM25)' if db.fts_available else 'unavailable (LIKE fallback)'}")
        print(f"working tree: {state.dirty_count} dirty file(s)")
        return 0
    finally:
        db.close()


def cmd_query(args: argparse.Namespace) -> int:
    repo = resolve_repo(args.path)
    config = load_config(repo)
    db = open_db(repo, config)
    try:
        limit = clamp_limit(args.limit, config)
        results, _ = run_query(db, repo, config.retrieval, args.query, limit)
        if args.format == "jsonl":
            sys.stdout.write(jsonl_render.render_query_jsonl(results, args.explain))
        else:
            print(render_query_markdown(results, args.explain, args.query))
        return 0
    finally:
        db.close()


def cmd_bundle(args: argparse.Namespace) -> int:
    repo = resolve_repo(args.path)
    config = load_config(repo)
    db = open_db(repo, config)
    try:
        limit = clamp_limit(args.limit, config)
        diff = diff_summary(repo, args.diff) if args.diff else None
        bundle = build_bundle(db, repo, config, args.query, limit, diff)
        if args.format == "jsonl":
            text = jsonl_render.render_bundle_jsonl(bundle)
        else:
            text = render_bundle_markdown(bundle)
        if args.output and args.output != "-":
            Path(args.output).write_text(text, encoding="utf-8")
            print(f"bundle: wrote {len(text)} characters to {args.output}", file=sys.stderr)
            print(f"bundle: {len(bundle.sources)} source(s), "
                  f"{len(bundle.omissions)} omitted", file=sys.stderr)
        else:
            print(text, end="")
        return 0
    finally:
        db.close()


def cmd_diff(args: argparse.Namespace) -> int:
    repo = resolve_repo(args.path)
    config = load_config(repo)
    db = open_db(repo, config)
    try:
        summary = diff_summary(repo, args.range)
        analysis = analyze_diff(db, repo, summary, args.limit)
        out = [f"# Diff summary: {summary.range_spec}", ""]
        out.append(f"## Commits ({len(summary.commits)})")
        for c in summary.commits:
            out.append(f"- {c.short} {c.subject} ({c.author})")
        out.append("")
        out.append(f"## Changed files ({len(summary.files)})")
        for f in summary.files:
            ranges = ", ".join(f"{a}-{b}" for a, b in f.ranges)
            out.append(f"- {f.status} {f.path}" + (f" (lines {ranges})" if ranges else " (no new lines)"))
        out.append("")
        out.append("## Relevant architecture documents (heuristic)")
        for d in analysis["decisions"]:
            out.append(f"- {d['path']} (lines {d['lines'][0]}-{d['lines'][1]})")
        out.append("")
        out.append("## Likely affected symbols (heuristic)")
        for s in analysis["symbols"]:
            out.append(f"- {s['symbol']} in {s['path']} (lines {s['lines'][0]}-{s['lines'][1]})")
        out.append("")
        out.append("## Nearby tests (heuristic)")
        for t in analysis["tests"]:
            out.append(f"- {t}")
        out.append("")
        out.append("## Nearby evidence artifacts (heuristic)")
        for e in analysis["evidence"]:
            out.append(f"- {e}")
        out.append("")
        if summary.empty:
            out.insert(1, f"No commits or file changes in range {summary.range_spec}.")
        print("\n".join(out))
        return 0
    finally:
        db.close()


def cmd_inspect(args: argparse.Namespace) -> int:
    repo = resolve_repo(args.path)
    config = load_config(repo)
    db = open_db(repo, config)
    try:
        rel = Path(args.file)
        if rel.is_absolute():
            try:
                rel = rel.relative_to(repo.root)
            except ValueError as exc:
                raise DatabaseError(f"file is outside the repository: {args.file}") from exc
        rel_str = rel.as_posix()
        rec = db.file_record(repo.repo_id, rel_str)
        if rec is None:
            raise DatabaseError(f"'{rel_str}' is not in the index; run 'ragshit index'")
        chunks = db.chunks_for_path(repo.repo_id, rel_str)
        print(f"path:     {rel_str}")
        print(f"kind:     {rec.kind} (language: {rec.language})")
        print(f"size:     {rec.byte_size} bytes, {rec.line_count} lines")
        print(f"hash:     sha256:{rec.content_hash[:16]}...")
        print(f"tracked:  {'yes' if rec.tracked else 'no'}")
        print(f"indexed:  {rec.indexed_at}")
        if rec.last_commit:
            print(f"last commit: {rec.last_commit}")
        try:
            current = (repo.root / rel_str).read_bytes()
            import hashlib
            digest = hashlib.sha256(current).hexdigest()
            fresh = digest == rec.content_hash
        except OSError:
            fresh = False
        print(f"fresh:    {'yes (content matches working tree)' if fresh else 'STALE (working tree differs)'}")
        parser = rec.language if rec.kind == "source" else rec.kind
        confidence = max((c.confidence for c in chunks), default=0.0)
        print(f"parser:   {parser} (confidence {confidence:.2f})")
        print(f"chunks:   {len(chunks)}")
        for c in chunks:
            name = c.structural_name or c.heading or ""
            conf = f" conf={c.confidence:.2f}" if c.confidence else ""
            print(f"  [{c.start_line}-{c.end_line}] {c.kind}{conf}: {name}")
        return 0
    finally:
        db.close()


def cmd_doctor(args: argparse.Namespace) -> int:
    repo = resolve_repo(args.path)
    config = load_config(repo)
    checks, ok = run_doctor(repo.root, config)
    print(f"ragshit doctor: {repo.root}")
    for check in checks:
        mark = "[OK]  " if check.ok else "[FAIL]"
        if check.severity == "warning":
            mark = "[WARN]"
        print(f"  {mark} {check.name}: {check.message}")
    failed = [c for c in checks if not c.ok and c.severity == "required"]
    if failed:
        print(f"doctor: FAILED ({len(failed)} required check(s) failed)")
        return 1
    print("doctor: all required checks passed")
    return 0


# ---------------------------------------------------------------------- #
# argument parsing
# ---------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ragshit",
        description="Local, Git-aware repository context and retrieval engine.",
    )
    parser.add_argument("--version", action="version", version=f"ragshit {__version__}")
    sub = parser.add_subparsers(dest="command", metavar="COMMAND", required=True)

    def add_path(p):
        p.add_argument("path", nargs="?", default=".", help="path to a directory inside the repository")

    p = sub.add_parser("init", help="create .ragshit.toml and .ragshitignore")
    add_path(p)
    p.set_defaults(func=cmd_init)

    p = sub.add_parser("index", help="build or refresh the local index")
    add_path(p)
    p.set_defaults(func=cmd_index)

    p = sub.add_parser("status", help="show repository and index state")
    add_path(p)
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("query", help="retrieve chunks for a query")
    add_path(p)
    p.add_argument("query", help="query text (words, \"phrases\", path:/kind:/symbol:/changed: filters)")
    p.add_argument("--limit", type=int, default=None, help="maximum results (default from config)")
    p.add_argument("--format", choices=["markdown", "jsonl"], default="markdown")
    p.add_argument("--explain", action="store_true", help="show per-signal score breakdown")
    p.set_defaults(func=cmd_query)

    p = sub.add_parser("bundle", help="assemble a deterministic context bundle")
    add_path(p)
    p.add_argument("query", help="retrieval request that defines the bundle")
    p.add_argument("--limit", type=int, default=None, help="candidate limit (default from config)")
    p.add_argument("--format", choices=["markdown", "jsonl"], default="markdown")
    p.add_argument("--output", default=None, help="output file ('-' for stdout)")
    p.add_argument("--diff", default=None, help="git range to include, e.g. main..HEAD")
    p.set_defaults(func=cmd_bundle)

    p = sub.add_parser("diff", help="retrieval-oriented summary of a git range")
    add_path(p)
    p.add_argument("range", help="git range, e.g. main..HEAD or HEAD~3..HEAD")
    p.add_argument("--limit", type=int, default=10, help="max items per heuristic category")
    p.set_defaults(func=cmd_diff)

    p = sub.add_parser("inspect", help="show indexed metadata for one file")
    add_path(p)
    p.add_argument("file", help="repository-relative path of the file")
    p.set_defaults(func=cmd_inspect)

    p = sub.add_parser("doctor", help="verify repository, index, and configuration")
    add_path(p)
    p.set_defaults(func=cmd_doctor)

    return parser


def main(argv: Optional[list] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except RagshitError as exc:
        print(f"ragshit: error: {exc}", file=sys.stderr)
        return exc.exit_code
    except KeyboardInterrupt:
        print("ragshit: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
