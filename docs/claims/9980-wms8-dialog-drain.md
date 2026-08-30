# Claim: WMS8 Gate 2 — drain the unsaved/about dialog overlay to the WM (slot 65 `DIALOG`)

- **Agent:** buffy (worktree `agent/buffy/docs-pass`, branch `agent/buffy/wms8-dialog-drain`)
- **Issue:** https://github.com/drawmeanelephant/DipshitOS/issues/628 (WMS8 of 10, milestone 16)
- **Scope:** WMS8 Gate 2 of the deletion sequence. NOT a deletion this gate — a DRAIN
  that unlocks the dialog deletion. WMS6 explicitly left the modal/transient dialogs on
  the WMS8 backlog ("modal dialogs remain on the WMS8 delete-runbook backlog"), and
  WMS8's own rule is *"a block is deleted only when its parity gate has been green with
  the WM registered for that behavior."* Unlike Gate 1 (the tooltip dwell, provably dead
  with zero callers), the unsaved-changes + about dialogs are still the **shim's only
  implementation** — reachable in default no-WM boots that WMS8 rounds the "the shim's
  compositor core stays until the very last deletion" guarantee on. So this gate GIVES
  the WM dialog ownership (parity), then the kernel's own decision gates behind
  `!wm_owns_input` exactly like the dock/tray/notif gates. The actual DELETION of the
  now-dormant kernel dialog decision is a later WMS8 gate.
- **Status:** ✅
- **Heartbeat:** 2026-08-30
- **Touches:** `kernel/src/driving_award.zig` (about primitives, unchanged — the
  WM applies them via cmd 11), `kernel/src/wm_server.zig` (cmd 11 + `dialog_count`),
  `kernel/src/syscall.zig` (cmd-11 DIALOG dispatch + host test), `kernel/src/input.zig`
  (gate the about self-toggle behind `!wm_owns_input`), `kernel/src/monitor.zig`
  (`dialog=` observability), `user/src/wnd.zig` (Ctrl+Shift+A → DIALOG toggle,
  `wnd: about` marker + pinned-const host test), gate script, sweep registration,
  `docs/decisions/0015...`, `docs/march-m32-wm-migration.md`, `docs/status.md`,
  claim + log.
- **Key result:** 2026-08-30 — **drained the ABOUT dialog** (keyboard-driven,
  Ctrl+Shift+A). New slot-65 cmd 11 `DIALOG` (0 close / 1 open / 2 toggle) applies
  the shim's OWN `about_dialog_*` primitives (parity by construction); the kernel's
  about self-toggle gates behind `!wm_owns_input`; WND.BIN decodes Ctrl+Shift+A
  (kind-21 usage 0x04 + shift) and issues DIALOG, emitting `wnd: about`. The UNSAVED
  dialog is DEFERRED to a later gate — it still needs the kind-20 mirror to carry an
  `unsaved` bit before the WM can know which windows are dirty.
- **Proof:** `verify-live-wnd8-dialog-drain.sh` PASS on VZ, both boots (boot A shim
  `dui: about=open`; boot B `wnd: about`, `key_fan=1`, `wm: dialog=1`, `dui: about`
  count 0). Host test `syscall: DIALOG (cmd 11, claim 9980)` green; zig build clean;
  fmt/coordination clean; BSS budget re-ran green. Deleting the now-dormant kernel
  about-decision is a later WMS8 gate (#628 stays open).