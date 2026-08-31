# Log — agent/buffy/m33-sb6-perf-payoff

## 2026-08-31 — claim 6864 opened (SB6: perf payoff vs WMS9 baselines)

Phase-4 payoff card on `agent/buffy/m33-sb6-perf-payoff` off `origin/main`
(SB5 merged, PR #715). The card's "measured, not asserted" requirement:
documented before/after on the WMS9 dynamic + static apps — fill-SVC counts,
composite cost, and copy volume for a migrated desktop vs the pre-seam-B path,
with host measurement + live VZ numbers in the same gate
(artifacts/m33-sb6-perf-payoff.md).

Design: SB6OLD.BIN (pre-seam-B control, unmigrated, slot-13 fills) and
SB6NEW.BIN (seam B, plain stores, zero fills) render the SAME frame; the WM
compose-N counts composes + bytes. New kernel observables: user_blits /
migrated_skips counters in driving_award (+ dui blits=/skips=). The gate
snapshots `syscalls` (slot 13/46), `dui` (presents, blits, skips, last=),
`wm` (present_count) and diffs before vs after.
