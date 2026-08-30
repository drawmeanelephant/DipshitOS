# Claim: WMS8 Gate 1 — delete the kernel tooltip dwell-decision policy

- **Owner:** buffy (`agent/buffy/wms8-desktop-overlay-drain`)
- **Prompt / plan:** issue #628 (WMS8, first of a multi-gate deletion sequence)
- **Scope:** M32 WMS8 — Slim `driving_award.zig` to a thin render server; this PR
  deletes ONE drained policy block: the tooltip dwell-decision (the kernel's
  `tooltip_set`/`tooltip_advance_tick` + the `tooltip_timer`/`tooltip_hover_ticks`
  state). The WM owns the WHEN of a tooltip via the WMS6 Gate C TOOLTIP (cmd 8)
  seam; the kernel keeps clamping, placing, and blitting the box.
- **Touches:** `kernel/src/driving_award.zig`, `tools/verify-live-wnd6-tooltip-drain.sh` (comment/assert note only), claim + log
- **Depends on:** WMS6 Gate C (claim 6154, merged) — the WM'd tooltip seam,
  whose parity is proven green by `verify-live-wnd6-tooltip-drain.sh`
- **Heartbeat:** 2026-08-29
- **Status:** ✅ `agent/buffy/wms8-desktop-overlay-drain`

## Notes

WMS8 is a 5,316-line kernel compositor whose policy has been draining into the
WND.BIN WM userland process since WMS4–WMS7. This card's end state is
`driving_award.zig` ≤ ~500 lines — a thin surfaces+blit+input-fan-out server.
The issue mandates deleting **one policy block per claim/PR**, each behind its
parity gate, with the shim compositor core surviving until the last deletion.

This is **Gate 1**: remove the tooltip dwell-decision from the kernel.

Why it's clean and safe:
- The dwell path is **dead**: `tooltip_set` has no callers, so the kernel's
  `tooltip_timer` never increments on its own and the dwell-only
  `tooltip_advance_tick` (the 10-tick shim hover timer) can never turn the box
  on by itself. The tooltip is shown only through `tooltip_show_now`/
  `tooltip_show`, which the registered WM reaches through the frozen TOOLTIP
  (cmd 8) seam.
- The deletion is mechanical (remove `tooltip_set`, `tooltip_advance_tick`, the
  composite call at the idle drain, and the `tooltip_timer`/
  `tooltip_hover_ticks` BSS) — no rewrite. What stays is `tooltip_show`/
  `tooltip_show_now`/`tooltip_clear` (the WM decision channel), the clamp, the
  box blit, and the monitor observability.
- Parity is already proven: WMS6 Gate C (`verify-live-wnd6-tooltip-drain.sh`)
  runs two boots — boot A the dormant shim shows no box on hover, boot B the
  WM decides and the kernel applies `tooltip=[count]` + `visible=yes`. Nothing
  the WM drives goes through the deleted code, so the gate re-runs green
  unchanged.

**Result (2026-08-29):** deleted `tooltip_set`, `tooltip_advance_tick`, the
composite idle call, and the `tooltip_timer`/`tooltip_hover_ticks` BSS;
retained the clamp/place/blit surface, `tooltip_show`/`tooltip_show_now`/
`tooltip_clear`, and `dui tooltip-state` observability. WMS6 Gate C re-ran
**PASS on VZ** both boots (dormant shim shows nothing on hover; the WM still
decides `visible=yes text=Clock` with `wm: tooltip=1` applied). Host tests 215
(driving_award) + 470 (syscall incl. the TOOLTIP cmd-8 test) green; `zig build`
clean; fmt/coordination clean; `verify-bss-budget.sh` re-ran green with added
headroom (10,849,896 / 11,534,336 B). `driving_award.zig` now 5,301 lines.

**This PR deliberately does NOT close #628.** The issue is a multi-PR deletion
sequence by design; closing it on one merged PR would either be an enormous
high-risk single change or an honest-closure-turned-lie. This PR links #628 as
progress on the sequence and leaves it open for the remaining deletion gates
(policy introspection surface, geometry/desktop-chrome dead blocks, and the
registry/convergence path).