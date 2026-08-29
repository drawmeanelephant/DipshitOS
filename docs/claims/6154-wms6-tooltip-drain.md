# Claim: WMS6 Gate C — the tooltip surface drains into WND.BIN (the read-mostly hover chrome)

- **Owner:** buffy (`agent/buffy/wms6-tooltip-drain`)
- **Issue:** https://github.com/drawmeanelephant/DipshitOS/issues/626 (WMS6 of 10, milestone 16 — Gate C)
- **Depends on:** WMS6 Gate B (claim 7557, PR #648 merged — kind-19 click channel, `wm_owns_input` gating, `--pointer-virtio` headless clicks). Cut from `main`.
- **Blocks:** WMS8 (deleting kernel chrome code)
- **Heartbeat:** 2026-08-29
- **Status:** ✅ complete

## Scope — Gate C of the card: the WM decides what the tooltip says

Gate A drained the keyboard chrome (Alt+Tab), Gate B the click chrome (notification
center). Gate C activates the **read-mostly hover chrome**: the tooltip. The M27 G6
tooltip in `driving_award` is a DORMANT stub — `tooltip_set` has no callers, no monitor
command drives it, and the M27 G7 row was only an audit of the renderer. Gate C makes
the tooltip a live surface whose POLICY lives in WND.BIN; the kernel keeps the clamp +
the box blit.

1. **New slot-65 subcommand `TOOLTIP = 8` (ADR 0007 amendment):** `a0` = 0 hide / 1 show;
   for show, `ptr/len` carry the text (≤ 32 bytes, the M27 bound — `copy_in` like the
   chrome descriptor; `EFAULT` bad pointer, `EINVAL` over-length). The kernel applies
   through the existing `tooltip_clear` / `tooltip_set` primitives plus a new
   `tooltip_show_now` (immediate show — the WM owns the hover-dwell policy; the shim's
   timer path stays for WMS8 deletion) and blits the box below its own cursor.
2. **Kernel self-trigger:** there is NONE today (the system is dormant), so there is
   nothing to gate — the honest statement is that the shim never self-triggered a
   tooltip, and it still doesn't (boot A: hover → nothing, no fault). WMS8 deletes the
   timer path.
3. **WND.BIN grows the tooltip policy:** a kind-19 hover (move, no click) entering the
   tray region (the same `fb_w - 80` slice as Gates A/B) decides a tooltip — "Clock" —
   and issues `TOOLTIP show "Clock"` (text via `ptr/len`); leaving the region issues
   `TOOLTIP hide`. Emits pinned `wnd: tooltip` markers.
4. **Headless CI:** the gate drives hover over `--pointer-virtio "<x>,<y>"` (a bare
   move, claim 9367) — no Accessibility trust. The WM sees the kind-19 move, decides,
   and the kernel renders the box.
5. **On unregister** the tooltip clears (the box belongs to the WM's session; the shim
   fallback stays dormant as before).

## Design decisions

1. **Activate, don't retrofit.** The dormant stub means the drain is a NEW live policy
   surface, not a gated shim decision — so the regression proof is "the shim still does
   nothing on hover (boot A), and the WM now does something (boot B)".
2. **The kernel keeps the tooltip functions** (WMS8 deletes them) — the 32-byte bound,
   the below-cursor placement and the box blit stay kernel-side; only the DECISION
   (when/what) moves out.
3. **Text rides `ptr/len`** — the one uaccess channel the slot-65 surface already has
   (the chrome descriptor precedent), so no new syscall.
4. **Immediate show (`tooltip_show_now`)** — the WM owns dwell by choosing WHEN to show;
   the shim's 10-tick timer is not a WM concern and dies with WMS8.

## Touches

`kernel/src/driving_award.zig` (`tooltip_show_now`), `kernel/src/wm_server.zig`
(TOOLTIP const + counter), `kernel/src/syscall.zig` (cmd 8 handler), `user/src/wnd.zig`
(hover policy + markers), `kernel/src/monitor.zig` (`dui tooltip-state` report + `wm`
row `tooltip=`), new `tools/verify-live-wnd6-tooltip-drain.sh`,
`docs/decisions/0007-syscall-abi.md`, `docs/status.md`, `docs/march-m32-wm-migration.md`,
claim + log.