# Milestone forty-two march — the Sexiburger desktop (living tracker)

> [`docs/status.md`](status.md) is the canonical milestone-level source. This
> file holds M42's per-card detail, order, and gate notes. A card's row flips
> to ✅ only with real observed evidence.
> Umbrella issue: **#981** (M42: The Sexiburger Desktop).
> GitHub milestone: **29 — M42: The Sexiburger Desktop**.

## Where we are

M39 shipped the tabbed desktop scaffold (`TABWM.BIN`, left sidebar, tab
lifecycle, centered viewport presentation) with a hand-drawn mini mascot.
M42 makes the Sexiburger **the** desktop: the proper 🐙+🍔 emoji artwork
everywhere the mascot appears, every app working **full screen** in its tab
(opt-in, via a real app-notification seam and a small app library), and the
remaining fleet rollout + primary-manager completion tracked as cards.

Three promises, in the user's words:
1. "i'd like the sexiburger to be the proper emoji symbol" — the actual
   artwork (an octopus holding the six-layer burger; the canonical export is
   `assets/sexiburger.png` 534x534), not an approximation.
2. "get it nice enough to be the main manager with all the apps we've made
   working in it full screen" — TABWM primary, apps full-viewport.
3. "if we need to work on a library or something to make apps interface
   build easier i would like to make issues to do that and work through
   them" — `lib/tabapp.zig` is that library, tracked card by card.

## The cards, in order

> **SX1 emblem → SX2 full-screen seam → SX3 app library → SX4 fleet rollout → SX5 primary manager.**

