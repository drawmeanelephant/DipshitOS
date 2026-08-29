# Log — WMS5 geometry policy drain-out (input seam + SET_WINDOW rects)

## 2026-08-29 — WMS5 claimed (issue #625)

- Claimed **WMS5 Gate 1 — the input seam + SET_WINDOW rects** as
  `docs/claims/9849-wms5-geometry-seam.md` (status 🔄, heartbeat
  2026-08-29). Branch `agent/buffy/wms5-geometry-seam` cut from
  `agent/buffy/wms4-chrome-drain` (the stacked WMS4 branch, PR #639 —
  WMS5 depends on WMS4's descriptor seam whose `a1/a2` geometry is
  reserved until this claim).
- Per the issue's own split guidance ("WM receives raw stream" then "WM
  decides geometry — two gates, one card"), this claim is Gate 1: the
  registered WM receives the raw pointer stream (kind 19 `WM_POINTER`)
  and registry mirrors (kind 20 `WM_WINDOW`); the kernel stops consuming
  pointer geometry while a WM is registered (cursor stays a kernel blit);
  `SET_WINDOW`'s frozen `a1/a2` rect encoding activates (WM proposes
  geometry, the kernel clamps + blits); WND.BIN drives a title-bar drag
  via SET_WINDOW rects. Gate 2 (tile/snap/workspaces/min-max/fullscreen
  state machines + the W1–W16 registered matrix) rides this seam and is
  claimed separately.
- Declared touches in the claim's `Touches:` list.

## 2026-08-29 — WMS5 Gate 1 landed (issue #625) ✅

- **Shipped.** The input-seam handover + SET_WINDOW rect transport:
  - `events.zig`: kind 19 `WM_POINTER` (raw absolute pointer — `arg0` =
    x|(y<<16), `flags` = HID button byte) and kind 20 `WM_WINDOW`
    (registry mirror — `flags` = id|visible<<8|focused<<9|ws<<10,
    `arg0`/`arg1` = rect). Both routing-restricted to the registered WM
    (the kind-18 discipline); never generated in shim mode.
  - `wm_server.zig`: `fan_pointer`/`fan_window` + counters; register
    flips `driving_award.wm_owns_input` + wires the hooks, unregister and
    `init()` restore shim input (the aggregated test binary exposed a
    stale-flag leak — init() now completes the teardown).
  - `driving_award.zig`: `pointer_tick` keeps tracking the cursor (a
    kernel blit) but the geometry block (drag/resize/snap/focus-at/
    buttons) is gated behind `!wm_owns_input`; the raw sample fans out on
    state CHANGE (motion OR button edge — a release with no motion must
    be seen). Registry mirrors push on open/close/move/resize/visibility/
    focus; `user_title_h` re-exports the single-source `wnd_core` value.
  - `syscall.zig`: SET_WINDOW's frozen `a1`/`a2` activates — the WM
    proposes a rect, the kernel applies it through the clamped
    `user_move`/`user_resize` (broadcast ALL stays chrome-only); len 0 =
    chrome unchanged, len 40 = chrome, else EINVAL.
  - `user/src/wnd.zig`: WND.BIN mirrors the registry (kind 20), hit-tests
    the raw pointer (kind 19) against the title band
    (`wnd_core.title_bar_contains`: [my, my+16) full width), grabs with
    offset, issues SET_WINDOW rects while held, drops on release — all
    naked asm, markers `wnd: grab` / `wnd: drag` / `wnd: drop` pinned as
    `pub const`s. Blob grew 301 → 663 bytes.
  - Runner: `--pointer-virtio` grammar gains `d` (down, held) and `u`
    (up) so a drag is expressible; moves between down and up carry the
    held button (the claim 9367 click gates are unchanged — `c` still
    emits down+up at one point).
- **Class B (real VZ) PASS** — new gate `tools/verify-live-wnd5-
  geometry.sh` (registered in sweep-vz): `wnd: grab` → 2× `wnd: drag` →
  `wnd: drop`, `wm: ptr_fan=1 win_mirror=2`, NOTEPAD's registry row
  moved from (56,56) to (256,292) — the exact drag math (grab at 300,64
  → dx/dy 244/8, final pointer 500,300 → nx/ny 256/292) — while the
  kernel's own geometry was gated off, so only the WM could have moved
  it. No `dui: pointer focus=` decision from the shell during the drag.
- **Class A:** fmt, build, unit tests all modules, BSS budget PASS (685
  KiB headroom), coordination gate ok.
- **Bring-up notes:** two gate bugs caught on the first live run — (1)
  the gate never ran `wm` (the fan counters were absent) and (2) the
  exact-rect assertion was timing-brittle (the guest input FIFO
  coalesces intermediate moves into the latest sample); fixed to assert
  the deterministic facts (left 56,56; moved down-right; size intact).
  The drag count varies (2 here) precisely because of that FIFO
  coalescing — the WM processed a subset of the held moves and the
  kernel clamped the rest; the mechanism (grab → SET_WINDOW rects →
  drop) is exactly the issue's contract.
