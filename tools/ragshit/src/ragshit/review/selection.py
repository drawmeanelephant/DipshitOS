"""Budgeted selection: greedy weighted set cover with diversity + redundancy.

Deterministic, no randomness.
"""
from __future__ import annotations

import re

from dataclasses import dataclass
from typing import List, Set, Tuple, Optional

from .candidates import Candidate
from .coverage import CoverageSpec
from .redundancy import redundancy_penalty


@dataclass
class SelectionResult:
    selected: List[Candidate]
    rejected: List[Tuple[Candidate, str]]  # candidate, reason
    budget: int
    actual_chars: int
    truncated: bool


def _is_low_value(c: Candidate) -> bool:
    # Fix D: one-line shell assignments (ROOT=, tmp=, pass=, id1=, ...) are
    # low-value bookkeeping. They never enter the mandatory changed-symbol
    # pool, so they cannot eat mandatory budget ahead of meaningful structural
    # context (the enclosing function/file carries the changed lines). They
    # remain selectable in phase 2 when budget actually remains, so no
    # changed-file coverage is lost.
    return c.symbol_kind == "constant" and c.language == "shell"


def _mandatory_pool(candidates: List[Candidate], spec: CoverageSpec) -> List[Candidate]:
    # Near-mandatory: changed-symbol and one per high-risk file
    mandatory: List[Candidate] = []
    # For each changed symbol, pick its highest utility candidate (smallest cost on tie)
    seen_symbols: Set[str] = set()
    for sym in sorted(spec.changed_symbols):
        best = None
        for c in candidates:
            if c.reason == "changed-symbol" and c.origin_symbol == sym:
                if _is_low_value(c):
                    continue
                if best is None or (c.base_utility > best.base_utility) or (c.base_utility == best.base_utility and c.cost < best.cost):
                    best = c
        if best and best.cid not in {m.cid for m in mandatory}:
            mandatory.append(best)
            seen_symbols.add(sym)
    # One per high-risk file not already covered via mandatory
    covered_files = {c.path for c in mandatory}
    for hf in sorted(spec.high_risk_files):
        if hf in covered_files:
            continue
        best = None
        for c in candidates:
            if c.path == hf and c.reason in ("changed-symbol", "changed-chunk", "high-risk-file"):
                if _is_low_value(c):
                    continue
                if best is None or c.base_utility > best.base_utility:
                    best = c
        if best and best.cid not in {m.cid for m in mandatory}:
            mandatory.append(best)
    # Deterministic order
    mandatory.sort(key=lambda c: (-c.base_utility, c.cost, c.path, c.start_line, c.cid))
    return mandatory


def _effective_utility(c: Candidate, selected: List[Candidate]) -> float:
    penalty, _ = redundancy_penalty(c, selected)
    return c.base_utility * (1.0 - penalty)


