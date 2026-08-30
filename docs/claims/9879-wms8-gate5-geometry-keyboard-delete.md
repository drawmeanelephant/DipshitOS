# Claim 9879: WMS8 Gate 5 — delete the kernel's geometry-policy keyboard-decision layer

- **Owner:** buffy (`agent/buffy/wms8-gate5-geometry-keyboard-delete`)
- **Prompt / plan:** issue #628 (WMS8, fifth of a multi-gate deletion sequence)
- **Scope:** the kernel's keyboard-DECISION layer for geometry policy that WMS5
  Gate 2 already drained to the WM. WMS5 proved the WM decides geometry from the
  kind-21 WM_KEY stream (input.zig fans the raw key out when `wm_owns_input`;
  the WM's `handle_wm_key` issues SET_WINDOW/SET_STATE). Since then the kernel's
  OWN chord consumers are provably DORMANT whenever a WM is registered (their
  pending flags are gated behind `!wm_owns_input`). Per WMS8's delete rule
  (a block is deleted only when its parity gate has been green with the WM
  registered — the WMS5 matrix re-runs green while seated), this gate DELETES
  that dormant keyboard layer:
    - input.zig: the pending-flag variables + chord-decoding branches for
      Ctrl+T (tile), Ctrl+M (master-swap), Ctrl+N (minimize), Ctrl+Shift+M
      (maximize), Ctrl+F1/F2/F3 + Alt+` (workspace switch/cycle), F11
      (fullscreen), Ctrl+Shift+T (always-on-top) — all already gated behind
      `!wm_owns_input` — plus their `take_*` accessors.
    - shell.zig: the idle-loop consumer blocks that called the applied
      primitives (toggle_tiling / swap_master / minimize_window /
      toggle_maximize / switch_workspace / cycle_workspace / toggle_fullscreen /
      toggle_always_on_top) from those flags.
  KEPT (still live / needed): the applied primitives themselves — the `dui`
  monitor commands and SET_STATE drive them (the W5 matrix re-runs green
  THROUGH them); lower-back (Ctrl+Shift+B) and move (Alt+arrows) keyboard
  consumers (the WM does NOT serve those chords yet → deleting without WM
  coverage would regress shim mode); Alt+Tab (a separate WMS6 focus surface).
  Shim end-state consequence (intended, per the issue's "no compositing
  policy" end-state): with NO WM, the drained geometry chords now do nothing
  instead of self-toggling.
- **Touches:** `kernel/src/input.zig`, `kernel/src/shell.zig`,
  `tools/verify-live-wnd8-geom-kbd-delete.sh` (new gate),
  `tools/sweep-vz.sh`, `docs/decisions/0015-window-server-render-seam.md`,
  `docs/march-m32-wm-migration.md`, `docs/status.md`, claim + log
- **Depends on:** WMS5 Gate 2 (claim 4278), WMS6 Gate A (alt-tab), WMS8 Gates
  1–4 (claims 4790/9980/7736/6155) — the previous gate pattern this follows.
- **Heartbeat:** 2026-08-30
- **Status:** ✅ `agent/buffy/wms8-gate5-geometry-keyboard-delete`

## Result (2026-08-30)

- **Deleted (input.zig):** the geometry pending-flag vars (workspace switch/
  cycle, tile toggle, master swap, minimize, maximize, fullscreen,
  always-on-top), their chord-decode branches (all gated behind
  `!wm_owns_input` -> provably dormant with a WM seated), and the `take_*`
  accessors.
- **Deleted (shell.zig):** the idle-loop consumer blocks that called the
  applied primitives from those flags.
- **KEPT:** the applied primitives (the `dui` monitor commands + SET_STATE
  drive them; the W1–W16 matrix re-runs green through them), lower-back
  (Ctrl+Shift+B) + move (Alt+arrows) keyboard consumers (no WM coverage
  yet), and Alt+Tab (separate WMS6 focus surface).
- **input.zig host test** updated to pin the drained-chord fan-out + the
  kept lower-back/move consumers.
- **New gate `verify-live-wnd8-geom-kbd-delete.sh` PASS on VZ, both boots;**
  canonical `verify-live-wnd5-gate2-policy.sh` re-ran PASS. Boot A (shim): a
  real Ctrl+T does nothing (`dui: tile=` count 0, NOTEPAD keeps its rect, no
  fault). Boot B (WM): the W1–W16 matrix re-runs green AND a WM-driven Ctrl+T
  fans out (`key_fan=1`), the WM decides (`wnd: tile`), and the kernel
  applies SET_WINDOW rect 24,0,837,700 while printing no `dui: tile=`.
- Host tests green (monitor 577, syscall 472, driving_award 215, input 215;
  the shell `mock-fed` FileNotFound failure is pre-existing on clean main);
  fmt/coordination clean; BSS budget re-ran green.
- **#628 stays open** — this deletion PR links, not closes, it.