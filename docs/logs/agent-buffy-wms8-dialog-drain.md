# Log — `agent/buffy/wms8-dialog-drain`

## 2026-08-30 — WMS8 Gate 2 claimed (issue #628)

Claimed **WMS8 Gate 2 — dialog overlay drain (slot 65 DIALOG)** as
`docs/claims/9980-wms8-dialog-drain.md` (status 🔄, heartbeat 2026-08-30). Branch
`agent/buffy/wms8-dialog-drain` cut from `main` after PR #660 (WMS8 Gate 1) merged.

**Why a DRAIN and not a DELETION this gate:** WMS6 explicitly left the modal/transient
dialogs on the WMS8 backlog, and WMS8's runbook deletes a block only after its parity
gate is green *with the WM registered*. The tooltip dwell (Gate 1) was deletable because
it was provably dead (zero callers). The unsaved/about dialogs are still the shim's only
implementation — reachable in default no-WM boots, which WMS8 rounds "the shim's
compositor core stays until the very last deletion." So Gate 2 = give the WM dialog
ownership (new slot-65 DIALOG), gate the kernel dialog decision behind `!wm_owns_input`
(dock/tray pattern), shim back-compat, parity gate; deletion lands later.
## 2026-08-30 — WMS8 Gate 2 COMPLETE (about dialog drained)

- **Gate 2 done — the ABOUT dialog (Ctrl+Shift+A) drains into WND.BIN policy.**
  New slot-65 cmd 11 `DIALOG` (a0 = 0 close / 1 open / 2 toggle) in `wm_server.zig` +
  the cmd-11 dispatch in `syscall.zig` applies the shim's OWN
  `about_dialog_open_dialog`/`about_dialog_close`/`about_dialog_toggle` primitives —
  parity by construction. The kernel's about self-toggle in `input.zig` gates behind
  `!wm_owns_input` (the dock/tray/notif pattern) so a registered WM cannot be fought,
  and `dialog=` joins the `wm` observability row. In `user/src/wnd.zig` WND.BIN
  decodes Ctrl+Shift+A (kind-21 usage 0x04 + shift) in `handle_wm_key` and issues
  DIALOG toggle, emitting `wnd: about` (pinned-const host test).
- **Why a DRAIN and not a deletion:** the about dialog is still the shim's ONLY
  implementation and live in default no-WM boots; WMS8 deletes a block only after its
  parity gate is green with the WM registered. So this gate gives ownership; the
  DELETION of the now-dormant kernel about-decision is a later gate.
- **Proof:** `verify-live-wnd8-dialog-drain.sh` PASS on VZ, both boots — boot A the
  shim self-toggles (`dui: about=open`, zero regression); boot B with WND.BIN
  registered the WM decided (`wnd: about`, `key_fan=1`) and the kernel applied
  (`wm: dialog=1`) and did NOT self-toggle (`dui: about` count 0). Host test
  `syscall: DIALOG (cmd 11, claim 9980)` green; zig build + fmt/coordination clean;
  BSS budget re-ran green.
- **Deferred:** the UNSAVED dialog stays — the WM can't know which windows are dirty
  until the kind-20 mirror carries an `unsaved` bit (a separate later gate). Issue
  #628 remains OPEN for the remaining deletion gates.
