# ADR 0018: Released-window mirror bit + kernel-mediated tab close

Status: **ACCEPTED** (claim issue #1008) · Date: 2026-09-05 · Milestone:
M42 Sexiburger desktop — UX hardening tranche

## Context

Two lifecycle blind spots survived the M39/M42 TABWM build-out:

- **The WM never learns a window was RELEASED.** The kernel's kind-20
  `WM_WINDOW` mirror stream (M32 WMS5) carries state (visible/focused/
  workspace/unsaved), but `driving_award.remove_user_at` — the shared
  release primitive behind `user_close` and the exit path's
  `close_owner` — fanned no mirror: only `user_close` fanned one
  pre-removal, and an app self-exit (or an owner-exit sweep) told the
  registered WM nothing. A tabbed WM whose tab list is fed by that
  stream cannot stay mirror-synced across exits.
- **A tab close was only a hide.** TABWM's `close_tab` called
  `set_state(false)` and dropped the tab; the owning process kept
  running hidden forever. The clean-exit seam already exists —
  `lib/tabapp.zig`'s `dispatch` classifies `WIN_CLOSE` (kind 8) to a
  clean exit, and `scheduler.exit_current` → `driving_award.close_owner`
  releases the window — but TABWM could not trigger it: an EL0 process
  cannot push an event into another process's event queue (slot 22
  reads the kernel `events.zig` queues only), and the IPC mailbox
  (slots 5/6) is a separate FIFO no tabapp drains. A WM-owned close
  needs the kernel to apply the release.

## Decisions

### D1. Additive `released` bit on the WM_WINDOW mirror (flags bit 13)

`wm_window_hook` and `wm_server.fan_window` gain one trailing
`released: bool` parameter. `fan_window` encodes it as flags **bit 13**
(`1 << 13`). All existing bits are unchanged — id (low byte), visible
(bit 8), focused (bit 9), workspace (bits 10–11), unsaved (bit 12) —
and `user/src/wnd.zig`'s decoder is deliberately NOT touched: it reads
only the bits it knows and ignores bit 13 (zero regression for the
legacy floating WM).

`remove_user_at` fans ONE mirror from the already-copied `removed_win`
state — geometry as-was, `visible=false`, `focused` = held-focus-at-
removal, `released=true` — and the now-redundant pre-removal fan block
in `user_close` is deleted. Every release path (`user_close`,
`close_owner`/app exit) informs the WM exactly once. The fan is pure
BSS writes (allocation-free), so it holds the same exception-context
contract as the WIN_CLOSE push that `remove_user_at` already performs
in the exit path.

### D2. WM-mediated close through the kernel's own release primitive

New slot-65 subcommand **`WMCTL_WIN_CLOSE` (cmd 13)**, WM-seat-only like
every cmd: a0 = window id; the kernel applies `driving_award.user_close`
— the SAME release primitive a shim close or `dui close <n>` runs — so
the owner receives the kernel's real `WIN_CLOSE` event push
(`remove_user_at`) and TABWM receives the released kind-20 mirror
(D1). Unknown id / non-user window → EINVAL. Counted as
`wm_server.note_win_close` (`win_close_count` in `WmInfo`).

TABWM's `close_tab` calls it (slot 65) BEFORE its marker/remove/
activate-next sequence. The local tab removal is the optimistic half;
the released mirror is the authoritative echo, and
`handle_window_mirror` absorbs it as a no-op for an already-removed
id — local removal and mirror echo agree by construction. A refused
seam (no WM seat, kernel refusal) falls back to hide-only with the
refusal visible in the marker line (`tabwm: win-close id=N closed=0|1`).

