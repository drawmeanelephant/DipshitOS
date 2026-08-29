# Log — WMS4 chrome policy drain-out (SET_WINDOW descriptors)

## 2026-08-29 — WMS4 claimed (issue #624)

- Claimed **WMS4 — chrome policy drain-out** as
  `docs/claims/2491-wms4-chrome-drain.md` (status 🔄, heartbeat
  2026-08-29). Branch `agent/buffy/wms4-chrome-drain` cut from main
  (f3bbdb0 — after WMS2 #633 and WMS3 #637 merged).
- Depends on WMS2 (claim 8482: slot-65 register + kind-18 ticks +
  teardown) and WMS3 (claim 3881: WND.BIN + `wnd_core` drift guard).
- Scope per issue #624: chrome policy moves out of the kernel — the WM
  server issues `SET_WINDOW` chrome descriptors; the kernel blits per the
  descriptor. Descriptor ABI in `wnd_core` (40-byte flat struct: kind
  bitmask, flags, 8 theme colors); broadcast (ALL) policy + per-window
  overrides; REQUEST_PRESENT now composites (draw_chrome paints from
  descriptors when a WM is registered, shim rules otherwise); WND.BIN
  issues the dark-theme policy at startup; new parity gate vs
  `verify-live-chrome.sh` pixel measurements.
- Declared touches in the claim's `Touches:` list.

## 2026-08-29 — implemented + live gate PASS

- Implemented: `ChromeDesc` ABI + validation in `wnd_core` (40-byte
  flat struct, kind bitmask + flags + 8 theme colors); per-window chrome
  state + descriptor-driven `draw_chrome` branch in `driving_award`
  (with `clear_wm_chrome` on WM teardown — found by the aggregated
  unit-test binary leaking a policy across tests); SET_WINDOW handler in
  `syscall` (broadcast ALL policy + per-window override, geometry
  EINVAL until WMS5, composite-on-present); submission counter + info
  in `wm_server`; `wm` observability rows in `monitor`; WND.BIN issues
  the dark-theme policy right after REGISTER; parity pins in
  `wnd_core`/`driving_award`/`syscall`/`user/src/wnd.zig`; help rows in
  `shell.zig` + the transcript fixture; new class-B gate
  `tools/verify-live-wnd4-chrome.sh` + sweep-vz entry.
- Root-caused during the live gate bring-up:
  - `monitor` printed `policy_kind=0x0x3f` (my `0x` prefix +
    `print_hex_min`'s own `0x`) — dropped the manual prefix; the gate's
    `policy_kind` grep was adjacent-anchored (`wm: chrome
    policy_kind=...`) but the line interleaves `submissions=N` first —
    widened the pattern. Boot B's VM hit a VZ `.error` (state=3) at
    ~tick 10 on the first run while boot A ran 55s+ fine — flaky host
    (ScreenCaptureKit window id changed between boots), not a guest bug;
    both boots pass on re-run.
  - Latent gate bug found: `run_boot` re-armed `set -e` before
    `return "$RC"`, so a failing boot killed the whole gate before the
    report write (the established gates survive only because their boots
    return 0). Removed the internal re-arm — the caller captures the rc
    under `set +e` and re-arms itself. Boot A's snapshot is also
    validated independently by hand (ring 31/31 px per row, label ink
    156, close-red 19) before the gate's python runs it.
- **Class B (real VZ): PASS** — `verify-live-wnd4-chrome` gate green on
  the final code state: boot A (focused) ring_top_ok, label_ink=156,
  close_red=19; boot B (unfocused) CHROME-METRICS-OK. `wm: chrome
  submissions=1 policy_kind=0x3f` + per-window `id=2 kind=0x3f`
  observed while WND.BIN paced (present_seq advanced, ticks climbing).
  The chrome pixels match `verify-live-chrome.sh`'s shim measurements
  exactly — the WMS4 drain-out parity proof.
- **Class A:** fmt, build, unit tests 24/24, BSS budget PASS (685 KiB
  headroom), coordination ok.
