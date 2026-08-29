# Claim: WMS6 Gate D — the dock drains into WND.BIN (icon clicks + hover labels)

- **Owner:** buffy (`agent/buffy/wms6-dock-drain`)
- **Issue:** https://github.com/drawmeanelephant/DipshitOS/issues/626 (WMS6 of 10, milestone 16 — Gate D)
- **Depends on:** WMS6 Gate C (claim 6154, PR #650 merged — cmd 8 TOOLTIP, the hover label channel this gate reuses). Cut from `main`.
- **Blocks:** WMS8 (deleting kernel chrome code)
- **Heartbeat:** 2026-08-29
- **Status:** ✅ complete

## Scope — Gate D of the card: the WM decides dock icon clicks and hover labels

Gates A/B/C drained the keyboard, click, and hover chrome. Gate D drains the **dock**
(M15 C4): the 24 px left icon bar whose clicks restore minimized windows / focus-open a
window, and whose icons are the natural hover-label targets the M27 tooltip system was
built for. The dock's DECISION surface moves into WND.BIN; the kernel keeps the bar
blit, the icon glyphs, and the clamped action chain.

1. **New slot-65 subcommand `DOCK = 9` (ADR 0007 amendment):** `a0` = icon index (0..4).
   The kernel clamps (idx ≤ 4, else `EINVAL`) and applies through a new
   `dock_icon_click(idx)` helper that encapsulates the shim's exact chain — restore the
   first minimized user window, else focus + raise a user window, else open one — so a
   WM decision and a shim click are byte-identical actions.
2. **Kernel dock-click handler gated behind `!wm_owns_input`:** while a WM is registered
   the shell's dock-click self-handling is a no-op — the raw click already fanned to the
   WM (kind 19 with the button byte), and the WM decides. No WM registered → byte-identical
   (the boot-A regression proof).
3. **WND.BIN grows the dock policy:**
   - a kind-19 left-button DOWN EDGE hit-tests the dock icon grid (the shim's
     `(2, 8+idx*32)` 20×20 boxes) and issues `DOCK <idx>`, emitting `wnd: dock idx=N`;
   - a kind-19 hover over an icon issues `TOOLTIP show "<label>"` (cmd 8, Gate C — the
     icon labels "Calc"/"Notes"/"Terminal"/"Browser"/"Settings" for idx 0..4), emitting
     `wnd: tooltip`; leaving the grid issues `TOOLTIP hide`.
4. **Headless CI:** clicks + hovers ride `--pointer-virtio` (claim 9367, no Accessibility
   trust) — the gate choreographs a hover over icon 0 then a click on icon 0.
5. **On unregister** the shim fallback restores its own dock-click behavior unchanged.

## Design decisions

1. **The dock click is a restore/focus decision, not a new interaction.** The WM maps the
   click to the icon index; the kernel applies the SAME clamped chain the shim runs, so
   the W1–W16/m21 shim rows stay byte-identical and the only thing that moves is WHO
   decided (boot B proves the WM's `wnd: dock` + the kernel's `wm: dock=` applied).
2. **Hover labels ride the Gate-C TOOLTIP seam** — the dock is the first real hover-label
   consumer of cmd 8, proving the channels compose (a WM-driven label through the
   WM-driven box).
3. **The kernel keeps its dock functions** (WMS8 deletes them) — the bar blit + icon
   glyphs + restore chain stay kernel-side until the delete pass.

## Touches

`kernel/src/driving_award.zig` (`dock_icon_click`, gate the shim dock-click behind
`!wm_owns_input`), `kernel/src/wm_server.zig` (DOCK const + counter),
`kernel/src/syscall.zig` (cmd 9 handler), `user/src/wnd.zig` (dock click + hover-label
policy), `kernel/src/monitor.zig` (`wm` row `dock=`), new
`tools/verify-live-wnd6-dock-drain.sh`, `docs/decisions/0007-syscall-abi.md`,
`docs/status.md`, `docs/march-m32-wm-migration.md`, claim + log.