# Log — `t3code/milestone-nine-triage`

Append-only. One entry per unit of work; never rewrite or delete.

---

## 2026-08-24 — claim 8777 opened: M21 window-management gate sweep (W1–W16)

- **Claim:** `docs/claims/8777-m21-window-gate-sweep.md` (🔄)
- **Context:** GitHub milestone 9 ("M21 — Window management depth") triage.
  Survey at HEAD `9bc0ec2`: W1–W5 merged via #488, W9/W11/W12 via 1a8dedf,
  W6–W10 primitives wired to live chords in shell.zig (maximize landed as
  Ctrl+Shift+M; the issue's Ctrl+M belongs to W2 master-swap). No M21 card
  has observed evidence: no gates exist, march-m21.md is empty of evidence
  and lacks W6–W16 rows, all issues open except W9.
- **Plan:** verification-first sweep in milestone order — per-card class-B
  gates (`tools/verify-live-m21-*.sh`, win-move/claim-0487 pattern with
  EL1h `dui` halves for chord entries), gap fixes as found (known gaps:
  W14 unimplemented; W15/W16 unwired), doc flips + issue close-outs with
  artifacts under `artifacts/`.
- **Next:** W1+W2 tiling/master-detail gate first.

---

## 2026-08-24 — claim 8777 resumed: sweep findings (winmove drive-by, tiled-blit OOB) + claim 2621 flip

- **Claim:** `docs/claims/8777-m21-window-gate-sweep.md` (🔄, Touches extended)
- **Found while preparing the W1/W2 gate:**
  1. 19a6335 (Aug 20 UI overhaul) resized WINMOVE.BIN 256×192 → 512×384 in
     asm/consts/docstring but left its pinned unit tests AND
     `tools/verify-live-win-move.sh` asserting the old geometry — class A
     tests fail on main; the milestone-six pattern gate has been red since
     Aug 20. Fixing both to the current reality and re-running live.
  2. `apply_tile_layout` rects (up to 837×700) exceed the fixed 512×384
     user back-buffer and `paint(.user)` → `blit_rect` doesn't clamp the
     source — every tiled window would blit OOB from BSS. Latent (no M21
     gate ever ran). Fixing with a source clamp in `paint(.user)`.
  3. Claim 2621 (`agent/buffy/m21-compositor-w9-w11-w12`) left 🔄 although
     its work merged as 1a8dedf (on main, verified by ancestry); flipping
     to ✅ per the claim-6637 precedent so its Touches stop holding
     monitor/shell/driving_award/syscall for this sweep.
- **Next:** W1+W2 gate: `dui tile <n>` / `dui master` EL1h halves,
  M21DEMO.BIN two-window payload, `tools/verify-live-m21-tile-master.sh`.

---

## 2026-08-25 — claim 8777: W1+W2 LIVE on VZ (first M21 evidence); win-move gate repaired green

- **Claim:** `docs/claims/8777-m21-window-gate-sweep.md` (🔄, W1+W2 done)
- **Landed:**
  - Fixes from the 2026-08-24 findings: winmove.zig pinned tests +
    stale inline comments aligned to the 512×384 reality; the tiled-blit
    source clamp in `paint(.user)` (driving_award.zig).
  - `tools/verify-live-win-move.sh` (milestone-six pattern gate, red since
    19a6335 on Aug 20): geometry updated to the clamp corner (768,336),
    registry/syscall assertions synced to observed current-main state
    (windows=5, user row dui[4], query z=4, implemented=63), hidden-capture
    scan excludes the taskbar strip (its white tray glyphs), and the
    final-frame pick now takes the highest-Ns capture explicitly (mtime
    ties after the artifacts copy). Also made self-contained: --script now
    points at $RUN_DIR/script.txt instead of the never-committed
    artifacts/live-win-move-script.txt. **PASS** live (2 runs today).
  - New EL1h halves `dui tile <n>` / `dui master` in monitor.zig cmd_dui
    (+ tiling-state line in the plain `dui` report; help text synced in
    monitor.zig + shell.zig + tests/transcript-console.txt). These drive
    the same functions as the Ctrl+T/Ctrl+M chords (#179 synthesized-kbd
    seam still deferred).
  - M21DEMO.BIN (`user/src/m21demo.zig`, thirty-eighth ESP program):
    two owned windows (A dark-blue+red id=2, B black+cyan id=3),
    build.zig + make-image.sh + mkfat32.py wiring (positional slot 42,
    new m21demo_file positional).
  - New gate `tools/verify-live-m21-tile-master.sh`: run A proves the W1
    tiled split (master 837 px / detail 419 px registry + pixels), run B
    proves the W2 swap (both rects move, cyan re-observed at the new
    origin). **PASS** live.
- **Runner lesson recorded in the gate:** scriptPoll checks
  --script-expect BEFORE --screenshot-after each poll and finishes on a
  match — the expect text must land in a LATER poll than the capture
  marker, or the capture never fires.
- **Evidence:** artifacts/live-m21-tile-* (gate/report/run{A,B}-*),
  artifacts/live-win-move-* refreshed.
- **Class A:** zig fmt clean; verify-unit-tests.sh all green (46 modules
  incl. driving_award 189, monitor 527, shell 730); transcript
  byte-identical; image builds with M21DEMO.BIN embedded.
- **Next:** W3 minimize gate (`dui minimize <n>` half + dock restore), then
  W4/W5; W6+ clusters after.
