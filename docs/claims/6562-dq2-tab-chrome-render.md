# Claim: M37 DQ2 — Tab-bar chrome render (issue #840)

- **Owner:** t3code (`agent/t3code/dq2-tab-chrome`)
- **Prompt / plan:** `docs/march-m37-desktop-quality.md` (DQ2 row), issue #840
- **Scope:** DQ2 only — WM-drawn tab strip from `tab_item_rect`: titles + truncation, active highlight, hover, `×`. No pointer behavior (DQ3), no restyle (DQ4). Only card allowed to propose new `chrome_*` kind bits, with justification.
- **Touches:** docs/claims/6562-dq2-tab-chrome-render.md, docs/logs/agent-t3code-dq2-tab-chrome.md, docs/march-m37-desktop-quality.md, kernel/src/wnd_core.zig, kernel/src/driving_award.zig, kernel/src/syscall.zig, user/src/wnd.zig, user/src/tabhold.zig, build.zig, tools/verify-live-tabstrip.sh
- **Depends on:** DQ1-stable (god-menu fns settled — merged)
- **Heartbeat:** 2026-09-03
- **Status:** ✅ agent/t3code/dq2-tab-chrome (merged PR #847; card #840 stays open pending pixel proof)

## Notes

Renders what S6/DQ1 made listable: windows with attached tabs get a real
strip. The pure rules exist (`tab_bar_height`/`tab_item_rect`,
`kernel/src/wnd_core.zig:479-507`); nothing in `WND.BIN` calls them yet.
Determine first who blits (WM-issued `ChromeDesc` + kernel paint vs WND
direct draw) by reading the WMS4 descriptor path and the kernel window
paint; extend whichever side owns chrome, keeping the drift-guard parity
tests green.

Verified by host unit tests (layout/truncation/hit-test incl.
narrow-window clamps) + Class-B live VZ (attached tabs render a visible
strip, active tab highlighted) + `verify-bss-budget.sh` +
`verify-coordination.sh`. Strictly before DQ3 (no clicking what isn't
drawn).

## Status 2026-09-03: code complete, pixel proof pending infra

- **Shipped in tree:** kind bit + strip geometry + grouping facts +
  paint + TABHOLD + `verify-live-tabstrip.sh`. Unit: wnd_core 12/12,
  driving_award 218/218, syscall 492/492, wnd 103/103. Build/BSS/coord
  clean.
- **Live attach path proven** (`wnd: tab-attach child=3 parent=2` seen
  3× headless) — the recording + syscall + WND halves work on hardware.
- **Strip pixels NOT yet captured:** the tabstrip gate is blocked on the
  session-wide VZ infra flake (#843: delivery stalls, EL0 aborts incl. a
  −96 sighting, one fixed-PC EL1h abort). A call-site-disabled
  discriminator run still fails → the paint call is exonerated as the
  cause. Retry `verify-live-tabstrip.sh` on idle hardware.
- **Adjacent real bugs filed:** #846 (file-channel read reentrancy —
  found via a WND preload fault; worked around per-summon in DQ1).
