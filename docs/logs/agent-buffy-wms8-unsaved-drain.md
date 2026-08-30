# Log — `agent/buffy/wms8-unsaved-drain`

## 2026-08-30 — WMS8 Gate 4 claimed (issue #628)

Claimed **WMS8 Gate 4 — the unsaved-changes dialog drains to the WM + the kernel
decision is deleted** as `docs/claims/6155-wms8-unsaved-drain.md` (status 🔄,
heartbeat 2026-08-30). Branch `agent/buffy/wms8-unsaved-drain` cut from `main`
after PR #664 (WMS8 Gate 3) merged.

**Why this shape:** the WM cannot know which windows are dirty today — the kind-20
mirror has no `unsaved` bit — so the unsaved dialog cannot be drained (or deleted)
until the mirror carries it. This gate: (1) kind-20 `unsaved` bit (bit 12) + fan on
change; (2) cmd-11 DIALOG actions 3–6 (unsaved show/save/dont-save/cancel) applied
through the kernel's own `unsaved_dialog_*` primitives; (3) WND.BIN decides —
close-click on a dirty mirror shows the dialog, dialog buttons apply save/dont-save/
cancel via the shared wnd_core choice rule; (4) delete the kernel self-decision
(pointer intercept, close dirty-check, 5-tick timeout). Shim mode degrades to
close-without-prompt (the issue's "no compositing policy" end-state).

## 2026-08-30 — WMS8 Gate 4 COMPLETE

- **Mirror:** `fan_window` carries `unsaved` (bit 12); `user_set_unsaved` fans a
  mirror on change; the hook signature + `wm_mirror` pass it through.
- **DIALOG seam:** cmd-11 actions 3 (show, a1 = window-validated target) / 4 (save) /
  5 (dont-save) / 6 (cancel); the `unsaved_dialog_click` save/dont-save/cancel bodies
  extracted to `unsaved_dialog_save` / `unsaved_dialog_dont_save` /
  `unsaved_dialog_cancel`, and `unsaved_dialog_click` delegates to them (parity by
  construction — a WM action and a shim button click run the same code).
- **WND.BIN:** parses the mirror `unsaved` bit; close-button hit-test on kind-19
  (title-bar top-right) shows the dialog for a dirty mirror (`wnd: unsaved-dialog`);
  dialog-button hit-test via the shared `wnd_core.unsaved_dialog_choice_at` rule
  issues save/dont-save/cancel (`wnd: unsaved-save` / `wnd: unsaved-discard` /
  `wnd: unsaved-cancel`).
- **Deleted:** the pointer_tick dialog intercept, the close-button dirty-check
  (shim close closes immediately), and `unsaved_dialog_advance_tick` +
  `unsaved_timeout_ticks` + the composite advance.
- **Proof:** `verify-live-wnd8-unsaved-drain.sh` **PASS on VZ, both boots** — boot A
  the shim closes a dirty window immediately (no dialog, window gone); boot B with
  WND.BIN registered the WM decided (`wnd: unsaved-dialog`, `wm: dialog=` grows),
  and the Don't-Save click closed the window. Host tests green (cmd-11 actions,
  wnd_core choice rule, fan_window bit); `zig build` + fmt + coordination clean; BSS
  budget re-ran green.
- **#628 stays open** — remaining deletion gates ahead.

## 2026-08-30 — WMS8 Gate 4 complete (claim 6155, issue #628)

- Claim **6155** (WMS8 Gate 4 — unsaved-changes dialog drain + kernel-decision
  deletion) closed ✅. Branch `agent/buffy/wms8-unsaved-drain`.
- Shipped: kind-20 mirror `unsaved` bit (flags bit 12) fanned by
  `user_set_unsaved`; DIALOG cmd-11 actions 3–6 through the kernel's own
  `unsaved_dialog_*` primitives; WND.BIN decision (close on dirty mirror →
  DIALOG 3, dialog buttons via the shared `wnd_core.unsaved_dialog_choice_at`
  rule → DIALOG 4/5/6, markers `wnd: unsaved-dialog` /
  `wnd: unsaved-save/discard/cancel`); DELETED the pointer_tick intercept,
  the close-button dirty-check, and the 5-tick timeout.
- New gate `verify-live-wnd8-unsaved-drain.sh` **PASS on VZ, both boots**
  (registered in `tools/sweep-vz.sh`): boot A the shim closes a dirty window
  immediately (no dialog, no fault); boot B the WM decided show + discard and
  the kernel applied (`wm: dialog=2`) and closed NOTEPAD.
- Host tests green incl. the syscall DIALOG unsaved-actions + wnd_core
  choice-rule pins; `zig build` + fmt/coordination clean; BSS budget re-ran
  green. Docs updated: march WMS8 row, status.md, ADR 0015.
- **#628 stays open** — remaining deletion gates ahead.
