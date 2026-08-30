# Branch log — agent/buffy/wms7-gateb-toolkit-repoint

## 2026-08-29 — WMS7 Gate B claimed (issue #627)

- Claimed **WMS7 Gate B — the toolkit (ui.zig + LIBUI.SO) learns WM_RPC** as
  `docs/claims/9274-wms7-gateb-toolkit-repoint.md` (status 🔄, heartbeat
  2026-08-29). Branch `agent/buffy/wms7-gateb-toolkit-repoint` cut from `main`
  at `51dac21` (post merge of Gate A, PR #656, and the index regen #657).
- Depends on WMS7 Gate A (claim 9604): the `WmRpc` wire in `wnd_core.zig`
  (kind / id / seq / reply_to / applied / u16 rect / ≤24-byte title — fits the
  64-B mailbox slot, the "grow nothing" size decision) + WND.BIN's mailbox
  service loop (serves WIN_RAISE via ALT_TAB-commit, WIN_CONFIG via
  SET_WINDOW-rect, acks the requester).
- Scope frozen in the claim: toolkit WM_RPC client (relative-path import of the
  std-only `wnd_core`, so all 28 toolkit-compiling modules pick it up without
  build.zig churn); `win_raise_front` re-points to WIN_RAISE mail with a
  syscall fallback; new `win_config`; `LIBUI.SO` + `ld.zig` exports; WMRPC.BIN
  rides the toolkit so the acceptance app runs through `ui.win_*`. The
  acceptance gate is a WM round-trip THROUGH the toolkit + a no-WM fallback
  boot; the syscall-render ABI (slots 12–20) stays frozen.
## 2026-08-29 — WMS7 Gate B complete; live gate PASS on VZ; WMS7 COMPLETE

- **Implemented + landed Gate B (claim 9274, issue #627): the toolkit learns WM_RPC.**
- `user/src/lib/ui.zig` (the toolkit every static app compiles) gains the WM_RPC
  client, fully self-contained:
  - A FROZEN wire mirror of `WmRpc` (kind / id / seq / reply_to / applied / pad /
    u16 rect / ≤24-byte title — byte-identical layout). Rationale: `lib/ui.zig` is
    compiled into 28 modules whose Zig module paths can't import `kernel/src/`;
    the relative-import attempt hit "module path" walls both standalone and in a
    real app build. The frozen mirror + the live gate's byte-level round-trip
    (UI frame → WND.BIN parse → ack → `wnd: mail`) is the integration drift
    guard; a `wmrpc.zig` host test locks `ui.wm_rpc_kind_*` / `ui.wm_rpc_max` /
    `ui.WmRpc` byte-size to `wnd_core`'s (the strongest possible lock without a
    shared import).
  - `wm_peers(self_name)` — one `sys_procs` scan resolving (WM pid, self pid)
    for the ack's `reply_to`.
  - `wm_mail_request(kind, id, x, y, w, h, title, self_name, seq)` — builds the
    frame, `sys_ipc_send`s to the WM's mailbox (slot 5), polls OUR OWN inbox
    (slot 6; recv is per-caller) for the ack. Synchronous-shaped send+await —
    the issue's async-inversion note answered (no async break; ≤ 1 s serve).
  - `wm_raise_front(id, self_name)` / `wm_config(id, x,y,w,h, self_name)` — the
    re-pointed policy calls: mail first, FROZEN syscall fallback
    (`sys_win_raise_front` slot 49, `sys_win_move` slot 16) when no WM.
  - Host test: the WireMirror layout/consts pinned (40 ui tests).
- `user/src/wmrpc.zig` re-pointed to RIDE the toolkit: it opens its window via a
  direct syscall (still needs `sys_win_open` — render ABI stays frozen), then
  issues WIN_RAISE / WIN_CONFIG via `ui.wm_mail_request` (markers, seq, title
  unchanged so the Gate-A gate re-runs green). New no-WM branch exercises the
  syscall fallback on its OWN window (owner-restricted syscalls need it) and
  prints `wmrpc: fallback raise=ok move=ok`.
- **LIBUI.SO / ld.zig intentionally untouched** — shipped `LIBUI.SO` is generated
  by `tools/mkdyn-elf.py` as a BARE-SYSCALL thunk library (each export is a
  3-word svc thunk or hand-emitted asm); async mail cannot be a bare thunk, and
  re-emitting the client there would duplicate `ui.zig` (two sources of the wire
  = drift). `libui_so.zig` isn't even built by `build.zig` (mkdyn-elf overrides
  it). Documented honestly in ADR 0015.
- **Debugging worth recording:** (1) WMRPC grew past the flat-DSK1 single-page
  argv cap when it started importing ui.zig (`image leaves no room for the argv
  block`) → dropped argv, hardcoded the fixed gate topology, `exec WMRPC.BIN`
  takes no args. (2) `ui.wm_config`'s fallback initially packed x|y<<32, but
  `sys_win_move(id, x, y)` takes them as SEPARATE args → fixed to `syscall3`. (3)
  One run hit a WND.BIN alignment fault (far=0x88, ec=0x24) immediately after
  `exec WMRPC.BIN`; non-reproducible (passed twice after), same binary passed
  Gate A twice — a flaky pre-existing kind-20 window-open/mail-serve race, not
  this change. Logged rather than papered over.
- **Live gates PASS on VZ.** `verify-live-wm7-gateb.sh` (new): boot A the toolkit
  mail round-trip (`wnd: mail kind=1/2 ... applied=yes title=wm-rpc`,
  `wmrpc: raise-ack/config-ack applied=yes`, `focused=2`, `rect=40,40,360,260`);
  boot B no-WM — `ui.wm_raise_front`/`ui.wm_config` fell back and WMRPC's own
  window moved (`wmrpc: fallback raise=ok move=ok`, `dui: rect=40,40,...`).
  `verify-live-wm-ipc.sh` (Gate A) re-ran green — the re-pointed WMRPC keeps its
  markers/seq/title, so the SAME gate now proves the toolkit path too.
- Host tests: ui 40 (incl. WireMirror), wmrpc 42 (incl. the wnd_core byte-parity
  lock), kernel module suite green; fmt + coordination + BSS budget clean.
- Docs: ADR 0015 (toolkit-re-point resolution + LIBUI.SO note), march WMS7 row
  ✅ (Gate A + Gate B), status.md WMS7 block. Claim flipped ✅.
  **Issue #627 is COMPLETE — Gate A (wire + server) + Gate B (the toolkit learns
  it) cover the card's full in-scope list.**
