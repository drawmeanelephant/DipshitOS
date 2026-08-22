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

### Live-gate evidence (2026-08-22, claim 0469 session; updated claim 5093)

`bash tools/verify-live-scrollback.sh` — **class-B PASS 1/1** on real VZ:
`artifacts/live-scrollback-gate.txt`, `live-scrollback-report.txt`,
`live-scrollback-serial-01.log` (banner=1 fill-ready=1 typed=1 report=1
runner-flag=1). Phase 2 now types the scroll keys through the
**synthesized keyboard** (`--input-chords`): `pageup ×3, pagedown ×3,
escape` then `echo scroll keys ok` and `input` — the shell's own input
report proves all 33 chord events reached the guest keymap with
dropped=0, and the typed echo proves the shell stayed live (claim 5093
added the `pageup`/`pagedown`/`escape` macChord tokens + guest keymap
usages 0x4b/0x4e/0x29).

**Three real shell bugs found & fixed while bringing up the keyboard
walk** (the earlier serial gate masked them — its `\n` submissions and
substring greps never hit them):

1. **Dangling editor CSI state:** the tracker consumed the `~` of a
   scroll sequence, leaving the editor mid-`ESC [ <param>` — the next
   ESC was swallowed and `[5`/`[6` fragments inserted into the line
   (`unknown command '[5[6[6cho …'` observed live). Fixed: `poll` calls
   the new `LineEditor.csi_reset()` whenever the tracker consumes a byte.
2. **Scrolling back to live kept `selecting` active** — a real Enter
   (0x0D) then copied+discarded the line instead of submitting it (only
   serial `\n` slipped past). Fixed: `scroll_handle(6)` clears selection
   when the offset reaches 0.
3. **Lone ESC in selection mode ate the next keystroke** (the cancel
   fired on the byte after ESC and consumed it). Fixed: the byte passes
   through — the editor's "a lone ESC does not eat the next keystroke"
   philosophy. The T2 selection gate (serial walk, no ESC) re-passed
   unchanged.

### Verification

- `zig test kernel/src/scrollback.zig` — 4/4 tests pass
- `zig test kernel/src/shell.zig` — 513/513 tests pass (4 new scrollback tests)
- `bash tools/verify-unit-tests.sh` — all modules pass
- `zig build test-console` — transcript byte-identical
- `zig build kernel` — kernel builds