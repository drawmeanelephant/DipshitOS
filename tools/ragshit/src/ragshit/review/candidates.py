"""Candidate generation for review packets.

Every candidate retains provenance, cost, coverage keys, and redundancy signals.
Deterministic: sorted inputs, stable ids.
"""
from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from typing import Dict, List, Set, Tuple, Optional

from ..indexing.database import Database
from ..impact.inventory import Inventory
from ..impact.symbols import SymbolMapping
from ..impact.neighborhood import Neighbor
from ..impact.stale import StaleDoc
from ..impact.scoring import FileScore
from ..models import Chunk


def _historical_chunks_for_deleted(
    repo, base_oid: str, path: str
):
    """Parse base revision content for a deleted path; return list of ParsedChunk.

    Deterministic helper shared with impact fallback. Returns [] on any failure.
    """
    if repo is None or not base_oid or not path:
        return [], ""
    import subprocess
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo.root), "show", f"{base_oid}:{path}"],
            capture_output=True, timeout=30,
        )
        if proc.returncode != 0:
            return [], ""
        raw = proc.stdout
        if not raw or b"\x00" in raw[:8192]:
            return [], ""
        text = raw.decode("utf-8", errors="replace")
        from ..discovery.files import detect_kind
        from ..parsing import get_parser
        first_line = text.splitlines()[0] if text else ""
        kind, language = detect_kind(path, first_line)
        result = get_parser(kind, language).parse(text, path)
        return result.chunks, text
    except Exception:
        return [], ""

REASON_WEIGHTS = {
    "changed-symbol": 10.0,
    "changed-chunk": 9.0,
    "high-risk-file": 8.0,
    "hardware-contract": 7.0,
    "test-reference": 6.0,
    "documentation-reference": 5.0,
    "claim-reference": 5.0,
    "decision-reference": 5.0,
    "build-file": 5.0,
    "stale-hint": 4.0,
    "surrounding-context": 3.0,
    "lexical-related": 1.0,
}

# Paths that indicate claim/decision/hardware docs
_CLAIM_PREFIX = "docs/claims/"
_DECISION_PREFIX = "docs/decisions/"
_HARDWARE = "docs/hardware-contract.md"
_BUILD_RE = re.compile(r"(^|/)(Makefile|Justfile|build\\.zig|build\\.zig\\.zon|Cargo\\.toml|pyproject\\.toml)$", re.I)


