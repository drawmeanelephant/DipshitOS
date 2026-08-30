# Claim: WMS8 Gate 4 — the unsaved-changes dialog drains to the WM and the kernel decision is deleted

- **Owner:** buffy (`agent/buffy/wms8-unsaved-drain`)
- **Prompt / plan:** issue #628 (WMS8, fourth of a multi-gate deletion sequence)
- **Scope:** WMS8 Gate 4 of the deletion sequence — a DRAIN + DELETION for the
  unsaved-changes dialog (Arc4 #242). The WM cannot know which windows are dirty
  today (the kind-20 mirror carries no `unsaved` bit), so this gate (a) extends the
  kind-20 WM_WINDOW mirror with an `unsaved` bit (bit 12) + fans a mirror when the
  flag changes, (b) extends slot-65 cmd 11 `DIALOG` with the unsaved-dialog actions
  (3 show / 4 save / 5 dont-save / 6 cancel) applied through the kernel's own
  `unsaved_dialog_*` primitives (parity by construction), (c) gives WND.BIN the
  DECISION — close-click on a dirty mirror → DIALOG show; dialog buttons (shared
  wnd_core geometry rule) → DIALOG save/dont-save/cancel — and (d) DELETES the
  kernel's self-decision: the pointer_tick dialog intercept, the close-button
  dirty-check (shim close now closes immediately), and the 5-tick composite timeout.
  Shim end-state degradation (intended): without a WM, closing a dirty window no
  longer prompts — the issue's "no compositing policy" end-state.
- **Touches:** `kernel/src/wnd_core.zig`, `kernel/src/wm_server.zig`,
  `kernel/src/driving_award.zig`, `kernel/src/syscall.zig`, `user/src/wnd.zig`,
  `tools/verify-live-wnd8-unsaved-drain.sh`, `tools/sweep-vz.sh`,
  `docs/decisions/0015-window-server-render-seam.md`,
  `docs/march-m32-wm-migration.md`, `docs/status.md`, claim + log
- **Depends on:** WMS8 Gates 2+3 (claims 9980/7736, merged) — the DIALOG cmd-11 seam
  and the delete-runbook precedent this gate follows.
- **Heartbeat:** 2026-08-30
- **Status:** ✅ `agent/buffy/wms8-unsaved-drain`

## Result (2026-08-30)

- **Mirror:** kind-20 `WM_WINDOW` now carries `unsaved` (bit 12); `fan_window` gained
  the param and `user_set_unsaved` fans a mirror on change, so WND.BIN learns dirty
  state as it changes.
- **DIALOG seam:** cmd 11 gained actions 3 show (a1 = target, window-validated) /
  4 save / 5 dont-save / 6 cancel, applied through the kernel's own
  `unsaved_dialog_show` / `unsaved_dialog_save` / `unsaved_dialog_dont_save` /
  `unsaved_dialog_cancel` (the click-body actions extracted, click delegates to
  them — parity by construction). The `wm: dialog=` observability counts all.
- **WM decision (WND.BIN):** parses the mirror `unsaved` bit; on a kind-19 close-
  button click (title-bar top-right) on a dirty mirror issues DIALOG show (marker
  `wnd: unsaved-dialog`); on a dialog-button click (shared `wnd_core`
  `unsaved_dialog_choice_at` rule) issues DIALOG save/dont-save/cancel (markers
  `wnd: unsaved-save/discard/cancel`).
- **Deleted:** the pointer_tick dialog intercept, the close-button dirty-check
  (shim close closes immediately), and `unsaved_dialog_advance_tick` +
  `unsaved_timeout_ticks` + the composite advance (the WM decides duration now).
- **Gate `verify-live-wnd8-unsaved-drain.sh` PASS on VZ, both boots.** Boot A (no
  WM): `dui unsaved 2 1` marks NOTEPAD dirty, a real close click closes it
  immediately (`notepad: win_close`, zero `win_unsaved`, no fault, no dialog).
  Boot B (WND.BIN registered): `dui unsaved 2 1` (fans the mirror bit) → close
  click → the WM decided (`wnd: unsaved-dialog`) → Don't-Save click → the WM
  decided discard (`wnd: unsaved-discard`), the kernel applied
  (`wm: dialog=2` = show + discard) and NOTEPAD closed (`notepad: win_close`).
  Real pointer sequences confirmed (`PTR-CV-SEQ` in both runner logs).
- Host tests green (cmd-11 actions, wnd_core choice rule, fan_window bit);
  `zig build` + fmt/coordination clean; BSS budget re-ran green.
- **#628 stays open** — remaining deletion gates ahead.