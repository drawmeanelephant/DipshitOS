# Claim: SB6 — perf payoff vs WMS9 baselines (M33 seam B, phase 4)

- **Owner:** buffy (`agent/buffy/m33-sb6-perf-payoff`)
- **Prompt / plan:** `docs/march-m33-seam-b-pixel-ownership.md` (SB6 card, issue #693), `artifacts/wms9-fill-reduction.md` (the WMS9 baseline)
- **Scope:** M33 SB6 (phase 4 - payoff/perf). MEASURE seam B against the WMS9 baselines on the dynamic + static apps: fill-SVC counts, composite cost, and copy volume for a migrated desktop vs the pre-seam-B path — host measurement + live VZ numbers in the same gate, written to `artifacts/m33-sb6-perf-payoff.md`.
- **Gate:** documented before/after on the WMS9 dynamic + static apps — fill-SVC counts, composite cost, and copy volume (host measurement + live VZ numbers in the same gate).
- **Depends on:** SB5 landed (claim 7397, PR #715) - compose-N + scanout grant + the migrated-window skip.
- **Touches:** kernel/src/driving_award.zig kernel/src/monitor.zig docs/claims/6864-m33-sb6-perf-payoff.md docs/logs/agent-buffy-m33-sb6-perf-payoff.md tools/verify-live-sb6-perf-payoff.sh docs/archive/gate-inventory-detail.md build.zig image/make-image.sh user/src/sb6_old.zig user/src/sb6_new.zig user/src/sb6_wm.zig artifacts/m33-sb6-perf-payoff.md docs/march-m33-seam-b-pixel-ownership.md
- **Heartbeat:** 2026-08-31
- **Status:** 🔄

## Plan

1. **Observability for the composite-cost leg.** Add two monotonic counters to
   `driving_award`: `user_blits` (a `.user` window actually blitted by
   paint_scene — the pre-seam-B cost) and `migrated_skips` (a surface-backed
   window skipped while the WM owns the user layer — the seam-B saving);
   expose both in `dui` (`blits=`/`skips=`). Fill-SVC counts already exist
   (the `syscalls` per-slot counters: 13 = sys_win_fill, 46 =
   sys_win_fill_batch); composite/present counts already exist (`dui`
   presents=, `wm` present_count).
2. **Live gate apps.** SB6OLD.BIN (the pre-seam-B control, unmigrated):
   opens a window and renders a static frame + 8 dynamic redraws with
   `sys_win_fill` (slot 13) — counting its own fills. SB6NEW.BIN (seam B):
   the SAME frame rendered with plain stores into a bound shared surface
   (zero fill syscalls) + the same redraws. SB6WM.BIN: registers, binds the
   scanout, compose-N per notification (counts composes + copied bytes),
   REQUEST_PRESENT per compose.
3. **The gate captures before/after.** One headless VZ boot (--screen):
   exec SB6OLD -> `syscalls` snapshot A -> exec SB6WM + SB6NEW -> `syscalls`
   snapshot B -> `dui` + `wm`. The script diffs the slot counters
   (before = A slot-13 = OLD's fills; after = B - A = NEW's fills = 0),
   reads blits/skips/presents/bytes, computes the copy volume (documented
   geometry arithmetic), and writes `artifacts/m33-sb6-perf-payoff.md`.
4. **Host tests.** The counters move on the blit vs skip paths; the marker
   strings are pinned.
5. **Docs.** Tracker SB6 row -> done; claim/log.

## Result

_Pending._
