# Claim: WMS4 — chrome policy drain-out (SET_WINDOW descriptors)

- **Owner:** buffy (`agent/buffy/wms4-chrome-drain`)
- **Issue:** https://github.com/drawmeanelephant/DipshitOS/issues/624 (WMS4 of 10, milestone 16)
- **Depends on:** WMS2 (claim 8482, PR #633 — slot-65 register + `COMPOSITE_TICK` + teardown) and WMS3 (claim 3881, PR #637 — WND.BIN + the `wnd_core` drift guard). Cut from main after both merged.
- **Blocks:** WMS5 (geometry drain, builds on the descriptor pattern), WMS8 (deleting the kernel's chrome code)
- **Heartbeat:** 2026-08-29
- **Status:** ✅ done (PR closing #624)

## Scope (issue #624)

Move CHROME policy out of the kernel: title bars, borders, focus ring,
close/minimize/pin buttons are rendered because the WM server says so via
`sys_wmctl SET_WINDOW` chrome descriptors — the kernel blits whatever the
descriptor dictates and no longer *decides* chrome. The shim path stays
byte-identical when no WM is registered; the two coexist behind the
registration flag.

## Design (this claim's decisions)

1. **Descriptor ABI lives in `kernel/src/wnd_core.zig`** (the drift guard):
   a flat 40-byte `ChromeDesc` (10 × u32, no pointers — per the issue's
   "bounded, number-or-small-struct shaped, no pointers on the first
   pass"), with the element-kind bitmask (BORDER/TITLE/CLOSE/MINIMIZE/
   PIN/RING), the per-window flags (FOCUS_ACCENT), and 8 theme colors
   (border focus/unfocus, title bg/fg, ring, close, minimize, pin). The
   frozen SET_WINDOW encoding from ADR 0007 (WMS1): `sys_wmctl(cmd=2,
   a0=window_id, a1=rect, a2=wh, ptr=descriptor, len=40)`; WMS4 accepts
   `a1=a2=0` (geometry stays kernel-owned until WMS5 — nonzero is EINVAL).
2. **Broadcast + per-window:** `a0=0xFFFFFFFF` sets the WM's chrome POLICY
   (applied to every user window, and inherited by windows created later);
   a specific id sets that window's override. Per-window state gives the
   `wm` observability ("last chrome kind per window").
3. **The present path composites:** WMS2/WMS3 gated the shell idle `drain`
   off while a WM is registered, so REQUEST_PRESENT only flushed the
   scanout — no chrome. WMS4 runs the composite (`driving_award.composite`)
   on REQUEST_PRESENT, and `draw_chrome` paints from descriptors when a WM
   is registered (shim rules otherwise — one registration-flag branch).
4. **WND.BIN issues the policy** at startup (right after REGISTER): one
   SET_WINDOW(ALL) carrying the dark-theme values that match the shim's
   constants exactly (the WM becomes the theme owner). Parity is then
   pixel-provable.
5. **Out of scope (per issue):** geometry (WMS5), desktop chrome (WMS6),
   deleting the kernel's chrome code (WMS8). The kernel still applies
   per-window DATA (geometry, focus, always_on_top, workspace, dynamic
   titles); the WM owns the LOOK.

## Acceptance (gate)

New class-B gate `verify-live-wnd4-chrome.sh` modeled on
`verify-live-chrome.sh`: with WND.BIN registered and driving chrome via
SET_WINDOW, the measured scanout (2px border, 16px title band, label ink,
close glyph, focus ring, unfocused muted border) matches the shim's —
the parity proof. Plus `wm` observability (submissions counted, policy
kind + per-window kind visible). Host tests: descriptor encode/decode,
unknown-kind/flag refusal, bad-id/bad-len EINVAL, broadcast vs per-window
semantics. All pre-WMS4 gates stay green (shim mode unchanged).

## Touches

`kernel/src/wnd_core.zig` (ChromeDesc ABI + validation — the drift
guard), `kernel/src/driving_award.zig` (per-window chrome state +
descriptor-driven draw_chrome branch), `kernel/src/wm_server.zig`
(submission counter + info), `kernel/src/syscall.zig` (SET_WINDOW
handler), `kernel/src/monitor.zig` (`wm` observability + registry), 
`kernel/src/shell.zig` (help text), `user/src/wnd.zig` (WND.BIN issues
the policy), `docs/decisions/0007-syscall-abi.md` (amendment),
`docs/march-m32-wm-migration.md`, `docs/status.md`, `tools/verify-live-wnd4-chrome.sh`
(new gate), `tools/sweep-vz.sh`, claim + log.