TABWM's mirror consumer is correspondingly lifecycle-aware: the
extracted `handle_window_mirror` drops the tab of a `released=true`
mirror (no WIN_CLOSE echo back to the app, no set_state of our own —
the kernel already released it), ignores plain hides (the tab list is
the WM's own), upserts geometry on visible mirrors, and ignores a
17th window instead of letting the manager's overflow return-0 hijack
tab 0's activation.

## Consequences

- The mirror ABI is extended, not broken: one additive bit, one
  additive parameter; WND.BIN and every pre-existing consumer compile
  and decode unchanged.
- A registered tabbed WM now converges with the kernel registry across
  app self-exits, owner-exit sweeps, and its own close decisions,
  closing the "zombie hidden tab" class for every release path — not
  just owner-known ones.
- The close path needs no owner-pid tracking in the WM: the kernel
  knows the owner and pushes WIN_CLOSE itself. One syscall, no new
  state, and the delivery semantics are exactly the proven shim ones.
- Cmd 13 is additive on the frozen ADR 0007 slot-65 command space
  (previously unused); WND.BIN never issues it and is untouched.

## Verification

`zig build` PASS; `zig build test` PASS (wm_server released-mirror
test: `remove_user_at`/`close_owner` fans `visible=false, released`
exactly once per release); `bash tools/verify-unit-tests.sh` PASS
including 8 new tabwm "M42 UX" class-A tests (released removes +
activates next; unknown-id no-op; hide-without-released kept; geometry
upsert; 17th-window guard; '+'-pill/Ctrl+T affordance incl. hit-test
order over the tab-row mapping; overlay empty vs filtered-empty;
close_tab local-removal + released-echo convergence). Full log:
`artifacts/2026-09-05-tabwm-ux-hardening/`.

Class B (live VZ, 2026-09-05): NEW gate
`tools/gate/specs/live-tabwm-close.spec` PASS 1/1 — the full chain on
real hardware: injected close-box click → `tabwm: win-close id=2
closed=1` (the kernel applied cmd 13) → `calc: win_close` →
`calc: exiting 43` → `dui: windows=4` (registry released). Live
regressions: `live-tabwm` PASS 1/1, `live-tabwm-fullscreen` PASS 2/2.

## Addendum — TABWM unsaved-state honesty + close feedback + Alt-Tab parity (2026-09-05, round 2, claim #1011)

Round 2 of the M42 UX-hardening tranche closes three remaining TABWM
honesty gaps WITHOUT ANY NEW KERNEL SURFACE: everything rides the
existing seams — the slot-65 DIALOG (cmd 11) unsaved actions 3–6 (the
WMS8 Gate 4 primitives WND.BIN already issues), the slot-65 ALT_TAB
(cmd 5) commit (the WMS6 Gate A seam), and the kind-20 mirror's unsaved
bit (flags bit 12, already fanned by `user_set_unsaved` and
`wm_server.fan_window` — TABWM simply decoded it, both upsert paths of
`handle_window_mirror`). `user/src/wnd.zig` and `user/src/tabapp.zig`
remain untouched; kernel files untouched this round.

- **Unsaved-state honesty.** Every TABWM close entry point (close-'x'
  pointer click, Ctrl+W, the detach RPC) routes through one decision
  function, `request_close_tab`: a clean tab closes exactly as before;
  a dirty tab (mirror bit 12) instead opens the unsaved-changes dialog
  (DIALOG action 3, a2 = the tab's window id) and waits. While the
  dialog is open it is MODAL in TABWM: pointer clicks hit-test the
  shared `wnd_core.unsaved_dialog_choice_at` rects FIRST and are
  consumed (parity by construction with the kernel's own
  `unsaved_dialog_click`), Escape = cancel / Enter = save, every other
  key is swallowed so no chord can mutate the tab list while a close
  decision is pending, and the Sexiburger overlay refuses to summon.
- **TABWM self-paints the dialog.** TABWM composes the FULL scanout
  every tick (sidebar + canvas backdrop), so its compose overdraws the
  kernel's own dialog blit from `driving_award.paint_scene` — the
  kernel-painted modal would never be visible under TABWM. TABWM
  therefore paints the dialog itself with the SAME 200x100 centered
  geometry and palette (0x1e293b surface, 0xf59e0b 2px border,
  0x10b981/0xef4444/0x64748b buttons — the shared `wnd_core` rect
  constants), so what the user sees matches WND's dialog exactly while
  the kernel still applies the decisions.
- **The discard-vs-save asymmetry.** `apply_unsaved_choice` is
  deliberately asymmetric, matching what each choice actually does
  kernel-side: DISCARD relies on the kernel's `user_close` INSIDE
  DIALOG action 5 — the owner gets the real WIN_CLOSE and exits, and
  the released kind-20 mirror echo (D1) removes the tab and activates
  the next; TABWM runs no local close. SAVE closes the tab via
  `close_tab`'s WMCTL_WIN_CLOSE (cmd 13, D2) after DIALOG action 4.
  Observed owner behavior (2026-09-05 hardware, NOTEPAD): the app
  treats WIN_UNSAVED as save-and-exit — it saves and exits 43 by
  itself, so cmd 13 lands while the window is still registered (honest
  `closed=1`) and the kernel's WIN_CLOSE push goes unconsumed. Either
  owner behavior converges: an app that kept running after its save
  would be closed by the WIN_CLOSE, and the released mirror echo is
  absorbed as a no-op (the tab is already removed). Cancel clears the
  dialog; the tab stays.
- **Close feedback.** `close_tab` records the ROW SLOT the closed tab
  occupied (position, not id — rows shift) plus an ~18-composite-tick
  countdown; `draw_sidebar` overlays an accent band on that slot while
  it is live (muted when the kernel refused the close and only a hide
  ran — the `closed=0` case). Pure helper `close_flash_active` keeps
  it unit-testable without a framebuffer.
- **Alt-Tab parity.** The kind-21 stream carries raw chords while the
  WM owns input, so TABWM now handles Alt+Tab / Alt+Shift+Tab (MOD_ALT
  + Tab) with WND's WMS6 Gate A semantics: the WM proposes the target
  through the pure `alt_tab_next` policy helper (the tab-list mirror of
  WND's `next_alt_tab_target` — next after the active row, wrapping,
  null under two tabs, shift inverts) and the kernel applies focus +
  raise via the ALT_TAB commit; `focus` auto-show re-reveals the
  TABWM-hidden target. TABWM does NOT call `activate_tab` on this path
  (the commit is the kernel-side truth; the target keeps its applied
  viewport) — it updates the local active row and emits the additive
  `tabwm: alt-tab id=N` marker. Ctrl+Tab / Ctrl+Shift+Tab are
  refactored through the SAME helper, so the two chords agree by
  construction.
- **Additive markers** (all pinned by class-A tests, grepped by the new
  class-B specs): `tabwm: unsaved-dialog id=N`, `tabwm: unsaved-save`,
  `tabwm: unsaved-discard`, `tabwm: unsaved-cancel`,
  `tabwm: alt-tab id=N`. The seven round-1 `tabwm:` markers are
  byte-identical.
