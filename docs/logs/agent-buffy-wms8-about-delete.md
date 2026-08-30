# Log — `agent/buffy/wms8-about-delete`

## 2026-08-30 — WMS8 Gate 3 claimed (issue #628)

Claimed **WMS8 Gate 3 — delete the kernel about-dialog decision** as
`docs/claims/7736-wms8-about-delete.md` (status 🔄, heartbeat 2026-08-30). Branch
`agent/buffy/wms8-about-delete` cut from `main` after PR #662 (WMS8 Gate 2) merged.

**Why deletable now:** Gate 2 drained the about dialog to the WM (slot-65 cmd 11
`DIALOG`) and its parity gate is green with the WM registered, satisfying WMS8's
delete-runbook rule. The kernel's own Ctrl+Shift+A self-toggle (`about_pending` /
`take_about()` in input.zig, the shell idle block) is a decision the WM now owns, and
`about_dialog_hit_test` + the `pointer_tick` close-button block become provably dead
once it is gone (`about_dialog_open` then only settable via the WM-only cmd 11).
Deletion scope: the decision machinery; the applied primitives + the modal blit stay
(the WM's DIALOG still drives them).

## 2026-08-30 — WMS8 Gate 3 COMPLETE

- **Deleted** `about_pending` + the Ctrl+Shift+A decode branch + `take_about()` in
  `kernel/src/input.zig`; the shell idle `take_about()` block in `kernel/src/shell.zig`;
  and `about_dialog_hit_test` + the `pointer_tick` close-button block in
  `kernel/src/driving_award.zig` (~58 lines total, the "one policy block per PR, no
  rewrite" shape). Kept the applied primitives (`about_dialog_open_dialog` /
  `about_dialog_close` / `about_dialog_toggle`), `about_dialog_open`, and the modal
  blit — the WM's cmd-11 DIALOG still opens/closes/toggles and the kernel still
  renders.
- **Shim end-state degradation (intended):** Ctrl+Shift+A is now WM-only — the about
  dialog opens only when a WM is registered (the issue's "shell still boots, windows
  render via present path, no compositing policy" end-state). The parity gate's boot B
  proves the WM fully covers the feature.
- **Proof:** `verify-live-wnd8-dialog-drain.sh` re-run **PASS on VZ, both boots** — boot
  A the dormant shim shows nothing (`dui: about` count 0, no fault, shell responsive);
  boot B the WM still decides (`wnd: about`, `key_fan=1`) and the kernel applies
  (`wm: dialog=1`). Host test `syscall: DIALOG (cmd 11)` green; `zig build` + fmt +
  coordination clean; BSS budget re-ran green.
- **#628 stays open** — the unsaved dialog (needs a kind-20 `unsaved` mirror bit) and
  the remaining deletion gates are ahead.
