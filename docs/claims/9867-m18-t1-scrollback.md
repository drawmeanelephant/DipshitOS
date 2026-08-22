# Claim: M18 T1 — terminal scrollback ring

- **Owner:** buffy (`agent/buffy/m18-t1-scrollback`)
- **Prompt / plan:** `docs/march-m18.md`
- **Scope:** M18 card T1 — bounded scrollback ring in `kernel/src/scrollback.zig`, Console wrapper in `shell.zig` to capture all output, CSI interceptor for PageUp/PageDown scroll keys, host tests + class-B live gate
- **Depends on:** —
- **Status:** ✅ done 2026-08-22

## Notes

Implements issue #404 T1: a bounded ring buffer (200 lines × 128 bytes) that captures all terminal output by wrapping the monitor's Console. PageUp (CSI 5 ~) and PageDown (CSI 6 ~) scroll the view by 10 lines. The CSI interceptor shadow-tracks without eating bytes — all keys reach the line editor except the final `~` of a scroll sequence.

### Self-referential pointer lesson

`Shell.init()` returns `Shell` by value, which means any self-referential pointers (e.g. `scrollback_ctx.sb = &shell.scrollback`) become dangling after the return copy. The console wrapping must happen in `boot()`, which takes `*Shell` and therefore holds valid pointers into the caller's `Shell`.

### Files changed

- **New:** `kernel/src/scrollback.zig` — Scrollback ring with `append`, `copy_lines`, `reset`, `stored`, `flush_partial`, 4 host tests
- **Modified:** `kernel/src/shell.zig` — ScrollbackCtx + vtable wrapper, CSI shadow-tracker, `boot()` now wraps console, 4 new host tests
- **Modified:** `tools/verify-unit-tests.sh` — added `scrollback` to module list
- **New:** `tools/verify-live-scrollback.sh` — class-B VZ gate: fill scrollback → PageUp×3 → PageDown×3 → verify shell survives

### Verification

- `zig test kernel/src/scrollback.zig` — 4/4 tests pass
- `zig test kernel/src/shell.zig` — 513/513 tests pass (4 new scrollback tests)
- `bash tools/verify-unit-tests.sh` — all modules pass
- `zig build test-console` — transcript byte-identical
- `zig build kernel` — kernel builds