def select(candidates: List[Candidate], spec: CoverageSpec, budget: int) -> SelectionResult:
    # Sort candidates deterministic for iteration
    candidates = sorted(candidates, key=lambda c: (-c.base_utility, c.cost, c.path, c.start_line, c.cid))
    mandatory = _mandatory_pool(candidates, spec)
    # Remaining pool = candidates not in mandatory
    mandatory_ids = {m.cid for m in mandatory}
    remaining = [c for c in candidates if c.cid not in mandatory_ids]

    # Reserve budget for mandatory first (greedy mandatory fit)
    selected: List[Candidate] = []
    rejected: List[Tuple[Candidate, str]] = []
    used = 0

    # Phase 1: place mandatory if fits; if not, we will truncate later
    for m in mandatory:
        if used + m.cost <= budget:
            selected.append(m)
            used += m.cost
        else:
            # Keep for truncation phase; mark as rejected temporarily with budget pressure but we'll truncate
            rejected.append((m, f"budget pressure (needs {m.cost} chars, {budget - used} remaining) mandatory deferred"))
    # If mandatory alone exceeds budget, we will truncate down to fit
    mandatory_selected_ids = {c.cid for c in selected}
    deferred_mandatory = [c for c, _ in rejected if c.reason in ("changed-symbol", "high-risk-file", "changed-chunk")]
    # Note: we stored rejected with reason, need to reconstruct list of deferred candidates
    # Instead recompute: mandatory not yet selected
    deferred = [m for m in mandatory if m.cid not in mandatory_selected_ids]

    # If used + sum(deferred costs) > budget, we need truncation path
    deferred_cost = sum(c.cost for c in deferred)
    if deferred_cost > 0 and used + deferred_cost > budget:
        # Collect all mandatory (selected + deferred) for truncation handling
        all_mandatory = selected + deferred
        # Truncate largest mandatory chunks until fit, preserving provenance
        # Do not add any remaining candidates in this branch
        truncated_pool = _truncate_to_budget(all_mandatory, budget)
        # Rejected = remaining + any mandatory that was truncated away (but truncate keeps all, just shorter)
        for c in remaining:
            rejected.append((c, "budget pressure (mandatory content truncated to fit)"))
        # Keep deterministic ordering for selected truncated
        truncated_pool.sort(key=lambda c: (-c.base_utility, c.cost, c.path, c.start_line, c.cid))
        actual = sum(c.cost for c in truncated_pool)
        # Add non-mandatory rejections that were already there (budget pressure)
        return SelectionResult(selected=truncated_pool, rejected=rejected, budget=budget, actual_chars=actual, truncated=True)

    # For deferred that actually fit now (since we checked overflow above, none remain)
    # Actually if we reached here, deferred is empty (all mandatory fit), else we'd have taken truncation path
    # But handle case where some mandatory was deferred due to ordering yet total would still fit with different order:
    # retry greedy mandatory by cost asc
    if deferred:
        # Sort deferred by cost asc to fit more
        deferred.sort(key=lambda c: (c.cost, -c.base_utility, c.path))
        for m in deferred:
            if used + m.cost <= budget:
                # move from rejected to selected
                # remove from rejected
                rejected = [(c, r) for c, r in rejected if c.cid != m.cid]
                selected.append(m)
                used += m.cost
            else:
                # keep rejected
                pass

    # Phase 2: greedy by effective_utility/cost ratio from remaining
    # We must recompute effective utility each iteration due to redundancy
    # Deterministic iteration: at each step pick max ratio among affordable remaining
    pool = list(remaining)  # copy
    # Filter out already rejected budget-pressure from mandatory (keep them rejected)
    while pool:
        best = None
        best_ratio = -1
        best_eff = -1
        for c in pool:
            eff = _effective_utility(c, selected)
            if eff <= 0.2:
                # Very redundant -> skip unless no alternative
                continue
            ratio = eff / max(c.cost, 1)
            # tie break deterministic
            cand_tuple = (ratio, eff, -c.cost, c.path, c.start_line, c.cid)
            best_tuple = (best_ratio, best_eff, -(best.cost if best else 0), best.path if best else "", best.start_line if best else 0, best.cid if best else "")
            if best is None or cand_tuple > best_tuple:
                best = c
                best_ratio = ratio
                best_eff = eff
        if best is None:
            # No non-redundant remains; try one redundant pass with lowest penalty
            # but prefer not to add duplicates
            break
        if used + best.cost <= budget:
            # Check high redundancy threshold: if penalty >0.7 and covers already fully covered, skip
            penalty, reason = redundancy_penalty(best, selected)
            # If high redundancy, mark rejected instead of selected
            if penalty >= 0.8:
                # consider skipped as redundant
                dup_cov = _covers_already(best, selected)
                if dup_cov:
                    rejected.append((best, f"redundant {reason}; coverage already {dup_cov:.0%} duplicated"))
                    pool.remove(best)
                    continue
            selected.append(best)
            used += best.cost
            pool.remove(best)
        else:
            rejected.append((best, f"budget pressure (needs {best.cost} chars, {budget - used} remaining) utility {best.base_utility:.1f}"))
            pool.remove(best)
    # Anything left in pool is rejected for budget pressure or not inspected due to break
    for c in pool:
        if c not in {r[0] for r in rejected} and c not in selected:
            penalty, _ = redundancy_penalty(c, selected)
            if penalty >= 0.7:
                rejected.append((c, "redundant / low effective utility vs selected"))
            else:
                rejected.append((c, "budget pressure (no remaining budget)"))
    # Deterministic ordering of selected/rejected
    selected.sort(key=lambda c: (-c.base_utility, c.cost, c.path, c.start_line, c.cid))
    rejected_sorted = sorted(rejected, key=lambda x: (-x[0].base_utility, x[0].cost, x[0].path, x[0].start_line))
    actual = sum(c.cost for c in selected)
    return SelectionResult(selected=selected, rejected=rejected_sorted, budget=budget, actual_chars=actual, truncated=False)


