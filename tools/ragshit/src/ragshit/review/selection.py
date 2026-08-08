"""Budgeted selection: greedy weighted set cover with diversity + redundancy.

Deterministic, no randomness.
"""
from __future__ import annotations

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


def _mandatory_pool(candidates: List[Candidate], spec: CoverageSpec) -> List[Candidate]:
    # Near-mandatory: changed-symbol and one per high-risk file
    mandatory: List[Candidate] = []
    # For each changed symbol, pick its highest utility candidate (smallest cost on tie)
    seen_symbols: Set[str] = set()
    for sym in sorted(spec.changed_symbols):
        best = None
        for c in candidates:
            if c.reason == "changed-symbol" and c.origin_symbol == sym:
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


def _truncate_excerpt_line_aware(c: Candidate, max_content_chars: int) -> Candidate:
    """Deterministic line-aware truncation (Fix C).

    - Operates on line boundaries, not arbitrary char slices.
    - Retained excerpt line numbers are accurate; omitted count is exact.
    - Provenance survives (never stripped).
    - Marker claims exact omitted lines (no estimates like len//40).
    - Prefers retaining the changed region: keeps the start of the excerpt.
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
        return c
    # max_content_chars must accommodate marker line(s)
    marker_template_omitted = "... [truncated {omitted} line(s) omitted]"
    # Reserve ~50 chars for marker worst-case digits
    reserve = 48
    keep_chars_limit = max(1, max_content_chars - reserve)
    kept_lines = []
    kept_chars = 0
    omitted = 0
    for ln in lines:
        add = len(ln) + 1  # newline
        if kept_chars + add > keep_chars_limit and kept_lines:
            break
        if kept_chars + add > keep_chars_limit and not kept_lines and total_lines > 1:
            # Even first line too long: hard-slice that single line deterministically
            ln = ln[: max(1, keep_chars_limit - 12)].rstrip() + "…"
            kept_lines.append(ln)
            kept_chars += len(ln) + 1
            break
        kept_lines.append(ln)
        kept_chars += add
    omitted = total_lines - len(kept_lines)
    if omitted <= 0:
        # Fits whole excerpt; no marker needed
        new_content = raw
        new_lines = total_lines
    else:
        marker = f"\n... [truncated {omitted} line(s) omitted -- retained {len(kept_lines)} of {total_lines} line(s)]"
        new_content = "\n".join(kept_lines).rstrip("\n") + marker
        new_lines = len(kept_lines)
    # Update line range to reflect retained excerpt (accurate per C)
    nc = copy.copy(c)
    nc.content = new_content
    nc.end_line = c.start_line + max(0, new_lines - 1)
    # Deterministic recompute of cost using same helper as candidates (exact block len)
    from .candidates import _rendered_block_len
    nc.cost = _rendered_block_len(nc.path, nc.start_line, nc.end_line, nc.reason, nc.covers, nc.base_utility, nc.content, nc.commit, nc.structural_name, nc.provenance)
    nc.content_hash = hashlib.sha256(nc.content.encode()).hexdigest()[:16]
    return nc


def _truncate_to_budget(candidates: List[Candidate], budget: int) -> List[Candidate]:
    """Truncate candidate contents (line-aware) to fit budget; preserve provenance."""
    import copy
    cands = sorted(candidates, key=lambda c: (-c.cost, c.path, c.start_line, c.cid))
    total = sum(c.cost for c in cands)
    if total <= budget:
        return cands
    truncated = [copy.copy(c) for c in cands]
    # Iterative: shave from largest by exact char excess, but truncation itself is line-aware
    guard = 0
    while sum(c.cost for c in truncated) > budget and guard < 40:
        guard += 1
        excess = sum(c.cost for c in truncated) - budget
        largest = max(truncated, key=lambda c: c.cost)
        if len(largest.content) <= 24:
            break
        # Target content length = current content len - excess - small margin; converted to line truncation
        target_content_len = max(24, len(largest.content) - excess - 12)
        trimmed = _truncate_excerpt_line_aware(largest, target_content_len)
        if len(trimmed.content) >= len(largest.content):
            # Could not shrink further via line trimming (single line case)
            # Fall back to single-line hard slice inside the excerpt
            trimmed.content = largest.content[:max(24, target_content_len)].rstrip() + "\n... [truncated to fit budget]"
            trimmed.cost = len(trimmed.content) + 80  # overhead fallback (will be recomputed if needed)
            from .candidates import _rendered_block_len
            trimmed.cost = _rendered_block_len(trimmed.path, trimmed.start_line, trimmed.end_line, trimmed.reason, trimmed.covers, trimmed.base_utility, trimmed.content, trimmed.commit, trimmed.structural_name, trimmed.provenance)
        # Replace in place
        idx = truncated.index(largest)
        truncated[idx] = trimmed
        if guard > 30 and sum(c.cost for c in truncated) > budget:
            break
    # If still over, drop smallest utility until fits (keep at least one)
    truncated.sort(key=lambda c: (-c.base_utility, c.cost, c.path))
    while sum(c.cost for c in truncated) > budget and len(truncated) > 1:
        truncated.pop()
    if sum(c.cost for c in truncated) > budget:
        c = truncated[0]
        # Must fit at least one candidate: hard line-aware trim to allowance
        from .candidates import _rendered_block_len
        overhead_est = _rendered_block_len(c.path, c.start_line, c.start_line, c.reason, c.covers, c.base_utility, "", c.commit, c.structural_name, c.provenance)
        allow_content = max(16, budget - overhead_est + len("".rstrip()))
        trimmed = _truncate_excerpt_line_aware(c, allow_content)
        if len(trimmed.content) + overhead_est > budget:
            trimmed.content = trimmed.content[: max(16, allow_content - 24)].rstrip() + "\n... [truncated to fit budget]"
            trimmed.cost = _rendered_block_len(trimmed.path, trimmed.start_line, trimmed.end_line, trimmed.reason, trimmed.covers, trimmed.base_utility, trimmed.content, trimmed.commit, trimmed.structural_name, trimmed.provenance)
        truncated[0] = trimmed
    return truncated
