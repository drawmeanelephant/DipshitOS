# Log — `agent/buffy/wms7-ipc-protocol`

## 2026-08-29 — WMS7 Gate A claimed (issue #627, the app-facing protocol)

- Claimed **WMS7 Gate A — the app↔WM mailbox protocol (WM_RPC) end-to-end** as
  `docs/claims/9604-wms7-ipc-protocol.md` (status 🔄, heartbeat 2026-08-29, claim ID 9604
  computed by `tools/status/claim-id.sh` from `agent/buffy/wms7-ipc-protocol` +
  `wms7-ipc-protocol`). Branch `agent/buffy/wms7-ipc-protocol` cut from `main` (5e7cc65,
  after WMS6 #626 closed). The toolkit `ui.zig`/`LIBUI.SO` re-point is Gate B (a later
  gate — the card's in-scope list is five items and the wire+server+test-app+gate proof
  is a natural, CI-closable slice).
- Scope frozen in the claim: freeze the `WM_RPC` wire format in ADR 0015 (kind byte +
  window id + seq + `reply_to` pid + bounded args; `WIN_RAISE`/`WIN_CONFIG`; ack reply)
  that FITS the frozen 64-byte mailbox slot — the card's mailbox-size-decision checkbox
  answered as "grow nothing" (avoids perturbing the IPC ABI, `verify-live-ipc.sh`, BSS),
  escalation deferred to WMS8 and documented. WND.BIN's tick loop drains its own mailbox
  (`sys_ipc_recv`, slot 6) and applies `WIN_RAISE` via the ALT_TAB-commit path and
  `WIN_CONFIG` via the SET_WINDOW-rect path, replying (`sys_ipc_send`, slot 5) with an ack.
  New WMRPC.BIN (segmented EL0 Zig) discovers its own + the WM pid via `sys_procs` (slot
  7), opens a window, sends the two requests, polls for the acks, and emits `wmrpc: *-ack`
  / `wmrpc: no-wm` markers. Gate `tools/verify-live-wm-ipc.sh`: a WM-registered boot proves
  raise + config applied + ack returned; a no-WM boot proves additive back-compat; the
  existing `verify-live-ipc.sh` re-runs for the mailbox-bound honesty contract. No kernel
  `.zig` changes (rides the existing mailbox + wmctl seams).
## 2026-08-29 — WMS7 Gate A complete; live gate PASS on VZ

- **Implemented + landed Gate A (claim 9604, issue #627): the app↔WM mailbox protocol (WM_RPC), proven end-to-end.**
- `kernel/src/wnd_core.zig`: the WM_RPC wire format (extern struct — kind / id / seq /
  reply_to / applied / u16 rect / ≤24-byte bounded title) single-sourced so WND.BIN and
  WMRPC.BIN compile the SAME ABI. Fits the frozen 64-byte mailbox slot — the ADR 0015
  size decision is answered "grow nothing" (no `message_max` change, no ABI churn,
  `verify-live-ipc.sh` capacity contract untouched, no BSS delta).
- `user/src/wnd.zig`: the mailbox service loop — drains its own inbox (sys_ipc_recv,
  slot 6) each kind-18 wake (≤ 1 s latency), applies WIN_RAISE via the ALT_TAB-commit
  path and WIN_CONFIG via the SET_WINDOW-rect path (its OWN clamped primitives, so a
  mail-driven action is byte-identical to a WM-native one), replies an ack
  (kind | 0x80, sys_ipc_send slot 5) to the requester's pid, emits `wnd: mail kind=N
  id=M seq=S applied=yes [title=..]` (the gate grep target). Unknown kinds / dead reply
  targets dropped honestly (no crash, no loss inside the kernel ring).
- `user/src/wmrpc.zig` (new): WMRPC.BIN — real EL0 Zig, FLAT DSK1 (all scratch on
  stack; no segmented data segment needed, contrary to the claim draft's first cut).
  Given `exec WMRPC.BIN 2 WND.BIN` it discovers the WM + its own pid via sys_procs
  (slot 7), opens its own window, sends WIN_RAISE + WIN_CONFIG over the mailbox, polls
  its own inbox for the acks, and emits `wmrpc: wm pid=.. self=.. target=..` /
  `raise-ack` / `config-ack` / `done` / `no-wm` markers. Wired into build.zig (49th
  user program) + `image/make-image.sh` DYN_ARGS (embedded at the volume root).
- **Debugging worth recording:** the first live run showed the app exec'd but printing
  nothing. Two real bugs, both found by reading serial evidence:
  1. **`sys_procs` returns the ROW COUNT, not bytes** (take_bytes/40 — the claim-5799
     contract). My `find_pid` divided by `procs_row_bytes` again → count always 0 →
     every WM reported absent (`wmrpc: no-wm` even with WND.BIN running). One-line fix;
     the boot-A round-trip went from "app silent" to fully green.
  2. **Boot B's gate script tore the VM down before the app's first quantum** — the
     `--script-expect` was an instant `echo wmipc-b-done`, and the runner exits as soon
     as the expected text lands. Fixed by expecting the app's OWN marker
     (`wmrpc: no-wm`): the VM now stops only after the app actually ran and degraded.
     (Also caught: my first boot-B "no output" reading was this same teardown race,
     not a fault — the gate's no-fault grep passed throughout.)
- **Live gate `tools/verify-live-wm-ipc.sh` PASS on VZ (both boots).** Boot A
  (WM registered): `wmrpc: wm pid=1 self=3 target=2` → `wnd: mail kind=1 id=2 seq=1
  applied=yes` (raise served) → `wmrpc: raise-ack applied=yes` → `wnd: mail kind=2
  id=2 seq=2 applied=yes title=wm-rpc` (config served, title round-tripped) →
  `wmrpc: config-ack applied=yes` → `wmrpc: done`; post-run `dui` shows the raise moved
  focus back to NOTEPAD (`focused=2`) and the config rect applied
  (`dui[N]: user user rect=40,40,360,260` owner=2); WND.BIN kept pacing (`wnd: present`).
  Boot B (no WM): `wmrpc: no-wm` then parks — additive back-compat, shim untouched.
- Regression: `verify-live-ipc.sh` re-run **PASS** (the mailbox 8-slot / 64-B capacity
  contract is untouched — the frozen-ABI promise of the size decision).
- Host tests: wmrpc 2/2 (`zig test --dep wnd_core -Mroot=user/src/wmrpc.zig
  -Mwnd_core=kernel/src/wnd_core.zig`), wnd 8/8 (same anon-import invocation), kernel
  module suite green (wnd_core + syscall + wm_server all pass), fmt clean, coordination
  ok, BSS budget PASS (684 KB headroom — zero kernel BSS added by this gate).
- Docs: ADR 0015 open-issue entry (mailbox size) resolved with the freeze + size
  decision; march WMS7 row updated (🟡 Gate A PASS, Gate B remaining); status.md WMS7
  block added. Claim flipped ✅. **The issue's remaining scope is Gate B — the toolkit
  (`ui.zig`/`LIBUI.SO`) re-point — which is a later claim.**