def _covers_already(c: Candidate, selected: List[Candidate]) -> float:
    # fraction of c.covers already present in selected
    if not c.covers:
        return 1.0
    covered_keys = set()
    for s in selected:
        covered_keys.update(s.covers)
    dup = sum(1 for k in c.covers if k in covered_keys)
    return dup / len(c.covers)


# Context lines around each changed range kept by anchor-aware truncation
# (mirrors git's --unified=2 default; deterministic, not a magic count).
_CTX = 2
# Fallback fill used when a candidate's own changed range is unknown but the
# excerpt must still keep the structural anchor line (see _build_excerpt).
_COMMENT_PREFIXES = ("#", "//", "/*", ";")


def _anchor_line_index(lines: List[str], kind: Optional[str], language: Optional[str],
                       name: Optional[str] = None) -> int:
    """0-based index of the structural identity line (signature / heading /
    function opener). When a structural name is known, the line that DECLARES
    it (word-boundary token, comments/blanks skipped) is preferred: for a
    source chunk whose leading imports or doc comments precede the
    declaration, the first non-comment line is not the symbol's identity —
    keeping it while dropping the signature would lose identity without
    marking the excerpt weak (claim 0176). Falls back to the first
    non-comment, non-blank line, then any non-blank line."""
    is_markdown = kind == "section" or str(language or "").lower() == "markdown"

    def is_comment(s: str) -> bool:
        return not is_markdown and s.startswith(_COMMENT_PREFIXES)

    if name:
        pat = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])")
        for i, ln in enumerate(lines):
            s = ln.strip()
            if not s or is_comment(s):
                continue
            if pat.search(ln):
                return i
    for i, ln in enumerate(lines):
        s = ln.strip()
        if not s:
            continue
        if is_comment(s):
            continue
        return i
    for i, ln in enumerate(lines):
        if ln.strip():
            return i
    return 0


def _clamped_changed_indices(lines: List[str], chunk_start_abs: int, anchor_ranges) -> Set[int]:
    """0-based indices of the ACTUAL changed lines inside the chunk (the
    core payload the candidate is mandatory for). Empty when the candidate
    has no direct changed lines."""
    idx: Set[int] = set()
    n = len(lines)
    for rs, re in anchor_ranges or []:
        lo = max(rs, chunk_start_abs)
        hi = min(re, chunk_start_abs + n - 1)
        if lo > hi:
            continue
        idx.update(range(lo - chunk_start_abs, hi - chunk_start_abs + 1))
    return idx


def _region_line_indices(lines: List[str], chunk_start_abs: int, anchor_ranges) -> Set[int]:
    """0-based indices of the changed-line neighborhoods: each changed range
    clamped to the chunk, expanded by _CTX context lines each side. Empty
    when the candidate has no direct changed lines."""
    idx: Set[int] = set()
    n = len(lines)
    for rs, re in anchor_ranges or []:
        lo = max(rs, chunk_start_abs)
        hi = min(re, chunk_start_abs + n - 1)
        if lo > hi:
            continue
        idx.update(range(max(0, lo - chunk_start_abs - _CTX),
                         min(n - 1, hi - chunk_start_abs + _CTX) + 1))
    return idx


