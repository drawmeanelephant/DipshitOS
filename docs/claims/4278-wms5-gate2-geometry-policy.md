# Claim: WMS5 Gate 2 — geometry policy moves into WND.BIN (tile/snap/ws/min-max over the seam)

- **Owner:** buffy (`agent/buffy/wms5-gate2-geometry-policy`)
- **Issue:** https://github.com/drawmeanelephant/DipshitOS/issues/625 (WMS5 of 10, milestone 16 — the Gate 2 remainder)
- **Depends on:** WMS5 Gate 1 (claim 9849, PR #641 — the input seam: kind 19 `WM_POINTER` + kind 20 `WM_WINDOW` fan-out, `wm_owns_input` gating the pointer geometry path, SET_WINDOW rects live). Cut from the Gate 1 branch (stacked); Gate 1's PR merges first.
- **Blocks:** WMS6 (desktop chrome), WMS8 (deleting kernel geometry code)
- **Heartbeat:** 2026-08-29
- **Status:** ✅ complete

## Scope — Gate 2 of the card: the WM decides geometry

Gate 1 handed the *pointer* stream to the WM and gated the kernel's pointer-geometry
path. Gate 2 completes the handover — the WM decides the *keyboard* geometry and owns
the full geometry state-machine surface, still proposing rects that the kernel clamps
+ blits:

1. **kind 21 `WM_KEY` (new, ADR 0009 D2 — the keyboard half of the input seam):**
   the raw keyboard stream fans out to the registered WM (routing-restricted like
   kinds 18/19/20, never generated in shim mode). `arg0` = the decoded key byte /
   usage, `flags` = ADR 0009 modifier bits. Fanned on key-DOWN edges, once per shell
   idle pass, like the pointer.
2. **Kernel keyboard geometry gates behind `!wm_owns_input`:** while a WM is
   registered, the shell idle's keyboard geometry consumers (Ctrl+T tile, Ctrl+M
   master-swap, Ctrl+N minimize, Ctrl+Shift+M maximize, F11 fullscreen, Ctrl+Shift+T
   always-on-top, Ctrl+F1-3 workspace switch, Alt+` workspace cycle, Alt+arrow
   keyboard move, Ctrl+Shift+B lower-back) are no-ops — the raw key already went to
   the WM via kind 21, and the WM issues SET_WINDOW/SET_STATE instead. Zero
   regression: no WM registered → byte-identical to pre-WMS5.
3. **`SET_STATE` (cmd 4, new — the visibility/workspace half of the geometry seam):**
   the ADR 0007 slot-65 subcommand table gains `WMCTL_SET_STATE = 4` with
   `a0 = window id`, `a1 = visible (0/1) | workspace << 8`. The WM minimizes/restores
   (visibility) and moves windows between workspaces (workspace) through the same
   clamped kernel primitives (`user_set_visible` + move-to-workspace) the shim uses.
   `EACCES`/`ENOSYS`/`EINVAL` per the seam discipline; ALL broadcast → `EINVAL`
   (per-window only, like geometry).
4. **WND.BIN grows real EL0 policy** (the file already imports wnd_core — the
   single-source drift guard with the kernel shim; Gate 2 finally *calls* it):
   - **tile / master-detail** (Ctrl+T / Ctrl+M): the WM tracks a small mirror
     registry from kind-20, runs the wnd_core tile rules, issues SET_WINDOW rects;
   - **snap zones** (drag near a screen edge while holding): the WM hit-tests the
     wnd_core snap-zone rule and issues the snapped rect;
   - **workspaces** (Ctrl+F1-3 switch, Alt+` cycle): SET_STATE visibility per window
     from the mirrors (each mirror carries `workspace` bits 10-11);
   - **minimize / restore** (Ctrl+N / re-click): SET_STATE visibility;
   - **maximize / restore** (Ctrl+Shift+M): SET_WINDOW rect (workspace area);
   - **fullscreen** (F11) + **always-on-top** (Ctrl+Shift+T): SET_WINDOW rect /
     SET_STATE flags where the encoding permits — the subset the W1-W16 matrix
     actually drives, kept byte-for-byte identical to the shim's numbers.
   The WMS3 pacing + WMS4 chrome + WMS5 drag behaviors and markers are unchanged
   (the existing live gates stay green).
5. **W1–W16 matrix re-run with WND.BIN registered:** the existing W-gates drive
   geometry via `dui` commands → kernel functions directly (the established
   EL1h-monitor precedent; the chords themselves are host-tested in input.zig). A new
   registered-variant live gate boots WND.BIN + the W-gate demo program and re-runs
   the matrix's `dui` assertions with the WM seated — plus a WM-driven interaction
   (injected chord → WND.BIN issues the rect → the pixel/serial proof shows the WM,
   not the kernel, decided).

## Design decisions

1. **The keyboard is the missing half of the input seam.** Gate 1 fanned the pointer;
   without kind 21 the WM could never trigger tile/min/max/ws policy. It is the same
   routing-restricted discipline as kind 18/19/20 (ADR 0009 D2), one more row.
2. **The kernel keeps its geometry functions** (WMS8 deletes them) — the shim path
   must stay byte-identical with no WM registered, and the W-gates' `dui`-driven
   assertions run against those functions. Gate 2 gates the *input paths* (pointer
   done in Gate 1, keyboard here), not the functions.
3. **Single source via wnd_core:** the tile/snap/workspace/clamp rules the WM issues
   are the SAME functions the kernel shim runs (`wnd_core`), compiled into both
   binaries. A rule change on either side fails the drift-guard tests. The EL0 blob
   keeps its pinned markers; the new policy markers are `pub const`s like the old.
4. **No new syscall:** SET_STATE is a new *subcommand* on the existing slot-65
   surface (the ADR 0007 table is amended, slot count unchanged).

## Touches

`kernel/src/events.zig` (kind 21), `kernel/src/input.zig` (keyboard fan-out hook +
gated consumers), `kernel/src/shell.zig` (idle keyboard path), `kernel/src/wm_server.zig`
(SET_STATE + fan counters), `kernel/src/syscall.zig` (cmd 4 handler),
`kernel/src/wnd_core.zig` (shared rules), `user/src/wnd.zig` (EL0 policy),
`kernel/src/monitor.zig` (`wm` observability), W1–W16 gate scripts (registered-variant
matrix + live gate), `docs/decisions/0007-syscall-abi.md`, `docs/decisions/0009-application-events.md`,
`docs/status.md`, `docs/march-m32-wm-migration.md`, claim + log.
