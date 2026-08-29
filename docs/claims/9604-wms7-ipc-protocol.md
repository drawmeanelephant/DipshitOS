# Claim: WMS7 Gate A — the app↔WM mailbox protocol (WM_RPC), frozen + proven end-to-end

- **Owner:** buffy (`agent/buffy/wms7-ipc-protocol`)
- **Issue:** https://github.com/drawmeanelephant/DipshitOS/issues/627 (WMS7 of 10, milestone 16 — Phase 3, the app-facing protocol)
- **Depends on:** WMS2/WMS3 (the WM server exists to receive mail). Parallel-friendly — cut from `main` after WMS6 (#626, PR #654) merged.
- **Gate A** of the card (the issue's in-scope list is five items; Gate A is the wire + server + test-app + gate proof; the toolkit re-point is Gate B).
- **Heartbeat:** 2026-08-29
- **Status:** ✅ done 2026-08-29 — Gate A PASS on VZ (both boots), all host tests green,
  `verify-live-ipc.sh` re-run green, fmt + coordination + BSS clean. Gate B (toolkit
  re-point) remains on the issue.

## Scope — Gate A: the wire protocol + the WM mailbox service loop, proven by a real app

Apps today ask the desktop through syscall slots; WMS7 gives them `sys_ipc_send` (slot 5)
mail to the registered WM. Gate A freezes the **WM_RPC** wire format, adds the **mailbox
service loop** to WND.BIN, ships a **WMRPC.BIN** test app that sends win-raise/win-config
and receives the ack reply, and gates the whole round-trip on VZ.

1. **Wire format + ADR 0015 amendment (the card's first two checkboxes):** `WM_RPC` is a
   bounded message that fits the FROZEN 64-byte mailbox slot — **no `message_max` growth
   needed** (the size-decision checkbox is answered with "grow nothing; the compact fixed
   layout fits"). Layout (byte 0 kind, byte 1 window id, byte 2 seq, bytes 3–6 `reply_to`
   pid LE, then args): `WIN_RAISE` (kind 1, no args) and `WIN_CONFIG` (kind 2 — x, y, w,
   h as u16 LE + a ≤ 24-byte bounded title). The reply is the same header with `reply`
   (bit 7) set + an `applied` flag in byte 3. This avoids perturbing the frozen IPC ABI
   (ADR 0007 slots 5/6), the `verify-live-ipc.sh` exact-capacity assertions, and BSS (no
   `verify-bss-budget` change) — the honest documented answer to ADR 0015's open issue.
2. **WM server mailbox service loop:** WND.BIN's tick loop (kind-18 arrives at 1 Hz, so it
   wakes at least every second — bounded ~1 s request latency, accepted and documented)
   also drains its OWN mailbox via `sys_ipc_recv` (slot 6, non-blocking). For each WM_RPC:
   - `WIN_RAISE <id>` → `sys_wmctl(ALT_TAB, id, commit)` — the kernel focuses + raises
     (the proven WMS6 Gate-A path).
   - `WIN_CONFIG <id> <x y w h>` → `sys_wmctl(SET_WINDOW, id, x|y<<16, w|h<<16)` — the
     kernel clamps + applies (the proven WMS4/WMS5 path).
   - replies to `reply_to` via `sys_ipc_send` (slot 5) with the WM_RPC ack (echo kind +
     seq + applied), and emits `wnd: mail kind=N id=M seq=S` (the gate grep target).
   Unknown kind / dead reply target are dropped honestly (no crash; the request is
   consumed, the sender's reply may not arrive — documented).
3. **WMRPC.BIN test app:** a real EL0 Zig program — FLAT DSK1 (all scratch is stack, so
   no writable module globals need the segmented DSK3 path). Given the target window id
   + the WM's name as argv (`exec WMRPC.BIN 2 WND.BIN`), it reads `sys_procs` (slot 7)
   to discover its own pid and the WM's pid (name + running). It opens a user window
   (so two windows exist — an unambiguous raise target), then sends `WIN_RAISE` /
   `WIN_CONFIG` for the target and polls its own mailbox (slot 6) for the acks,
   emitting `wmrpc: raise-ack` / `wmrpc: config-ack` and a no-WM fallback
   `wmrpc: no-wm` (back-compat: with no server it does nothing).
4. **Back-compat is additive:** apps that never send mail keep working through the frozen
   syscalls — zero change for CALC/NOTEPAD/FILE/etc. The `verify-live-ipc.sh` gate re-runs
   green (the existing mailbox-bound honesty proof: full ring → `ENOSPC`, no loss).
5. **Gate `tools/verify-live-wm-ipc.sh`:** Boot A — `wnd start` + `exec NOTEPAD.BIN` +
   `exec WMRPC.BIN 2 WND.BIN`: assert `wnd: mail kind=... applied`, the
   `wmrpc: *-ack` markers, the raise moved focus (`dui: windows=... focused=2`), the
   config applied a new rect (`dui: ... rect=40,40,360,260`), and WND.BIN still pacing.
   Boot B — no WM (shim): `exec WMRPC.BIN 2 WND.BIN` reports `wmrpc: no-wm` and the
   shim desktop is unchanged (additive back-compat). The gate expects the app's OWN
   marker (not an instant echo), so the VM tears down only after the app actually ran.

## Design decisions

1. **No mailbox growth — the 64 B bound fits.** `WIN_CONFIG` carries a bounded 24-byte
   title with the rect in an 18-byte frame, inside 64 B. Growing `message_max`/slots would
   perturb the frozen IPC ABI, the `live-ipc` capacity assertions, and BSS — not worth it
   for a title that the WM currently doesn't even render. Escalation to a grown bound is
   left to WMS8 if a real frame config outgrows it (documented in the ADR).
2. **~1 s request latency is acceptable.** WND.BIN wakes on kind-18 at 1 Hz; draining the
   mailbox in that wake bounds request handling to ≤ 1 s without a kernel change (no new
   "mailbox-arrived" event). The card's async-inversion note is answered: the toolkit API
   stays synchronous-shaped (send + bounded poll), Gate B's concern — the WM side here is
   fire-and-ack with the app polling for the reply.
3. **Raise = the proven ALT_TAB commit path; config = the proven SET_WINDOW rect path.**
   No new kernel geometry channel needed — the WM applies app requests through the same
   clamped primitives it already uses for its own decisions, so a mail-driven raise/config
   is byte-identical to a WM-native one.
4. **Socket/signal-free** — rides the existing per-process mailbox (ADR 0015 D1/0015).

## Touches

`user/src/wnd.zig` (mailbox service loop + WM_RPC parse/apply/reply + markers),
`user/src/wmrpc.zig` (new WMRPC.BIN — the test app), `build.zig` + `image/make-image.sh`
(embed WMRPC.BIN at the volume root via DYN_ARGS), host tests (wnd mailbox policy +
wmrpc pins), new `tools/verify-live-wm-ipc.sh` + `tools/sweep-vz.sh` registration,
`docs/decisions/0015-window-server-render-seam.md` (wire freeze + size decision),
`docs/status.md`, `docs/march-m32-wm-migration.md`, claim + log. **Gate B (the
toolkit `ui.zig`/`LIBUI.SO` re-point) is a later gate.**