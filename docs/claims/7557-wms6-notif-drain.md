# Claim: WMS6 Gate B — notification-center policy drains into WND.BIN (the click-driven chrome surface)

- **Owner:** buffy (`agent/buffy/wms6-notif-drain`)
- **Issue:** https://github.com/drawmeanelephant/DipshitOS/issues/626 (WMS6 of 10, milestone 16 — Gate B)
- **Depends on:** WMS6 Gate A (claim 4510, PR #646 merged — cmd 5 ALT_TAB, kind-21 keyboard fan, `wm_owns_input` gating). Cut from `main`. Also rides the headless `--pointer-virtio` click channel (claim 9367).
- **Blocks:** WMS8 (deleting kernel chrome code)
- **Heartbeat:** 2026-08-29
- **Status:** ✅ complete

## Scope — Gate B of the card: the WM decides the notification center

Gate A drained the keyboard-driven chrome (Alt+Tab). Gate B drains the click-driven
chrome: the **notification center** (the M21 W5 tray-clock pull-out panel). Today the
kernel owns the panel state (`notif_center_open`) AND the tray-click toggle/dismiss/clear
AND the render. Gate B moves the *decision* into WND.BIN; the kernel keeps clamps + the
panel blit.

1. **Kernel tray-click decision gated behind `!wm_owns_input`:** while a WM is registered
   the shell's tray-click toggle + panel dismiss/clear are no-ops — the raw click already
   fanned to the WM as kind 19 `WM_POINTER` (flags carry the HID button byte), and the WM
   decides. No WM registered → byte-identical (the boot-A regression proof).
2. **New slot-65 subcommands (ADR 0007 amendment):**
   - `NOTIF_CENTER = 6` — `a0` = 0 close / 1 open / 2 clear-all; the kernel sets
     `notif_center_open` / clears the ring (clamped) and blits the panel.
   - `NOTIF_DISMISS = 7` — `a0` = row index; the kernel dismisses that notification
     (`EINVAL` honestly refused when out of range).
3. **WND.BIN grows the notification-center policy:** on a kind-19 left-button DOWN EDGE it
   hit-tests the tray (the same `fb_w - 80` right slice as the shim's `tray_rect`), toggles
   its own `notif_open`, issues `NOTIF_CENTER` open/close, and emits pinned
   `wnd: notif-open` / `wnd: notif-close` markers. (Dismiss/clear via cmd 6/7 are the same
   channel; the gate drives the tray toggle.)
4. **Headless CI-runnable gate:** the notification center is click-driven, so Gate B uses
   the `--pointer-virtio "<x>,<y>c"` channel (claim 9367 — custom-virtio kind-2 absolute
   pointer, no Accessibility trust, headless). The injected click lands in the tray region
   (e.g. x=1240, y=710) that BOTH the kernel `tray_rect` and the WM hit-test, so boot A
   (no WM) proves the shim still self-toggles and boot B (WM registered) proves the WM
   decided while the kernel gated its own toggle off.
5. **On unregister** the shim fallback restores its own tray-click behavior unchanged.

## Design decisions

1. **The click is the missing half of the chrome drain.** Gate A proved the keyboard seam;
   the notification center is the flagship *click-driven* surface. Kind 19 already carries
   the button byte, so no new event kind is needed — only the WM's hit-test decision.
2. **The kernel keeps its panel functions** (WMS8 deletes them) — the no-WM path is
   byte-identical and the M21 W5 shim rows run against them. Gate B gates the *input decision
   path*, not the functions.
3. **`notif_center_set_open` is the only mutator the WM reaches** through cmd 6 — same
   clamped primitive the shim uses, so the panel blit stays consistent.
4. **No new syscall** — two new subcommands on the existing ADR 0007 slot-65 surface
   (slot count unchanged).

## Touches

`kernel/src/driving_award.zig` (gate the tray-click + panel click behind `!wm_owns_input`;
`notif_center_set_open`), `kernel/src/wm_server.zig` (NOTIF_CENTER/NOTIF_DISMISS consts +
counters), `kernel/src/syscall.zig` (cmd 6/7 handlers), `user/src/wnd.zig` (tray-click
policy + markers), `kernel/src/monitor.zig` (`wm` row notif counters), M21 W5 shim rows
(registered-variant assertions), new `tools/verify-live-wnd6-notif-drain.sh`,
`docs/decisions/0007-syscall-abi.md`, `docs/status.md`, `docs/march-m32-wm-migration.md`,
claim + log.