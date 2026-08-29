# Branch log — agent/buffy/wms5-gate2-geometry-policy

## 2026-08-29 — WMS5 Gate 2 claimed (issue #625 remainder)

- Claimed **WMS5 Gate 2 — geometry policy moves into WND.BIN (tile/snap/ws/min-max
  over the seam)** as `docs/claims/9850-wms5-gate2-geometry-policy.md` (status 🔄,
  heartbeat 2026-08-29). Branch `agent/buffy/wms5-gate2-geometry-policy` cut from
  `agent/buffy/wms5-geometry-seam` (Gate 1, PR #641 — stacked; Gate 1 merges first).
- Scope frozen in the claim: kind 21 `WM_KEY` (the keyboard half of the input seam),
  kernel keyboard geometry gated behind `!wm_owns_input`, new slot-65 subcommand
  `SET_STATE = 4` (visibility + workspace over the clamped kernel primitives), and
  WND.BIN growing real EL0 policy (tile/master-detail, snap, workspaces,
  minimize/maximize, fullscreen, always-on-top) from the shared wnd_core rules —
  with the W1–W16 matrix re-run against the registered WM.
- Survey confirmed: the W-gates drive geometry via `dui` monitor commands → kernel
  functions directly (the chords are host-tested in input.zig), so the registered-variant
  matrix + a WM-driven interaction is the honest live proof; the shell idle's keyboard
  consumers (`input.take_*`) are the path to gate; WND.BIN is a full Zig user program
  (naked `_start`) that already imports wnd_core as the drift guard.

## 2026-08-29 — WMS5 Gate 2 complete (claim 9850)

- Implemented the full Gate 2 surface and **passed the class-B live gate**
  (`tools/verify-live-wnd5-gate2-policy.sh`, PASS 2026-08-29 on VZ).
- **Kernel:** kind 21 `WM_KEY` (ADR 0009 D2 row) + `wm_server.fan_key` (key-DOWN
  edges); the shell idle's keyboard geometry consumers (tile/master/min-max/ws/
  fullscreen/aot/alt-arrow) gated behind `!wm_owns_input`; new slot-65 cmd 4
  `SET_STATE` (visibility | workspace<<8 | always-on-top; ALL broadcast = global
  workspace switch) via the clamped primitives; SET_WINDOW rects now apply with
  **layout semantics** (`wm_apply_rect` — scanout clamp, not back-buffer clamp —
  so WM tiling matches the shim's 837 px master width).
- **shared rules:** `wnd_core` gained named `Rect`/`GeomBounds` + the pure
  tile-layout / maximize / fullscreen / snap-zone / title-bar parity functions the
  WM issues; `driving_award` re-exports the constants. Host parity + drift-guard
  tests green (wnd_core 10, driving_award 215, syscall 463, input, wm_server).
- **WND.BIN → real Zig policy program.** Mutable policy state forced the segmented
  DSK3 loader path (`linker-segmented.ld` + `elf2bin.py --segments`), which also
  needed a make-image.sh DSK3 case and the static-exec path registering the
  writable data region in the per-task TCB (without it `sys_wait_event`'s copy_out
  EFAULTs forever — observed live as a `state=ready` spinning WM with unconsumed
  ticks). The loop drains the WHOLE backlog per wake (no per-event yield) so the
  WM isn't starved by the 1 Hz-VZ ring + EL1h worker.
- **Live gate:** the starved-ring lesson restructured it to the WMS4-settled 20 s
  dwells; boot A re-runs the W1–W16 `dui` matrix with the WM registered (zero
  regression); boot B injects a headless Ctrl+T chord → the WM emitted `wnd: tile`,
  the kernel consumed nothing (gated, `kernel_tile=0`), `key_fan=1`, and NOTEPAD
  moved to `rect=24,0,837,700` — the WM decided.
- Docs: ADR 0007 (cmd 4 SET_STATE row + Gate-2 amendment), ADR 0009 (kind 21 row +
  kinds-18–21 routing note), `docs/status.md`, `docs/march-m32-wm-migration.md`
  WMS5 row (claims 9849+9850).