| Card | Issue | Phase | Depends on | Status | Touches | Notes |
|:-----|:------|:------|:-----------|:-------|:--------|:------|
| **SX1** | [#982](https://github.com/drawmeanelephant/DipshitOS/issues/982) **Proper mascot emblem** | asset | — | ✅ done 2026-09-04 (claim #987) | `assets/sexiburger.png`, `user/src/lib/fixtures/qoi/mascot_{28x28,24x24,64x64}.qoi`, `user/src/lib/ui/draw.zig`, `user/src/lib/ui.zig`, `user/src/tabwm.zig`, `user/src/sexiburger.zig`, `user/src/wnd.zig` (fixture refresh), `tools/verify-unit-tests.sh` | The repo's old `assets/mascot.png` was UNRELATED art (a guillotine) — the attached emoji export is the canonical source, added as `assets/sexiburger.png`. Premultiplied-alpha Lanczos downscale to 28/24/64, encoded with `tools/png2qoi.py`. `ui.draw_image_buf` is the scanout-buffer source-over blit (the WM-server seam where `draw_image`'s window-backing path does not apply). TABWM's sidebar button blits the real raster (rect-drawn mini mascot kept as decode-failure fallback); God Menu header fixture refreshed; SEXIBURG.BIN renders 24x24 top-bar + 64x64 splash with the text column moved right of it. Unit: fixture decode pins + buffer-blit correctness/clipping + draw_sidebar raster smoke (tabwm 52/52, sexiburger 55/55, ui suite green). |
| **SX2** | [#983](https://github.com/drawmeanelephant/DipshitOS/issues/983) **Full-screen viewport seam** | kernel | — | ✅ done 2026-09-04 (claim #987) | `kernel/src/driving_award.zig`, `kernel/src/wnd_core.zig`, `user/src/lib/ui/abi.zig`, `user/src/lib/ui.zig`, `user/src/tabwm.zig` | The gap: `wm_apply_rect` (the WM's SET_WINDOW path) never told the app its canvas changed. Now it pushes `WIN_RESIZE` (w,h payload, `user_resize` parity) to the owner when the clamped layout changes the size; pure moves and idempotent re-applies emit nothing. Additive `wm_rpc_kind_declare_fullscreen` (kind 8, wnd_core + toolkit mirror, drift-guard pinned in wmrpc.zig) — WND.BIN treats it as unknown and refuses (zero regression). TABWM: `Tab.tab_aware` + `applied_vp`; `compute_tab_viewport` gives tab-aware apps the full 1100x720; activation proposes SET_WINDOW only when the rect changed (no repeat WIN_RESIZE); the declare RPC applies immediately when active, defers when inactive. Kernel tests (driving_award 59/59) + tabwm tests (52/52). |
| **SX3** | [#984](https://github.com/drawmeanelephant/DipshitOS/issues/984) **`lib/tabapp.zig`** | library | SX2 | ✅ done 2026-09-04 (claim #987) | `user/src/lib/tabapp.zig`, `user/src/lib/ui/abi.zig` | `TabApp.init` (theme sync + win_open + best-effort declare), `dispatch` (WIN_CLOSE/WIN_RESIZE canvas tracking), `present`/`close_and_exit`, and `scale` (the fixed-layout mapping; identity at the native canvas = the zero-regression fixed point). Toolkit WM discovery resolves EITHER seat (`is_wm_name` — WND.BIN or TABWM.BIN; one seat exists, acks route by pid). Doc header shows the ~40-line app shape. tabapp 34/34. |
| **SX4** | [#985](https://github.com/drawmeanelephant/DipshitOS/issues/985) **Fleet rollout** | apps | SX3 | 🔄 exemplar landed; fleet open | `user/src/calc.zig` | **CALC ported end-to-end** (the exemplar): per-state `LayoutRects` + `canvas_w/h`; `layout()` maps the 7 area rects and all 54 native button rects proportionally (integer math, rounding top-left so grids never spill); draw AND hit-test helpers (`cfg_row_at`/`history_row_at` now take the state) read the same per-state rects so scaled geometry and scaled hit tests cannot drift; `gui_main` rides TabApp (declare → WIN_RESIZE → relayout → redraw). Native-size rendering is byte-identical (identity mapping pinned by tests). CALC 142/142. Remaining fleet (NOTEPAD/EDIT, FILE, SETTINGS, SYSMON/TOP, VIEW, DEVCONS) = open cards on the issue. |
| **SX5** | [#986](https://github.com/drawmeanelephant/DipshitOS/issues/986) **Primary-manager completion** | manager | SX1–SX4 | 🔄 overlay + default seam + gate landed 2026-09-04 (claim #996); human-session default flip stays open | `user/src/tabwm.zig`, `kernel/src/shell.zig`, `tools/verify-live-tabwm-fullscreen.sh` | **The Sexiburger overlay**: Ctrl+Space or the sidebar button summons the command palette ON THE SCANOUT (dim + panel + the real 🐙🍔 emblem); the APPS.TXT catalog loads at server start; type-to-filter, arrows, Enter launches into a NEW TAB (sys_exec → the WM_WINDOW stream → the tab manager), Esc dismisses; TABWM.BIN filtered out. **The default seam**: `settings set wm tabwm` boots TABWM once per session from the shell idle — the DEFAULT VM stays shim-only (unit-tested: once-flag, silence without the key, non-tabwm refused). **`verify-live-tabwm-fullscreen.sh` PASS 2/2 on VZ**: boot A (settings-seeded autostart → CALC declares → full 1100x720 via the WIN_RESIZE seam → relayout), boot B (`tabwm start` → ctrl-space → typed filter "64-bit" → Enter launches CALC into a tab → full viewport). Open: flipping the documented human-session default after the fleet lands. |

## Live gate evidence (tranche 2, 2026-09-04, this worktree)

- `tools/verify-live-tabwm-fullscreen.sh` — **PASS 2/2** (the SX5 capstone):
  boot A proves the default-manager seam (settings-seeded autostart, the
  tab-aware declaration accepted, the full 1100x720 viewport applied
  through the kernel's WIN_RESIZE seam, CALC's relayout marker); boot B
  proves the overlay (ctrl-space summon, typed filter "64-bit", Enter
  launches CALC into a NEW TAB, same full-viewport chain). Gate-
  engineering lessons recorded: the runner's script stages must wait for
  the app's settle sleep (the relayout marker is the LAST link — earlier
  expects killed the VM mid-sleep); typed filters that name shell commands
  double-launch (use a label like "64-bit"); the share persists across a
  gate's boots (boot B resets SETTINGS.TXT).

## Live gate evidence (tranche 1, 2026-09-04, this worktree)

- `tools/verify-live-tabwm.sh` — **PASS 1/1** on the SX1+SX2 build: the
  full TABWM lifecycle (register slot 65, sidebar render, present cadence,
  WINLOOP window tracking, tab switch) with the emblem + viewport seam in
  the binary.
- `tools/verify-live-godmenu-summon.sh` — **PASS**: the God Menu (refreshed
  24x24 mascot fixture) summon/filter/exec/dismiss live on VZ.
- `tools/verify-live-sexiburger-actions.sh` — **PASS 2/2** after one
  #843-shaped attach flake (WM-side attach lines present, app-side ack
  missing once; re-runs green — the documented flake family).
- **Pre-existing failures observed on BASELINE main @2762e68 on this host**
  (identical signature on the stashed tree — NOT M42 regressions, honestly
  recorded): `verify-live-calc-depth.sh` (0/1; the first 13 chords of the
  sweep are silent in both trees — stats/date/cfg markers missing, rest
  green; the #843/#768 stall family), `verify-live-calc-prog.sh` (0/1;
  `prog-on` never observed, echo still responsive), and
  `verify-live-tabstrip.sh` (0/1). Follow-up belongs on #843/#768 triage.

## Asset pipeline (SX1)

```bash
# the canonical source
assets/sexiburger.png          # the 🐙+🍔 emoji export, 534x534 RGBA palette PNG
# regenerate the fixtures with a premultiplied-alpha Lanczos pass, then
python3 tools/png2qoi.py /tmp/scaled-<size>.png user/src/lib/fixtures/qoi/mascot_<size>x<size>.qoi
```

Premultiply → resize → unpremultiply (the straight-alpha Lanczos halo
killer); QOI is lossless so the embedded fixtures are pixel-exact to the
host-side scaling. Sizes: 28 (TABWM sidebar button), 24 (God Menu header),
64 (SEXIBURG.BIN splash).

## Invariants & design principles

1. **Zero-Regression**: WND.BIN untouched (the kind-8 RPC is refused by it);
   non-tab-aware apps keep the M39 TWM3 centered presentation; the default
   VM stays shim-only.
2. **Identity is the fixed point**: `tabapp.scale` at the native canvas
   maps every rect to itself — no resize means byte-identical rendering.
3. **Scaled draw == scaled hit tests**: apps read one per-state rect set
   for both (the CALC lesson).
4. **Zero heap** in the WM server render path and the library (BSS/stack
   only, the M39 rule).
5. **One event per real change**: the kernel answers a size-changing
   SET_WINDOW with exactly one WIN_RESIZE; TABWM never repeats a proposal.