def _render_excerpt(lines: List[str], keep: Set[int]) -> Tuple[str, int]:
    """Render kept line indices in ascending order with exact omission
    markers between gaps and a trailing summary marker. Returns (content,
    omitted_total). Deterministic."""
    total = len(lines)
    if not keep:
        return "", total
    kept = sorted(keep)
    omitted_total = 0
    parts: List[str] = []
    if kept[0] > 0:
        parts.append(f"... [truncated {kept[0]} line(s) omitted]")
        omitted_total += kept[0]
    parts.append(lines[kept[0]])
    prev = kept[0]
    for i in kept[1:]:
        if i == prev + 1:
            parts.append(lines[i])
        else:
            gap = i - prev - 1
            parts.append(f"... [truncated {gap} line(s) omitted]")
            parts.append(lines[i])
            omitted_total += gap
        prev = i
    omitted_total += total - 1 - prev
    content = "\n".join(parts)
    if omitted_total > 0:
        content += (f"\n... [truncated {omitted_total} line(s) omitted -- "
                    f"retained {len(keep)} of {total} line(s)]")
    return content, omitted_total


def _build_excerpt(lines: List[str], anchor: int, region: Set[int], core: Set[int], allowance: int) -> Tuple[str, Set[int], bool]:
    """Deterministic anchor-aware excerpt.

    Priority: structural anchor line, then the ACTUAL changed lines (core),
    then their context neighborhood, then the remaining lines in ascending
    order (so the excerpt reads naturally). Markers are sized exactly
    afterwards by dropping lowest-priority kept lines until the content fits
    the allowance — the anchor and the core changed lines are never dropped,
    so a useful excerpt cannot lose the change it is mandatory for (a
    too-small allowance falls through to a hard slice and weak marking).
    Returns (content, keep, partial_anchor) where partial_anchor means the
    anchor line itself had to be hard-sliced (a lost-identity signal).
    """
    total = len(lines)
    total_chars = sum(len(l) + 1 for l in lines)
    if total_chars <= allowance:
        return "\n".join(lines).rstrip("\n"), set(range(total)), False
    order: List[int] = [anchor]
    order += sorted(core - {anchor})
    order += sorted(region - core - {anchor})
    order += [i for i in range(total) if i not in order]
    keep: Set[int] = set()
    used = 0
    for i in order:
        cost = len(lines[i]) + 1
        if used + cost <= allowance:
            keep.add(i)
            used += cost
    content, omitted = _render_excerpt(lines, keep)
    # Shrink to the exact allowance by dropping lowest-priority kept lines
    # (fill lines first, then context lines; the anchor and the core changed
    # lines are never dropped — if they cannot fit it is hard-sliced below).
    sel_order = [i for i in order if i in keep and i != anchor and i not in core]
    while len(content) > allowance and sel_order:
        i = sel_order.pop()
        if i not in keep:
            continue
        keep.remove(i)
        content, omitted = _render_excerpt(lines, keep)
    partial_anchor = False
    if len(content) > allowance or not keep:
        # The allowance cannot hold even the anchor plus the core changed
        # lines (or the selection kept nothing): hard-slice the anchor to
        # the allowance rather than emit an empty excerpt. The slice is a
        # lost-identity signal; losing the core marks the excerpt weak.
        i = anchor if anchor < len(lines) else (next(iter(keep)) if keep else 0)
        keep = {i}
        line = lines[i]
        tail_v = (f"... [truncated {total - 1} line(s) omitted -- "
                  f"retained 1 of {total} line(s)]")
        tail_c = f"... [truncated {total - 1} line(s) omitted]"
        for tail in (tail_v, tail_c, ""):
            need = len(tail) + 1 if tail else 0
            room = allowance - need
            if room < 1:
                continue
            piece = line[:room].rstrip() or line[:room]
            if len(piece) < len(line):
                partial_anchor = (i == anchor)
            if tail and len(piece) + 1 + len(tail) <= allowance:
                content = piece + "\n" + tail
            else:
                content = piece
            if len(content) <= allowance:
                break
        if len(content) > allowance:
            content = content[:allowance].rstrip()
            partial_anchor = True
    return content, keep, partial_anchor


