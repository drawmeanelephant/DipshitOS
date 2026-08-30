# Claim: WMS8 Gate 3 — delete the kernel about-dialog decision (Ctrl+Shift+A drains fully)

- **Owner:** buffy (`agent/buffy/wms8-about-delete`)
- **Prompt / plan:** issue #628 (WMS8, third of a multi-gate deletion sequence)
- **Scope:** WMS8 Gate 3 of the deletion sequence — a DELETION. Gate 2 (claim 9980)
  gave the WM the about-dialog decision via slot-65 cmd 11 `DIALOG` and proved parity
  green (`verify-live-wnd8-dialog-drain.sh` boot B: `wnd: about`, `key_fan=1`,
  `wm: dialog=1`). That satisfies WMS8's rule — *"a block is deleted only when its
  parity gate has been green with the WM registered for that behavior"* — so this gate
  DELETES the kernel's own about-decision: the `about_pending` flag + Ctrl+Shift+A
  decode branch + `take_about()` in `input.zig`, and the shell idle `take_about()`
  block in `shell.zig`. The kernel KEEPS the applied primitives
  (`about_dialog_open_dialog` / `about_dialog_close` / `about_dialog_toggle`) that cmd
  11 applies, the `about_dialog_open` state, and the modal blit. The pointer
  close-button hit-test (`about_dialog_hit_test` + the `pointer_tick` block) becomes
  provably dead once the shim decision is gone (`about_dialog_open` is then only
  settable via the WM-only cmd 11, and `pointer_tick` early-returns when a WM owns
  input), so it is deleted too. Shims: the end-state degradation — Ctrl+Shift+A is
  now WM-only (a WM must be registered for the about dialog to open), consistent with
  the issue's "shell still boots, windows render via present path, no compositing
  policy" end-state.
- **Touches:** `kernel/src/input.zig`, `kernel/src/shell.zig`,
  `kernel/src/driving_award.zig`, `tools/verify-live-wnd8-dialog-drain.sh`,
  `docs/decisions/0015-window-server-render-seam.md`,
  `docs/march-m32-wm-migration.md`, `docs/status.md`, claim + log
- **Depends on:** WMS8 Gate 2 (claim 9980, merged) — the DIALOG seam + the parity gate
  this deletion rests on.
- **Heartbeat:** 2026-08-30
- **Status:** ✅ `agent/buffy/wms8-about-delete`

## Result (2026-08-30)

- **Deleted** `about_pending` + the Ctrl+Shift+A decode branch + `take_about()` in
  `input.zig` (26 lines), the shell idle `take_about()` block in `shell.zig` (7 lines),
  and `about_dialog_hit_test` + the `pointer_tick` close-button block in
  `driving_award.zig` (25 lines) — ~58 lines removed, the "one policy block per PR,
  no rewrite" shape.
- **Kept** the applied primitives (`about_dialog_open_dialog`/`about_dialog_close`/
  `about_dialog_toggle`), `about_dialog_open`, and the modal blit — the WM's cmd-11
  DIALOG still opens/closes/toggles and the kernel still renders it.
- **Gate re-run `verify-live-wnd8-dialog-drain.sh` PASS on VZ**: boot A the dormant
  shim no longer self-toggles (`dui: about` count 0 — the degraded end-state, no
  fault, shell responsive); boot B with WND.BIN registered the WM still decides
  (`wnd: about`, `key_fan=1`) and the kernel applies (`wm: dialog=1`).
- Host tests green (incl. `syscall: DIALOG (cmd 11)` — the WM path unchanged);
  `zig build` + fmt/coordination clean; BSS budget re-ran green.
- **#628 stays open** — the unsaved dialog (needs a kind-20 `unsaved` mirror bit) and
  the remaining deletion gates are still ahead.