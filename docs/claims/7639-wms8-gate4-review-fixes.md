# Claim 7639: WMS8 Gate 4 review fixes — drag-on-close, top-down scan, DIALOG guard

- **Owner:** buffy (`agent/buffy/wms8-gate4-review-fixes`)
- **Prompt / plan:** post-merge review of PR #666 (WMS8 Gate 4, claim 6155) found
  three real bugs; this claim fixes them as a follow-up PR linking #628.
- **Scope:** review-fix follow-up, no new surface:
  1. **Drag-on-close (wnd.zig):** the close-button rect sits inside the title
     band, so after `show_unsaved_dialog(m.id)` the WM's DOWN-EDGE handler falls
     through to the WMS5 title-bar grab (`grabbing = true` + `wnd: grab`, then a
     `snap_window_to` on release). The kernel shim set `handled_btn` and broke;
     the WM must consume the DOWN EDGE when the dialog or a close button takes
     it.
  2. **Bottom-up close scan (wnd.zig):** `for (&mirrors)` walks ids 2→5 =
     registry order = the BOTTOM of the z-stack; the kernel walks `win_count..0`
     top-down. With overlapping title bars the WM would show the dialog for the
     wrong (lower) window. Scan top-down (reverse mirror order) to match.
  3. **DIALOG actions 4/5/6 without an open dialog (syscall.zig + the
     extracted primitives):** `unsaved_dialog_save/dont_save/cancel`
     unconditionally clear the open flag and act on the stale
     `unsaved_dialog_target` (BSS-zero before any show). The old click path
     started with `if (!unsaved_dialog_open) return .none`. Return EINVAL when
     nothing is open, and pin the stale path in the host test.
  Nits: fix the shared Cancel rect to the painted 30px (x+160..190, was
  x+160..220 — overrunning the 200px dialog) on both sides; early-out in
  `user_set_unsaved` when the flag is unchanged; trailing newlines on the
  claim/log.
- **Touches:** `user/src/wnd.zig`, `kernel/src/syscall.zig`,
  `kernel/src/wnd_core.zig`, `kernel/src/driving_award.zig`,
  `tools/verify-live-wnd8-unsaved-drain.sh`, `docs/status.md`,
  `docs/march-m32-wm-migration.md`, `docs/decisions/0015-window-server-render-seam.md`,
  claim + log
- **Depends on:** WMS8 Gate 4 (claim 6155, merged via PR #666).
- **Heartbeat:** 2026-08-30
- **Status:** ✅ `agent/buffy/wms8-gate4-review-fixes`

## Result (2026-08-30)

- **Fix 1 (drag-on-close):** the WM's DOWN-EDGE handler now sets
  `down_handled` when the dialog or a close button consumes the click and
  skips the WMS5 title-bar grab block (the shim set `handled_btn` and
  broke). The live gate now asserts ZERO `wnd: grab`/`wnd: drag`/`wnd: drop`
  in boot B — previously the close click printed `wnd: grab` + `wnd: drop`.
- **Fix 2 (top-down scan):** the close-button scan iterates mirrors in
  reverse id order (ids 5..2 == top of the stack, since z-order == id order
  and `raise()` has no callers), matching the kernel's win_count..0 walk —
  the higher window wins on overlapping title bars.
- **Fix 3 (DIALOG guard):** cmd-11 actions 4/5/6 return EINVAL (not
  counted) when `!unsaved_dialog_is_open()`; the stale BSS-zero
  `unsaved_dialog_target` is unreachable. The syscall host test pins the
  closed-dialog EINVAL path (was: a counted no-op).
- **Nits:** the shared `wnd_core.unsaved_dialog_choice_at` Cancel rect is now
  the painted 30px button (x+160..190, was x+160..220 — overran the 200px
  dialog) on both sides with test pins; `user_set_unsaved` early-outs on an
  unchanged flag.
- **Gate `verify-live-wnd8-unsaved-drain.sh` re-ran PASS on VZ, both boots,**
  with the new no-drag assertion (boot B: `wnd: unsaved-dialog` +
  `wnd: unsaved-discard`, `wm: dialog=2`, `notepad: win_close`, zero
  grab/drag/drop).
- Host tests green (syscall 472, wnd_core 10, driving_award 215 incl. the
  updated pins); fmt/coordination clean; BSS budget re-ran green.
- **#628 stays open** — review-fix PR links, does not close it.
