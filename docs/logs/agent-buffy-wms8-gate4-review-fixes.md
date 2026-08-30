# Log — `agent/buffy/wms8-gate4-review-fixes`

## 2026-08-30 — WMS8 Gate 4 review fixes claimed (issue #628)

- Claimed **7639** — post-merge review fixes for PR #666 (WMS8 Gate 4, claim
  6155): the drag-on-close fall-through, the bottom-up close scan, and the
  unguarded DIALOG 4/5/6 stale-target path, plus the Cancel-rect nit and the
  `user_set_unsaved` early-out. Branch `agent/buffy/wms8-gate4-review-fixes`
  cut from `origin/main` (de69ec2).
- The three bugs were confirmed against the code before claiming:
  (1) the close-rect is inside the title band so the DOWN-EDGE handler starts
  a title-bar grab after showing the dialog (the shim set `handled_btn` and
  broke); (2) the mirror scan walks ids 2→5 (bottom-up) while the kernel walks
  top-down, and z-order == id order (`raise()` has no callers); (3) cmd-11
  DIALOG actions 4/5/6 act on the stale BSS-zero `unsaved_dialog_target` with
  no `unsaved_dialog_is_open()` guard (the old click path returned `.none`
  first).
- **#628 stays open** — this is a review-fix PR that links, not closes, it.

## 2026-08-30 — WMS8 Gate 4 review fixes complete (claim 7639, issue #628)

- Claim **7639** closed ✅. Branch `agent/buffy/wms8-gate4-review-fixes`.
- Fixed all three review findings + nits: (1) the close-click DOWN EDGE no
  longer falls through into the WMS5 title-bar grab (`down_handled` +
  gate asserts zero `wnd: grab/drag/drop`); (2) the close-button scan is now
  top-down (reverse mirror id order) matching the kernel's win_count..0 walk;
  (3) cmd-11 DIALOG actions 4/5/6 return EINVAL when no dialog is open
  (stale BSS-zero target unreachable), pinned in the host test. Cancel rect
  fixed to the painted 30px button on both sides; `user_set_unsaved`
  early-outs on unchanged flag.
- Gate `verify-live-wnd8-unsaved-drain.sh` re-ran **PASS on VZ, both boots**
  with the new no-drag assertion. Host tests 472/10/215 green; fmt +
  coordination clean; BSS budget re-ran green.
- Docs updated: march WMS8 row, status.md, ADR 0015.
- **#628 stays open** — this PR links, not closes, it.
