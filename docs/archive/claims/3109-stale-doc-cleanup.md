# Claim: Stale-doc cleanup — replace old blocker snapshots with pointers to docs/status.md

- **Owner:** buffy (`freebuff/stale-doc-cleanup`)
- **Prompt / plan:** inline — see Notes
- **Scope:** docs only (README, roadmap, architecture, testing, hardware-contract,
  march-m15, plus claims/logs as needed for the before/after report). NO code
  changes, NO edit to `docs/status.md`.
- **Depends on:** hardware findings already on `main` (claims 0009/0010/0013/0015/0017/0018/0020/0021)
- **Status:** ✅ done 2026-08-08 — stale blocker snapshots removed/corrected across README, roadmap, architecture, testing, hardware-contract, march-m15; before/after stale-phrase report in `artifacts/stale-doc-report.txt` (26 → 0 hits); link check clean; `docs/status.md` untouched

## Notes

`docs/status.md` is the canonical, always-current status. Several other docs
accumulated snapshots of old blocker descriptions ("device discovery is
next", "no usable serial device in declared MMIO windows" as the whole
blocker, pre-claim-0010 M2 death-site descriptions, old M1.5 progress
percentages, "monitor not implemented", "machine controls fake", step-20
language that reads as milestone-closed). Goal: reduce stale duplication —
classify each non-status document's content:

1. timeless architecture/design/history → keep;
2. current gate status → replace with a short pointer to `docs/status.md`;
3. historical result → retain only if clearly labeled with date/context;
4. stale or contradictory statement → remove or correct.

Do NOT turn README/architecture/roadmap/testing into mirrors of status.md.
Prefer sentences like "Current VZ gate state: see docs/status.md."

Deliverable: grep/link-based stale-phrase check before/after, saved as a
report under `docs/` or `artifacts/` (gitignored) — the before/after diff is
the evidence. No milestone-status duplication added anywhere.