def _truncate_excerpt_line_aware(c: Candidate, max_content_chars: int) -> Candidate:
    """Deterministic anchor-aware line truncation (claims 9112/3320 C + 0176).

    - Operates on line boundaries, never arbitrary char slices.
    - Retained excerpt line numbers are accurate (start/end = first/last
      retained line); omitted count is exact.
    - Provenance survives (never stripped).
    - Prefers the structural anchor (signature/heading) PLUS the actual
      changed-line neighborhood, so a changed region deep in a large symbol
      stays represented instead of collapsing to a content-free prefix.
    - Sets weak/weak_reason when the excerpt lost its structural identity
      line or its changed-line neighborhood: such an excerpt never counts
      identically to useful coverage (claim 0176).
    - Avoids cutting code fences into invalid structure by truncating inside
      the candidate's own code block fence pair, not across blocks; fences
      are balanced by block rendering, not per-candidate truncation.
    """
    import copy
    import hashlib
    raw = c.original_content if c.original_content else c.content
    lines = raw.splitlines()
    total_lines = len(lines)
    if total_lines == 0:
        nc = copy.copy(c)
        nc.weak = False
        nc.weak_reason = None
        return nc
    total_chars = sum(len(l) + 1 for l in lines)
    if total_chars <= max_content_chars:
        # Fits whole excerpt; no truncation, never weak.
        nc = copy.copy(c)
        nc.weak = False
        nc.weak_reason = None
        return nc
    anchor = _anchor_line_index(lines, c.kind, c.language, c.structural_name or c.origin_symbol)
    core = _clamped_changed_indices(lines, c.start_line, c.anchor_ranges)
    region = _region_line_indices(lines, c.start_line, c.anchor_ranges)
    content, keep, partial_anchor = _build_excerpt(lines, anchor, region, core, max_content_chars)
    omitted = total_lines - len(keep)
    truncated = omitted > 0 or partial_anchor
    # Weak coverage determination (claim 0176): a truncated excerpt is weak
    # when it lost the structural identity line, or when the symbol has a
    # distinct changed region (disjoint from the identity line) that is not
    # represented at all.
    weak = False
    weak_reason = None
    if truncated:
        if partial_anchor or anchor not in keep:
            weak = True
            weak_reason = "excerpt lost the structural identity line"
        elif core and not (core & keep):
            weak = True
            weak_reason = "excerpt lost the changed region (changed-line neighborhood)"
    nc = copy.copy(c)
    nc.content = content
    if keep:
        nc.start_line = c.start_line + min(keep)
        nc.end_line = c.start_line + max(keep)
    nc.weak = weak
    nc.weak_reason = weak_reason
    # Deterministic recompute of cost using same helper as candidates (exact block len)
    from .candidates import _rendered_block_len
    nc.cost = _rendered_block_len(nc.path, nc.start_line, nc.end_line, nc.reason, nc.covers, nc.base_utility, nc.content, nc.commit, nc.structural_name, nc.provenance)
    nc.content_hash = hashlib.sha256(nc.content.encode()).hexdigest()[:16]
    return nc


