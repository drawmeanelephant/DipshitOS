# Claim: WMS8 Gate 2 — drain the kernel about dialog to the WM (slot 65 `DIALOG`)

- **Owner:** buffy (`agent/buffy/wms8-dialog-drain`)
- **Prompt / plan:** issue #628 (WMS8, second of a multi-gate deletion sequence)
- **Scope:** WMS8 Gate 2 of the deletion sequence. NOT a deletion this gate — a DRAIN
  that unlocks the dialog deletion. WMS6 explicitly left the modal/transient dialogs on
  the WMS8 backlog ("modal dialogs remain on the WMS8 delete-runbook backlog"), and
  WMS8's own rule is *"a block is deleted only when its parity gate has been green with
  the WM registered for that behavior."* Unlike Gate 1 (the tooltip dwell, provably dead
  with zero callers), the about dialog is still the **shim's only implementation** —
  reachable in default no-WM boots that WMS8's "the shim's compositor core stays until
  the very last deletion" guarantee covers. So this gate GIVES the WM dialog ownership
  (parity), gating the kernel's own decision behind `!wm_owns_input` exactly like the
  dock/tray/notif gates. The actual DELETION of the now-dormant kernel about-decision is
  a later WMS8 gate.
- **Touches:** `kernel/src/wm_server.zig`, `kernel/src/syscall.zig`,
  `kernel/src/input.zig`, `kernel/src/monitor.zig`, `user/src/wnd.zig`,
  `tools/verify-live-wnd8-dialog-drain.sh`, `tools/sweep-vz.sh`,
  `docs/decisions/0015-window-server-render-seam.md`, `docs/march-m32-wm-migration.md`,
  `docs/status.md`, claim + log
- **Depends on:** WMS5 Gate 2 (claim 4278, merged) — the kind-21 keyboard seam the WM
  owns, which this gate's Ctrl+Shift+A chord rides; WMS6 Gate C (claim 6154) tooltip
  parity pattern; WMS8 Gate 1 (claim 4790, merged) — the deletion runbook this gate
  follows.
- **Heartbeat:** 2026-08-30
- **Status:** ✅ `agent/buffy/wms8-dialog-drain`

## Result (2026-08-30)

- **Drained the ABOUT dialog** (keyboard-driven, Ctrl+Shift+A). New slot-65 cmd 11
  `DIALOG` (a0 = 0 close / 1 open / 2 toggle) applies the shim's OWN
  `about_dialog_open_dialog`/`about_dialog_close`/`about_dialog_toggle` primitives —
  parity by construction. The kernel's about self-toggle in `input.zig` gates behind
  `!wm_owns_input`; WND.BIN decodes the kind-21 usage-0x04+shift chord in
  `handle_wm_key` and issues DIALOG toggle, emitting `wnd: about`; `dialog=` joins the
  `wm` observability row.
- **Gate `tools/verify-live-wnd8-dialog-drain.sh` PASS on VZ, both boots.** Boot A (no
  WM): the shim still self-toggles (`dui: about=open`). Boot B (WND.BIN registered): the
  WM decided (`wnd: about`, `key_fan=1`) and the kernel applied (`wm: dialog=1`) and did
  not self-toggle (`dui: about` count 0).
- Host test `syscall: DIALOG (cmd 11, claim 9980)` green; `zig build` + fmt/coordination
  clean; BSS budget re-ran green (684 KB headroom).
- **Deferred:** the UNSAVED dialog stays — the WM can't know which windows are dirty
  until the kind-20 mirror carries an `unsaved` bit (a separate later gate). Issue #628
  remains OPEN for the remaining deletion gates.