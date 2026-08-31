# Claim: SB6 — perf payoff vs WMS9 baselines (M33 seam B, phase 4)

- **Owner:** buffy (`agent/buffy/m33-sb6-perf-payoff`)
- **Prompt / plan:** `docs/march-m33-seam-b-pixel-ownership.md` (SB6 card, issue #693), `artifacts/wms9-fill-reduction.md` (the WMS9 baseline)
- **Scope:** M33 SB6 (phase 4 - payoff/perf). MEASURE seam B against the WMS9 baselines on the dynamic + static apps: fill-SVC counts, composite cost, and copy volume for a migrated desktop vs the pre-seam-B path — host measurement + live VZ numbers in the same gate, written to `artifacts/m33-sb6-perf-payoff.md`.
- **Gate:** documented before/after on the WMS9 dynamic + static apps — fill-SVC counts, composite cost, and copy volume (host measurement + live VZ numbers in the same gate).
- **Depends on:** SB5 landed (claim 7397, PR #715) - compose-N + scanout grant + the migrated-window skip.
- **Touches:** kernel/src/driving_award.zig kernel/src/monitor.zig docs/claims/6864-m33-sb6-perf-payoff.md docs/logs/agent-buffy-m33-sb6-perf-payoff.md tools/verify-live-sb6-perf-payoff.sh docs/archive/gate-inventory-detail.md build.zig image/make-image.sh user/src/sb6_old.zig user/src/sb6_new.zig user/src/sb6_wm.zig artifacts/m33-sb6-perf-payoff.md docs/march-m33-seam-b-pixel-ownership.md
- **Heartbeat:** 2026-08-31
- **Status:** ✅

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

**DONE 2026-08-31 — the seam-B payoff is measured, not asserted.** ONE headless
VZ boot, SAME 8x8-grid frame (static + 8 dynamic redraws), two paths:

- **Before (SB6OLD.BIN, pre-seam-B control):** 576 `sys_win_fill` (slot 13)
  SVCs + 9 `sys_win_present` (slot 14) SVCs; the kernel blitted the window on
  20 paint_scene visits (`dui blits=20`).
- **After (SB6WM.BIN + SB6NEW.BIN, seam B):** SB6NEW renders the SAME grid
  with PLAIN STORES into a bound shared surface — ZERO fill SVCs; the kernel
  SKIPPED the migrated window on 22 visits (`dui skips=22`, never a blit); the
  WM compose-N'd the surface into its scanout view (`sb6: wm bytes=196608`
  copy counter; `sb6: wm readback=0x6B` byte parity) and issued the FINAL
  present (REQUEST_PRESENT, flush-only).
- **Snapshot (syscalls + dui, ticks=45):** `13 sys_win_fill calls=576`
  (exactly the control's fills — the seam-B app added zero); `dui: windows=4
  presents=24 blits=20 skips=22` (blits>=9 and skips>=9 both hold).

Gate: `tools/verify-live-sb6-perf-payoff.sh` — **PASS** (runner-rc=0, zero
faults). Documented before/after (fills, composite cost, copy volume) in
`artifacts/m33-sb6-perf-payoff.md`. New kernel observables: `user_blits` /
`migrated_skips` monotonic counters + `dui blits=`/`skips=` columns; host test
pins the counter semantics (blit vs skip paths). Build clean, full host suite
green (221 driving_award tests), fmt/coordination ok, BSS PASS (685128 B
headroom).

**Honest finding (pre-existing, out of this card's scope):** the first bring-up
paced frames with cooperative yield-spins; a user task in a SUSTAINED
yield-spin stalls after the first timer preemption (~1 s, ~9-17 yields) — the
task stops being scheduled while the kernel's shell/worker keep advancing (no
fault line, no exit). Reproduces with a single app and no WM (SB6OLD alone),
so it is independent of the seam-B machinery. Existing gates that yield-loop
forever (WINLOOP, WINMOVE, SB4DAM) pass only because their evidence is
captured before the stall. SB6 apps pace with `sys_sleep(1)` (blocking — the
proven app pacing) and the gate is green. Candidate root cause: the EL0 timer
preemption vs the cooperative-yield resume path in
`scheduler.tick()`/`switch_context` — worth its own scheduler investigation
card.
