"""Ragshit command-line interface.

Commands:
    init     create .ragshit.toml and .ragshitignore
    index    build/refresh the local SQLite index
    status   show repository and index state
    query    retrieve chunks for a query
    bundle   assemble a deterministic context bundle
    diff     retrieval-oriented summary of a git range
    inspect  show indexed metadata for one file
    impact   Git-aware change-impact reviewer context
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


def cmd_impact(args: argparse.Namespace) -> int:
        import time
        from .impact.inventory import build_inventory
        from .impact.symbols import map_symbols
        from .impact.neighborhood import collect_neighborhood
        from .impact.stale import detect_stale
        from .impact.scoring import score_files
        from .impact.report import build_report, report_to_json, report_to_markdown
        from .rendering.markdown import render_source_block
        repo = resolve_repo(args.path)
        config = load_config(repo)
        t0 = time.monotonic()
        inv = build_inventory(repo, args.range)
        db = open_db(repo, config)
        try:
            mapping = map_symbols(db, repo.repo_id, inv, repo=repo)
            symbols_by_path = {k: [s.name for s in v] for k, v in mapping.per_file.items()}
            all_symbols = {s.name for s in mapping.symbols}
            changed_paths = {f.path for f in inv.files}
            neighbors, per_path = collect_neighborhood(db, repo.repo_id, changed_paths, symbols_by_path, all_symbols)
            stale = detect_stale(db, repo.repo_id, changed_paths, all_symbols)
            file_scores = score_files(inv, mapping, per_path)
            refs = db.get_git_refs(repo.repo_id)
            index_head = refs["head"] if refs is not None else None
            # Real elapsed for humans goes to stderr; deterministic JSON/markdown is always 0
            real_timing_ms = int((time.monotonic() - t0) * 1000)
            timing_ms = 0
            # Loud mismatch warning when index HEAD != range head
            index_stale = False
            index_warning = None
            if index_head and inv.head_oid and index_head != inv.head_oid:
                index_stale = True
                index_warning = f"index HEAD {index_head[:12]} != range head {inv.head_oid[:12]} ({inv.head}); symbols/excerpts reflect indexed HEAD, not the requested range"
            elif index_head is None:
                index_stale = True
                index_warning = "index has no git HEAD recorded; impact context may not match requested range"
            report = build_report(str(repo.root), repo.repo_id, inv, mapping, neighbors, file_scores, stale, timing_ms, index_head, index_stale=index_stale, index_warning=index_warning)
            # Always surface real timing + stale warning to stderr (does not affect determinism)
            print(f"impact: {real_timing_ms} ms -- index HEAD {index_head[:12] if index_head else '(unknown)'}; range head {inv.head_oid[:12]}", file=sys.stderr)
            if index_warning:
                print(f"impact: WARNING: {index_warning}", file=sys.stderr)
            if args.json:
                text_out = report_to_json(report)
                if args.bundle:
                    import json as _j
                    d = _j.loads(text_out)
                    d["note"] = "bundle requested with --json not embedded; use --bundle without --json for packet"
                    text_out = _j.dumps(d, indent=2, sort_keys=True) + "\n"
                if args.output and args.output != "-":
                    Path(args.output).write_text(text_out, encoding="utf-8")
                    print(f"impact: wrote {len(text_out)} characters to {args.output}", file=sys.stderr)
                else:
                    sys.stdout.write(text_out)
                return 0
            bundle_text = None
            if args.bundle:
                parts = []
                top = file_scores[:3] if file_scores else []
                for fs in top:
                    chunks = db.chunks_for_path(repo.repo_id, fs.path)
                    ranges = next((f.ranges for f in inv.files if f.path == fs.path), [])
                    picked = []
                    for c in chunks:
                        is_sym = any(s.name == (c.structural_name or "") for s in mapping.per_file.get(fs.path, []))
                        overlaps = any(c.start_line <= e and c.end_line >= s for s, e in ranges) if ranges else False
                        if is_sym or overlaps:
                            picked.append(c)
                    picked = sorted(picked, key=lambda c: (c.start_line, c.chunk_id))[:3]
                    for c in picked:
                        from .models import RetrievedChunk
                        rc = RetrievedChunk(chunk=c, score=fs.score, components=fs.components)
                        parts.append(render_source_block(rc, explain=False))
                for n in neighbors[:2]:
                    chunks = db.chunks_for_path(repo.repo_id, n.path)
                    tgt = next((c for c in chunks if c.start_line == n.start_line and c.end_line == n.end_line), None)
                    if tgt is None and chunks:
                        tgt = chunks[0]
                    if tgt is not None:
                        from .models import RetrievedChunk
                        rc = RetrievedChunk(chunk=tgt, score=0.0, components={n.reason: 1.0})
                        parts.append(render_source_block(rc, explain=False))
                if parts:
                    bundle_text = "\n\n".join(parts)
                else:
                    bundle_text = "(no index excerpts available for this range)"
            md = report_to_markdown(report, bundle=bundle_text)
            if args.bundle and args.bundle != "-":
                Path(args.bundle).write_text(md, encoding="utf-8")
                print(f"impact: wrote {len(md)} characters to {args.bundle}", file=sys.stderr)
                sys.stdout.write(md)
            elif args.bundle == "-":
                sys.stdout.write(md)
            else:
                sys.stdout.write(md)
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

    p = sub.add_parser("impact", help="Git-aware change-impact reviewer context")
    add_path(p)
    p.add_argument("range", help="git range, e.g. HEAD~5..HEAD or main..HEAD")
    p.add_argument("--json", action="store_true", help="machine-readable JSON output")
    p.add_argument("--bundle", default=None, help="write a review packet to FILE (or '-' for stdout)")
    p.add_argument("--output", default=None, help="JSON output file (alternative to stdout)")
    p.set_defaults(func=cmd_impact)

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
