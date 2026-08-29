# Claim: WMS5 — geometry policy drain-out (the input seam + SET_WINDOW rects)

- **Owner:** buffy (`agent/buffy/wms5-geometry-seam`)
- **Issue:** https://github.com/drawmeanelephant/DipshitOS/issues/625 (WMS5 of 10, milestone 16)
- **Depends on:** WMS4 (claim 2491, PR #639 — the descriptor transport + composite-on-present, whose SET_WINDOW `a1/a2` geometry is reserved nonzero→EINVAL until this claim). Cut from the WMS4 branch (stacked); the WMS4 PR merges first.
- **Blocks:** WMS6 (desktop chrome — repositions overlays using this geometry), WMS8 (deleting kernel geometry code)
- **Heartbeat:** 2026-08-29
- **Status:** ✅ done — PR #639 (WMS4, the dependency) + this claim's PR both merged

## Scope (issue #625) — Gate 1 of the card: the INPUT SEAM + SET_WINDOW rects

The issue's own split guidance: *"if the input-seam handover proves hairy, split
the card's PR into 'WM receives raw stream' then 'WM decides geometry' — two
gates, one card."* This claim is **Gate 1 — the input seam (the card's real
content)** plus the SET_WINDOW rect transport the WM drives geometry through:

1. **Raw stream fan-out (the handover):** while a WM is registered, the
   registered WM — not the kernel — receives the raw pointer stream. New
   routing-restricted event kinds (ADR 0009 D2, the kind-18 pattern):
   - kind 19 `WM_POINTER`: raw absolute pointer — `arg0` = x|(y<<16),
     `flags` = button bits (reuse BTN_*); delivered ONLY to the registered
     WM's process queue, once per idle pass when the pointer state changed.
   - kind 20 `WM_WINDOW`: registry mirror — `flags` = id | visible<<8 |
     focused<<9 | workspace<<10, `arg0` = x|(y<<16), `arg1` = w|(h<<16);
     pushed on every user-window open/close/move/resize/visibility/focus
     change while a WM is registered, so the WM can hit-test.
2. **Kernel stops consuming geometry while a WM is registered:** the shell
   idle keeps draining input and tracking the cursor (blit surface —
   kernel-owned), but `pointer_tick`'s geometry consumption (drag, resize,
   snap, focus-at, minimize/close buttons, alt-tab) is gated behind
   `!wm_owns_input`; instead the raw pointer fans out to the WM. Zero
   regression: no WM registered → byte-identical to pre-WMS5.
3. **SET_WINDOW accepts rects:** the frozen ADR 0007 `a1`/`a2` encoding
   (`a1` = x|(y<<16), `a2` = w|(h<<16)) activates: the WM submits
   `SET_WINDOW(id, rect, wh)` and the kernel applies it through the existing
   clamped `user_move`/`user_resize` (geometry = WM-decision, blit + clamp =
   kernel). The chrome-descriptor path (ptr/len=40, WMS4) is unchanged; a
   call may carry rect and/or chrome.
4. **WND.BIN drives a drag:** the WM mirrors the window registry from
   kind-20, hit-tests the raw pointer from kind-19 (title bar → grab with
   offset; move while held → SET_WINDOW rect; release → drop), and marks the
   drag (`wnd: drag id=.. x=.. y=..` markers pinned as `pub const`s).
5. **Observability:** `wm` report gains pointer-fan-out and window-mirror
   counts (the gate's greps).

**Gate 2 of the card (explicitly NOT this claim):** the full geometry state
machines as WM policy — tile/master-detail/snap zones/workspaces/
minimize/maximize/fullscreen/always-on-top — and the W1–W16 gate matrix run
with WND.BIN registered. Rides this seam; claimed separately after Gate 1
lands (the issue's sanctioned split).

## Design decisions

1. **Cursor stays kernel-owned** (a blit surface like chrome); only geometry
   DECISIONS move out. The kernel still clamps (`user_move`/`user_resize`
   are the clamp boundary) — the WM proposes, the kernel clamps + blits.
2. **No new syscall.** SET_WINDOW's reserved `a1/a2` carry the rect (the
   ADR 0007 row already freezes that encoding; this claim activates it).
3. **Routing restriction = the kind-18 discipline:** `events.push` only when
   `wm_server.registered()`, to the registrant's pid only. Outsiders and
   shim mode see nothing (zero regression; the existing W1–W16 gates boot
   shim-only and must stay green untouched).
4. **wm_server stays the seam's home** (counters + fan-out helpers); the
   `wm_owns_input` flag lives in driving_award and is flipped by
   register/unregister (wm_server already imports driving_award for
   clear_wm_chrome — no new import cycle).
5. **Naked-asm WND.BIN** (the WMS3/WMS4 shape): register, chrome policy,
   then the pointer loop — wait_event drains kind-19/20, mirrors, hit-tests,
   issues SET_WINDOW rects, presents at its cadence. Bounded work per wake.

## Acceptance (gates)

- **Class B (live VZ):** new `tools/verify-live-wnd5-geometry.sh` — with
  WND.BIN registered and NOTEPAD open, the custom-virtio pointer injection
  (claims 9367/0680) drives a title-bar grab + drag; the gate greps
  `wnd: drag` markers, `wm:` fan-out counts, and the window's rect change
  (`dui` registry row), proving the WM — not the kernel — moved the window.
- **Class A:** unit tests (kind-19/20 routing restriction, SET_WINDOW rect
  apply + clamp + bad-id/bad-len EINVAL, WND.BIN drag-rule parity vs
  wnd_core), fmt, build, BSS budget, transcript + coordination gates.
- **Zero regression:** every pre-WMS5 gate stays green untouched (shim mode).

## Touches

`kernel/src/events.zig` (kinds 19/20), `kernel/src/wm_server.zig` (fan-out +
counters + register/unregister wiring), `kernel/src/driving_award.zig`
(`wm_owns_input` gate + mirror pushes + window-changed hooks),
`kernel/src/syscall.zig` (SET_WINDOW rect activation + tests),
`kernel/src/shell.zig` (idle seam branch), `kernel/src/monitor.zig` (`wm`
rows + registry help), `user/src/wnd.zig` (drag loop + markers),
`docs/decisions/0007-syscall-abi.md` (WMS5 rect activation note),
`docs/decisions/0009-events.md` (kind 19/20 D2 note), `docs/status.md`,
`docs/march-m32-wm-migration.md`, `tools/verify-live-wnd5-geometry.sh`
(new gate), `tools/sweep-vz.sh`, claim + log.
