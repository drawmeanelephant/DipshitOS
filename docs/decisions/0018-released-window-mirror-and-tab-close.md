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
