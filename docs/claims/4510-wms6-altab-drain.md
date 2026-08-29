# Claim: WMS6 Gate A — Alt+Tab policy drains into WND.BIN (the first read-mostly chrome surface)

- **Owner:** buffy (`agent/buffy/wms6-altab-drain`)
- **Issue:** https://github.com/drawmeanelephant/DipshitOS/issues/626 (WMS6 of 10, milestone 16 — Gate A)
- **Depends on:** WMS5 Gate 2 (claim 4278, PR #644 merged — kind 21 `WM_KEY` keyboard fan-out, `wm_owns_input` gating, the SET_WINDOW/SET_STATE seam). Cut from `main` (WMS1–5 are merged).
- **Blocks:** WMS6 Gate B (notification center / toasts — click-driven, class-B trust), WMS8 (deleting kernel chrome code)
- **Heartbeat:** 2026-08-29
- **Status:** ✅ complete

## Scope — Gate A of the card: the WM decides which window Alt+Tab switches to

The issue's own guidance is to port the read-mostly, keyboard-driven chrome first and
leave modality for a second PR. Alt+Tab is the ideal first surface: it is keyboard-driven
(provable via the CI-runnable injected-chord pattern WMS5 established), and the WM already
sees the full window registry via kind 20 `WM_WINDOW` mirrors. Today the kernel `driving_award`
owns the whole Alt+Tab policy state machine (`overlay_*`: snapshot window ids, cycle the
highlight, commit/dismiss on Alt release). Gate A moves the *decision* into WND.BIN while the
kernel keeps clamps + the overlay blit.

1. **New slot-65 subcommand `ALT_TAB = 5` (ADR 0007 amendment):** `a1` = action, `a0` = window id.
   - `1 activate` — open the Alt+Tab overlay with `a0` as the current highlight;
   - `2 cycle` — move the highlight to `a0`;
   - `3 commit` — `focus(a0)` + `raise(a0)` and dismiss the overlay;
   - `4 dismiss` — drop the overlay without switching.
   The kernel clamps (window-id validity against the live snapshot, ≥2 user windows, visibility/
   workspace rules like the shim) and keeps rendering the overlay blit from `overlay_*`. No new
   syscall — a subcommand on the existing ADR 0007 slot-65 surface (slot count unchanged).
2. **Kernel Alt+Tab input path gates behind `!wm_owns_input`:** with no WM registered the Alt+Tab
   handling is byte-identical to today. With a WM, the raw Tab chord already fans to the WM as
   kind 21 (`WM_KEY`, `flags` = modifier bits incl. `MOD_ALT`, edge on key-down); the kernel does
   not self-cycle. An explicit `self_cycle_count` in `driving_award` (incremented only on the shim
   path) is the gate's `kernel_self_cycle=0` proof.
3. **WND.BIN grows the Alt+Tab policy:** the WM tracks a small mirror registry from kind-20 (already
   the single source it uses for geometry via `wnd_core`); on a `WM_KEY` Tab chord with `MOD_ALT`
   it runs the window list (visible, non-minimized, current workspace — the same M21 W3/W4 rules
   the shim applies), picks the next window after the focused one, and issues
   `ALT_TAB activate` + `cycle`/`commit`. Emits pinned `wnd: alt-tab=<id>` markers.
4. **On unregister** `clear_wm_chrome`-style reset: the Alt+Tab overlay state falls back to the shim
   path unchanged.

## Design decisions

1. **Read-mostly, keyboard-driven first (the issue's guidance).** Alt+Tab needs no Accessibility
   trust (the click-driven notification center does), so Gate A is fully CI-runnable via the proven
   injected-chord pattern. Modality/dock/dialogs are later gates of the same card.
2. **The kernel keeps its Alt+Tab functions** (WMS8 deletes them) — the no-WM path must stay
   byte-identical and the M21 WI shim rows run against them. Gate A gates the *input decision
   path*, not the functions.
3. **Single source via `wnd_core`:** the WM's alt-tab "next window" rule is the SAME shared rule the
   kernel shim uses (compiled into both binaries; the drift guard). A behavior change on either side
   fails the guard tests.
4. **`focus`/`raise` are the only kernel mutators** the WM reaches through for commit — same clamped
   primitives the shim uses, so the blit and focus bookkeeping stay consistent.
5. **No new event kind** — reuse kind 21 `WM_KEY` (the keyboard already reaches the WM).

## Touches

`kernel/src/wm_server.zig` (ALT_TAB const + apply + counters), `kernel/src/syscall.zig` (cmd 5
handler), `kernel/src/driving_award.zig` (expose `alt_tab_select_window` + `self_cycle_count`),
`kernel/src/wnd_core.zig` (shared alt-tab next-window rule), `user/src/wnd.zig` (EL0 alt-tab
policy), `kernel/src/monitor.zig` (`wm` observability), M21 `dui` alt-tab rows (registered-variant
assertions), new `tools/verify-live-wnd6-altab-drain.sh`, `docs/decisions/0007-syscall-abi.md`,
`docs/status.md`, `docs/march-m32-wm-migration.md`, claim + log.