def _sha(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()[:16]


def _token_set(text: str) -> frozenset:
    # Normalized word set lowercased alphanum tokens
    toks = re.findall(r"[a-z0-9_]+", text.lower())
    return frozenset(toks)


def _rendered_block_len(path: str, start: int, end: int, reason: str, covers: List[str], score: float, content: str, commit: Optional[str], structural_name: Optional[str] = None, provenance: str = "") -> int:
    # Exact cost: mirrors report.md `### path:start-end\nreason:...\n...\n```\ncontent\n```\n\n`
    # Compute header lines as report does
    h = []
    h.append(f"### {path}:{start}-{end}")
    h.append(f"reason: {reason}")
    h.append(f"covers: {', '.join(sorted(set(covers))) if covers else '(none)'}")
    h.append(f"score: {score:.2f}")
    h.append(f"cost: 0 chars")  # placeholder length ~12; actual cost line adds ~15+digits
    h.append(f"provenance: {provenance or commit or '?'}")
    if structural_name:
        h.append(f"symbol: {structural_name}")
    header = "\n".join(h) + "\n\n```\n" + content.rstrip("\n") + "\n```\n\n"
    return len(header)


def _chunk_block_len(path: str, start: int, end: int, reason: str, covers: List[str], score: float, content: str, commit: Optional[str]) -> int:
    return _rendered_block_len(path, start, end, reason, covers, score, content, commit)


@dataclass
class Candidate:
    cid: str
    path: str
    start_line: int
    end_line: int
    content: str
    content_hash: str
    kind: str
    structural_name: Optional[str]
    heading: Optional[str]
    language: str
    commit: Optional[str]
    reason: str
    origin_changed_file: Optional[str]
    origin_symbol: Optional[str]
    covers: List[str]
    token_set: frozenset
    cost: int
    base_utility: float
    components: Dict[str, float]
    provenance: str
    # For truncation bookkeeping
    original_content: str = field(default="")


def _candidate_id(repo_id: str, path: str, start: int, end: int, reason: str, origin: str) -> str:
    return _sha(f"{repo_id}\x00{path}\x00{start}\x00{end}\x00{reason}\x00{origin}")


def build_candidates(
    db: Database,
    repo_id: str,
    inv: Inventory,
    mapping: SymbolMapping,
    neighbors: List[Neighbor],
    stale: List[StaleDoc],
    file_scores: List[FileScore],
    index_head: Optional[str],
    repo=None,
) -> List[Candidate]:
    """Build deterministic candidate pool from impact signals."""
    out: List[Candidate] = []
    seen_keys: Set[Tuple[str, int, int, str]] = set()
    # Map path -> score level
    score_by_path = {fs.path: fs for fs in file_scores}
    changed_paths = {f.path for f in inv.files}
    deleted_paths = {f.path for f in inv.files if f.status.startswith("D")}
    # Symbols per file
    high_risk_paths = {fs.path for fs in file_scores if fs.level in ("critical", "high")}

    # Cache historical parses for deleted paths to avoid repeated git show
    _historical_cache: Dict[str, list] = {}
    def _get_hist(path: str):
        if path in _historical_cache:
            return _historical_cache[path]
        parsed, _ = _historical_chunks_for_deleted(repo, inv.base_oid, path)
        _historical_cache[path] = parsed
        return parsed

    # 1. changed-symbol candidates (mandatory class)
    for sym in sorted(mapping.symbols, key=lambda s: (s.path, s.start_line, s.name)):
        chunks = db.chunks_for_path(repo_id, sym.path)
        chunk = next((c for c in chunks if c.structural_name == sym.name and c.start_line == sym.start_line), None)
        if chunk is None:
            # fallback: any chunk overlapping symbol range
            chunk = next((c for c in chunks if c.start_line <= sym.end_line and c.end_line >= sym.start_line), None)
        historical_provenance = None
        historical_content_hash = None
        if chunk is None and sym.path in deleted_paths:
            # No index chunks (reindexed past deletion) — synthesize from base revision
            hist_chunks = _get_hist(sym.path)
            # Find matching parsed chunk by structural name and line
            pc = next((p for p in hist_chunks if p.structural_name == sym.name and p.start_line == sym.start_line), None)
            if pc is None:
                pc = next((p for p in hist_chunks if p.structural_name == sym.name), None)
            if pc is not None:
                # Synthesize a Chunk-like candidate directly from ParsedChunk
                import hashlib as _hl
                h = _hl.sha256(pc.content.encode()).hexdigest()[:16]
                # Do NOT pretend it came from current index
                prov = f"base:{inv.base_oid[:12]} (historical, not index) path:{sym.path}"
                covers = [f"changed_symbol:{sym.name}", f"changed_file:{sym.path}"]
                if sym.path in high_risk_paths:
                    covers.append(f"high_risk:{sym.path}")
                covers.append(f"symbol_range:{sym.path}:{sym.start_line}-{sym.end_line}")
                fs = score_by_path.get(sym.path)
                file_boost = round(min(5.0, (fs.score / 20.0) if fs else 0), 2)
                base = REASON_WEIGHTS["changed-symbol"] + file_boost
                comps = {"reason": REASON_WEIGHTS["changed-symbol"], "file_priority": file_boost}
                cost = _rendered_block_len(sym.path, pc.start_line, pc.end_line, "changed-symbol", covers, base, pc.content, None, pc.structural_name, prov)
                cid = _candidate_id(repo_id, sym.path, pc.start_line, pc.end_line, "changed-symbol", sym.name)
                key = (sym.path, pc.start_line, pc.end_line, "changed-symbol")
                if key not in seen_keys:
                    seen_keys.add(key)
                    out.append(Candidate(
                        cid=cid, path=sym.path, start_line=pc.start_line, end_line=pc.end_line,
                        content=pc.content, content_hash=h, kind=pc.kind,
                        structural_name=pc.structural_name, heading=pc.heading, language="",
                        commit=None, reason="changed-symbol", origin_changed_file=sym.path, origin_symbol=sym.name,
                        covers=covers, token_set=_token_set(pc.content), cost=cost, base_utility=base,
                        components=comps, provenance=prov,
                        original_content=pc.content,
                    ))
                continue
            else:
                # No parsed chunk for this symbol but file was deleted — synthesize minimal window if file had content
                # (e.g., synthetic file stem case)
                if hist_chunks is None or len(hist_chunks) == 0:
                    # Try to synthesize from raw historical text as a single window
                    _, raw_text = _historical_chunks_for_deleted(repo, inv.base_oid, sym.path)
                    # Avoid double git show: use cached text if available — re-fetch via helper that returns text
                    # For now skip if no chunks
                    pass
                continue
        if chunk is None:
            continue
        key = (chunk.path, chunk.start_line, chunk.end_line, "changed-symbol")
        if key in seen_keys:
            continue
        seen_keys.add(key)
        covers = [f"changed_symbol:{sym.name}", f"changed_file:{sym.path}"]
        if sym.path in high_risk_paths:
            covers.append(f"high_risk:{sym.path}")
        covers.append(f"symbol_range:{sym.path}:{sym.start_line}-{sym.end_line}")
        fs = score_by_path.get(sym.path)
        file_boost = round(min(5.0, (fs.score / 20.0) if fs else 0), 2)
        base = REASON_WEIGHTS["changed-symbol"] + file_boost
        comps = {"reason": REASON_WEIGHTS["changed-symbol"], "file_priority": file_boost}
        cost = _chunk_block_len(chunk.path, chunk.start_line, chunk.end_line, "changed-symbol", covers, base, chunk.content, chunk.commit)
        cid = _candidate_id(repo_id, chunk.path, chunk.start_line, chunk.end_line, "changed-symbol", sym.name)
        out.append(Candidate(
            cid=cid, path=chunk.path, start_line=chunk.start_line, end_line=chunk.end_line,
            content=chunk.content, content_hash=chunk.content_hash, kind=chunk.kind,
            structural_name=chunk.structural_name, heading=chunk.heading, language=chunk.language,
            commit=chunk.commit, reason="changed-symbol", origin_changed_file=sym.path, origin_symbol=sym.name,
            covers=covers, token_set=_token_set(chunk.content), cost=cost, base_utility=base,
            components=comps, provenance=f"commit:{chunk.commit or '?'} index:{index_head[:12] if index_head else '?'}",
            original_content=chunk.content,
        ))

    # 2. changed-chunk / overlapping chunk not already symbol (hunk-aligned)
    for cf in sorted(inv.files, key=lambda f: f.path):
        if cf.status.startswith("D") or not cf.ranges:
            continue
        chunks = db.chunks_for_path(repo_id, cf.path)
        # find chunks overlapping ranges that are not already selected as changed-symbol
        for chunk in sorted(chunks, key=lambda c: (c.start_line, c.chunk_id)):
            overlaps = any(chunk.start_line <= e and chunk.end_line >= s for s, e in cf.ranges)
            if not overlaps:
                continue
            # skip if already covered by a changed-symbol candidate at same path/range
            key = (chunk.path, chunk.start_line, chunk.end_line, "changed-chunk")
            if (chunk.path, chunk.start_line, chunk.end_line, "changed-symbol") in seen_keys:
                continue
            if key in seen_keys:
                continue
            # If chunk has a structural name that is already a changed symbol, skip (already covered)
            if chunk.structural_name and any(s.path == cf.path and s.name == chunk.structural_name for s in mapping.symbols):
                continue
            seen_keys.add(key)
            covers = [f"changed_file:{cf.path}"]
            if cf.path in high_risk_paths:
                covers.append(f"high_risk:{cf.path}")
            if chunk.structural_name:
                covers.append(f"changed_symbol:{chunk.structural_name}")
            fs = score_by_path.get(cf.path)
            file_boost = round(min(5.0, (fs.score / 20.0) if fs else 0), 2)
            base = REASON_WEIGHTS["changed-chunk"] + file_boost
            comps = {"reason": REASON_WEIGHTS["changed-chunk"], "file_priority": file_boost}
            cost = _chunk_block_len(chunk.path, chunk.start_line, chunk.end_line, "changed-chunk", covers, base, chunk.content, chunk.commit)
            cid = _candidate_id(repo_id, chunk.path, chunk.start_line, chunk.end_line, "changed-chunk", cf.path)
            out.append(Candidate(
                cid=cid, path=chunk.path, start_line=chunk.start_line, end_line=chunk.end_line,
                content=chunk.content, content_hash=chunk.content_hash, kind=chunk.kind,
                structural_name=chunk.structural_name, heading=chunk.heading, language=chunk.language,
                commit=chunk.commit, reason="changed-chunk", origin_changed_file=cf.path, origin_symbol=chunk.structural_name,
                covers=covers, token_set=_token_set(chunk.content), cost=cost, base_utility=base,
                components=comps, provenance=f"commit:{chunk.commit or '?'} index:{index_head[:12] if index_head else '?'}",
                original_content=chunk.content,
            ))
            # One per file is enough for changed-chunk unless multiple distinct hunks far apart
            # but we allow up to 2 per file to keep diversity
            count_for_file = sum(1 for c in out if c.path == cf.path and c.reason == "changed-chunk")
            if count_for_file >= 2:
                break

    # 3. surrounding-context: one adjacent symbol per changed file
    for cf in sorted(inv.files, key=lambda f: f.path):
        if cf.status.startswith("D"):
            continue
        chunks = db.chunks_for_path(repo_id, cf.path)
        sym_chunks = [c for c in sorted(chunks, key=lambda c: c.start_line) if c.structural_name]
        # symbols already taken as changed
        changed_sym_names = {s.name for s in mapping.per_file.get(cf.path, [])}
        for c in sym_chunks:
            if c.structural_name in changed_sym_names:
                continue
            key = (c.path, c.start_line, c.end_line, "surrounding-context")
            if key in seen_keys:
                continue
            # Only one surrounding per file
            if any(o.path == cf.path and o.reason == "surrounding-context" for o in out):
                break
            seen_keys.add(key)
            covers = [f"changed_file:{cf.path}", f"surrounding:{c.structural_name}"]
            base = REASON_WEIGHTS["surrounding-context"]
            comps = {"reason": base}
            cost = _chunk_block_len(c.path, c.start_line, c.end_line, "surrounding-context", covers, base, c.content, c.commit)
            cid = _candidate_id(repo_id, c.path, c.start_line, c.end_line, "surrounding-context", c.structural_name or c.path)
            out.append(Candidate(
                cid=cid, path=c.path, start_line=c.start_line, end_line=c.end_line,
                content=c.content, content_hash=c.content_hash, kind=c.kind,
                structural_name=c.structural_name, heading=c.heading, language=c.language,
                commit=c.commit, reason="surrounding-context", origin_changed_file=cf.path, origin_symbol=c.structural_name,
                covers=covers, token_set=_token_set(c.content), cost=cost, base_utility=base,
                components=comps, provenance=f"commit:{c.commit or '?'} index:{index_head[:12] if index_head else '?'}",
                original_content=c.content,
            ))
            break

    # Track hardware-contract / claim / decision explicitly so they surface even without neighbor hit
    def _classify_neighbor_reason(n: Neighbor) -> str:
        if n.reason == "test-reference":
            return "test-reference"
        if n.reason == "documentation-reference":
            if n.path.startswith(_CLAIM_PREFIX):
                return "claim-reference"
            if n.path.startswith(_DECISION_PREFIX):
                return "decision-reference"
            if n.path == _HARDWARE:
                return "hardware-contract"
            return "documentation-reference"
        if n.path.startswith(_CLAIM_PREFIX):
            return "claim-reference"
        if n.path.startswith(_DECISION_PREFIX):
            return "decision-reference"
        if n.path == _HARDWARE:
            return "hardware-contract"
        if n.reason == "direct-symbol":
            return "documentation-reference" if (n.path.startswith("docs/") or n.language == "markdown") else "lexical-related"
        return n.reason

    # 4. neighbors (dedup by path+lines+query)
    for n in sorted(neighbors, key=lambda x: (x.path, x.start_line, x.query)):
        reason = _classify_neighbor_reason(n)
        # But preserve original neighbor reason weight mapping: map correctly
        if reason not in REASON_WEIGHTS:
            reason = n.reason if n.reason in REASON_WEIGHTS else "lexical-related"
        key = (n.path, n.start_line, n.end_line, reason)
        if key in seen_keys:
            # keep the higher-weight reason if duplicate location with different reason
            continue
        seen_keys.add(key)
        # Fetch chunk content for this neighbor if available, else synthesize minimal
        chunks = db.chunks_for_path(repo_id, n.path)
        tgt = next((c for c in chunks if c.start_line == n.start_line and c.end_line == n.end_line), None)
        if tgt is None:
            # pick best chunk by heading overlap
            tgt = next((c for c in chunks if c.structural_name == n.structural_name), None)
            if tgt is None and chunks:
                tgt = min(chunks, key=lambda c: abs(c.start_line - n.start_line))
        if tgt is None:
            continue
        covers = [f"related:{reason}:{n.query}"]
        if reason in ("test-reference",):
            covers.append(f"test:{n.path}")
        elif reason in ("documentation-reference", "claim-reference", "decision-reference", "hardware-contract"):
            covers.append(f"doc:{n.path}")
        # also tag the queried symbol/file
        if n.query in {s.name for s in mapping.symbols}:
            covers.append(f"changed_symbol:{n.query}")
        if n.query in changed_paths:
            covers.append(f"changed_file:{n.query}")
        base = REASON_WEIGHTS.get(reason, 1.0)
        # Tests/docs mentioning changed symbols get small bonus
        bonus = 0
        if reason in ("test-reference", "documentation-reference") and any(c.startswith("changed_symbol:") for c in covers):
            bonus = 1.0
        base += bonus
        comps = {"reason": REASON_WEIGHTS.get(reason, 1.0)}
        if bonus:
            comps["symbol_link"] = bonus
        cost = _chunk_block_len(tgt.path, tgt.start_line, tgt.end_line, reason, covers, base, tgt.content, tgt.commit)
        cid = _candidate_id(repo_id, tgt.path, tgt.start_line, tgt.end_line, reason, n.query)
        out.append(Candidate(
            cid=cid, path=tgt.path, start_line=tgt.start_line, end_line=tgt.end_line,
            content=tgt.content, content_hash=tgt.content_hash, kind=tgt.kind,
            structural_name=tgt.structural_name, heading=tgt.heading, language=tgt.language,
            commit=tgt.commit, reason=reason, origin_changed_file=n.query if n.query in changed_paths else None,
            origin_symbol=n.query if n.query not in changed_paths else None,
            covers=covers, token_set=_token_set(tgt.content), cost=cost, base_utility=base,
            components=comps, provenance=f"commit:{tgt.commit or '?'} index:{index_head[:12] if index_head else '?'} via {n.reason}:{n.query}",
            original_content=tgt.content,
        ))

    # 5. stale hints
    for s in sorted(stale, key=lambda x: (x.path, x.symbol)):
        chunks = db.chunks_for_path(repo_id, s.path)
        tgt = next((c for c in chunks if c.start_line == s.start_line and c.end_line == s.end_line), None)
        if tgt is None:
            tgt = min(chunks, key=lambda c: abs(c.start_line - s.start_line)) if chunks else None
        if tgt is None:
            continue
        key = (tgt.path, tgt.start_line, tgt.end_line, "stale-hint")
        if key in seen_keys:
            continue
        seen_keys.add(key)
        covers = [f"stale:{s.path}:{s.symbol}", f"doc:{s.path}", f"changed_symbol:{s.symbol}"]
        base = REASON_WEIGHTS["stale-hint"]
        comps = {"reason": base}
        cost = _chunk_block_len(tgt.path, tgt.start_line, tgt.end_line, "stale-hint", covers, base, tgt.content, tgt.commit)
        cid = _candidate_id(repo_id, tgt.path, tgt.start_line, tgt.end_line, "stale-hint", s.symbol)
        # avoid duplicate if already has same stale coverage via neighbor
        if any(f"stale:{s.path}:{s.symbol}" in c.covers for c in out):
            continue
        out.append(Candidate(
            cid=cid, path=tgt.path, start_line=tgt.start_line, end_line=tgt.end_line,
            content=tgt.content, content_hash=tgt.content_hash, kind=tgt.kind,
            structural_name=tgt.structural_name, heading=tgt.heading, language=tgt.language,
            commit=tgt.commit, reason="stale-hint", origin_changed_file=None, origin_symbol=s.symbol,
            covers=covers, token_set=_token_set(tgt.content), cost=cost, base_utility=base,
            components=comps, provenance=f"commit:{tgt.commit or '?'} index:{index_head[:12] if index_head else '?'} stale:{s.symbol}",
            original_content=tgt.content,
        ))

    # 6. Ensure one per high-risk file if not already covered (high-risk-file)
    for fs in file_scores:
        if fs.level not in ("critical", "high"):
            continue
        if any(c.path == fs.path and c.reason in ("changed-symbol", "changed-chunk", "high-risk-file") for c in out):
            continue
        chunks = db.chunks_for_path(repo_id, fs.path)
        if not chunks:
            continue
        # pick top structural chunk or overlapping
        picked = None
        cf = next((f for f in inv.files if f.path == fs.path), None)
        if cf and cf.ranges:
            for c in sorted(chunks, key=lambda c: (c.start_line, c.chunk_id)):
                if any(c.start_line <= e and c.end_line >= s for s, e in cf.ranges):
                    picked = c
                    break
        if picked is None:
            picked = sorted(chunks, key=lambda c: (0 if c.structural_name else 1, c.start_line))[0]
        key = (picked.path, picked.start_line, picked.end_line, "high-risk-file")
        if key in seen_keys:
            continue
        seen_keys.add(key)
        covers = [f"high_risk:{fs.path}", f"changed_file:{fs.path}"]
        base = REASON_WEIGHTS["high-risk-file"]
        comps = {"reason": base, "high_risk": fs.score}
        cost = _chunk_block_len(picked.path, picked.start_line, picked.end_line, "high-risk-file", covers, base, picked.content, picked.commit)
        cid = _candidate_id(repo_id, picked.path, picked.start_line, picked.end_line, "high-risk-file", fs.path)
        out.append(Candidate(
            cid=cid, path=picked.path, start_line=picked.start_line, end_line=picked.end_line,
            content=picked.content, content_hash=picked.content_hash, kind=picked.kind,
            structural_name=picked.structural_name, heading=picked.heading, language=picked.language,
            commit=picked.commit, reason="high-risk-file", origin_changed_file=fs.path, origin_symbol=picked.structural_name,
            covers=covers, token_set=_token_set(picked.content), cost=cost, base_utility=base,
            components=comps, provenance=f"commit:{picked.commit or '?'} index:{index_head[:12] if index_head else '?'}",
            original_content=picked.content,
        ))

    # 7. Ensure hardware-contract appears if high-risk or any symbol touches kernel/boot (even without neighbor)
    if _HARDWARE not in {c.path for c in out}:
        # include it only if there's at least one high-risk impl change
        has_impl = any(f.path.startswith(("kernel/", "boot/", "host/")) for f in inv.files)
        if has_impl:
            chunks = db.chunks_for_path(repo_id, _HARDWARE)
            if chunks:
                c = chunks[0]
                key = (c.path, c.start_line, c.end_line, "hardware-contract")
                if key not in seen_keys:
                    covers = ["doc:docs/hardware-contract.md", "hardware-contract"]
                    base = REASON_WEIGHTS["hardware-contract"]
                    comps = {"reason": base}
                    cost = _chunk_block_len(c.path, c.start_line, c.end_line, "hardware-contract", covers, base, c.content, c.commit)
                    cid = _candidate_id(repo_id, c.path, c.start_line, c.end_line, "hardware-contract", "hardware-contract")
                    out.append(Candidate(
                        cid=cid, path=c.path, start_line=c.start_line, end_line=c.end_line,
                        content=c.content, content_hash=c.content_hash, kind=c.kind,
                        structural_name=c.structural_name, heading=c.heading, language=c.language,
                        commit=c.commit, reason="hardware-contract", origin_changed_file=None, origin_symbol=None,
                        covers=covers, token_set=_token_set(c.content), cost=cost, base_utility=base,
                        components=comps, provenance=f"commit:{c.commit or '?'} index:{index_head[:12] if index_head else '?'}",
                        original_content=c.content,
                    ))

    # Deterministic ordering of candidates before selection
    # Recompute cost with accurate provenance length
    for c in out:
        c.cost = _rendered_block_len(c.path, c.start_line, c.end_line, c.reason, c.covers, c.base_utility, c.content, c.commit, c.structural_name, c.provenance)
    out.sort(key=lambda c: (-c.base_utility, c.cost, c.path, c.start_line, c.cid))
    return out