def _useful_floor_content_len(c: Candidate) -> int:
    """Minimal CONTENT allowance that still yields a useful excerpt: the
    structural anchor line plus a BOUNDED window around the first changed
    line (git --unified=2 context, i.e. 2*_CTX+1 lines). The truncator sizes
    the result exactly and fills any remaining allowance with further
    changed/context lines, so this is a sizing floor for budget distribution
    — it deliberately bounds whole-file rewrites so one massive symbol cannot
    starve the packet (claim 0176). Candidates without direct changed lines
    keep the anchor line."""
    lines = (c.original_content if c.original_content else c.content).splitlines()
    if not lines:
        return 1
    anchor = _anchor_line_index(lines, c.kind, c.language, c.structural_name or c.origin_symbol)
    core = _clamped_changed_indices(lines, c.start_line, c.anchor_ranges)
    if not core:
        # No direct changed lines: the useful floor is the anchor line.
        return sum(len(l) + 1 for l in lines[:anchor + 1])
    first_core = min(core)
    lo = max(0, first_core - _CTX)
    hi = min(len(lines) - 1, first_core + _CTX)
    window_cost = sum(len(l) + 1 for l in lines[lo:hi + 1])
    # Markers are exact: one inter-run marker when the anchor is disjoint
    # from the changed window (either side), plus the trailing summary
    # (~70 chars). Include the anchor line's own cost when it is outside the
    # window, so the floor is genuinely achievable by _build_excerpt.
    anchor_in_window = lo <= anchor <= hi
    anchor_cost = 0 if anchor_in_window else sum(len(l) + 1 for l in lines[anchor:anchor + 1])
    gap_marker = 50 if not anchor_in_window else 0
    return window_cost + anchor_cost + gap_marker + 70


def _truncate_to_budget(candidates: List[Candidate], budget: int) -> List[Candidate]:
    """Truncate candidate contents (anchor-aware, line-exact) to fit budget;
    preserve provenance.

    Two phases so the pressure is DISTRIBUTED instead of nuking the largest
    symbol to a content-free prefix (claim 0176):
      1. shave every candidate down to its useful floor (structural anchor +
         changed region) — with a normal budget every mandatory symbol then
         stays decision-useful;
      2. only if still over budget, shave the largest below its floor
         (weak fragments), then drop lowest-utility candidates as the
         genuine last resort.
    """
    import copy
    cands = sorted(candidates, key=lambda c: (-c.cost, c.path, c.start_line, c.cid))
    total = sum(c.cost for c in cands)
    if total <= budget:
        return cands
    truncated = [copy.copy(c) for c in cands]
    # Phase 1: shave every candidate to its useful floor.
    for i, c in enumerate(truncated):
        floor = _useful_floor_content_len(c)
        if len(c.content) > floor:
            trimmed = _truncate_excerpt_line_aware(c, floor)
            if len(trimmed.content) < len(c.content):
                truncated[i] = trimmed
    # Phase 2: still over budget — shave the largest below its floor.
    guard = 0
    while sum(c.cost for c in truncated) > budget and guard < 60:
        guard += 1
        excess = sum(c.cost for c in truncated) - budget
        largest = max(truncated, key=lambda c: c.cost)
        target_content_len = max(1, len(largest.content) - excess - 8)
        trimmed = _truncate_excerpt_line_aware(largest, target_content_len)
        if len(trimmed.content) >= len(largest.content):
            # Already a minimal hard-sliced fragment: move to the next largest.
            remaining = [t for t in truncated if t.cid != largest.cid]
            if not remaining:
                break
            largest = max(remaining, key=lambda c: c.cost)
            target_content_len = max(1, len(largest.content) - excess - 8)
            trimmed = _truncate_excerpt_line_aware(largest, target_content_len)
            if len(trimmed.content) >= len(largest.content):
                break
        for i, t in enumerate(truncated):
            if t.cid == trimmed.cid:
                truncated[i] = trimmed
                break
    # Phase 3 (genuine last resort): drop the LOWEST-utility mandatory
    # candidate (ties drop the highest cost, freeing the most budget).
    truncated.sort(key=lambda c: (c.base_utility, -c.cost, c.path, c.start_line, c.cid))
    while sum(c.cost for c in truncated) > budget and len(truncated) > 1:
        truncated.pop(0)
    if sum(c.cost for c in truncated) > budget and truncated:
        # Must fit at least one candidate: hard anchor-aware trim to the
        # allowance (may produce a weak fragment rather than an empty block).
        c = truncated[0]
        from .candidates import _rendered_block_len
        overhead_est = _rendered_block_len(c.path, c.start_line, c.start_line, c.reason, c.covers, c.base_utility, "", c.commit, c.structural_name, c.provenance)
        allow_content = max(16, budget - overhead_est)
        trimmed = _truncate_excerpt_line_aware(c, allow_content)
        truncated[0] = trimmed
    return truncated
