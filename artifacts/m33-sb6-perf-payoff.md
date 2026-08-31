# M33 SB6 — seam-B perf payoff: measured before/after vs the WMS9 baselines

- **Card:** M33 SB6 (issue #693), claim 6864 — phase 4 (payoff/perf)
- **Gate:** `tools/verify-live-sb6-perf-payoff.sh` — PASS (2026-08-31, one
  headless VZ boot on macOS 27; runner-rc=0, zero faults)
- **Serial evidence:** `artifacts/live-sb6-perf-payoff-serial.log`
- **Baseline reference:** `artifacts/wms9-fill-reduction.md` (WMS9, issue #629)

## What was measured (one boot, same frame, two paths)

Both halves render the IDENTICAL frame: an 8x8 grid of 16x16 rects in a
256x192 user window (static frame + 8 dynamic redraws = 9 frames).

| Leg | Path | Kernel-visible work |
|-----|------|---------------------|
| **Before** (SB6OLD.BIN, pre-seam-B control) | frozen per-rect fills | 576 `sys_win_fill` (slot 13) SVCs + 9 `sys_win_present` (slot 14) SVCs; the kernel blitted the window on every drain/tick visit (20 user-blits) |
| **After** (SB6NEW.BIN + SB6WM.BIN, seam B) | plain stores into a bound shared surface + registered-WM compose-N | **0** fill SVCs; the kernel *skipped* the migrated window (22 skips); the WM compose-N'd the surface into its scanout view (196,608 bytes, one copy) and issued the final present (REQUEST_PRESENT cmd 3, flush-only) |

## Measured numbers (same boot, `syscalls` + `dui` snapshot at heartbeat ticks=45)

### Fill SVCs — the WMS9 headline metric
- `13 sys_win_fill calls=576` — exactly the control's fills. The seam-B app
  added **ZERO** (plain stores never reach the kernel fill path).
- Context from the WMS9 baseline: per-pixel fills were already batched to
  spans (slot 46); seam B removes the *kernel fill syscall entirely* for
  migrated apps — 576 slot-13 entries → 0, with byte-identical pixels.

### Composite cost (new SB6 counters, `dui` blits=/skips=)
- `dui: windows=4 focused=0 presents=24 blits=20 skips=22`
- `blits=20`: paint_scene visits where the kernel actually blitted the
  unmigrated control window (the pre-seam-B composite cost — includes the
  open + 9 presents + the fade-in re-dirty frames).
- `skips=22`: paint_scene visits where the kernel consumed the migrated
  window's damage WITHOUT a blit (the WM's compose-N stores are the
  pixels). Both counters are monotonic per boot; the gate requires
  blits>=9 and skips>=9 (one per present) and observed 20/22.

### Copy volume (SB6WM's byte counter)
- `sb6: wm bytes=196608` — the compose-N copy moved 256*192*4 = 196,608
  bytes from the migrated surface into the scanout (the WM's plain byte
  copies, no kernel fill involved).
- `sb6: wm readback=0x6B` — the composited scanout pixel at the window
  origin is the app's plain-store magic byte: the WM's compose-N bytes are
  the on-screen pixels (parity with the old fill path, by construction).
- `sb6: wm present` — the FINAL present (flush only; the kernel never
  re-paints over the WM's stores).

### Syscall deltas (before → after, for the same 9 frames)
| slot | before (SB6OLD) | after (SB6NEW+SB6WM) |
|------|-----------------|----------------------|
| 13 `sys_win_fill` | 576 | **0** |
| 14 `sys_win_present` | 9 | 9 (same present cadence) |
| 63 `sys_mmap` | — | 3 (scanout grant + owner bind + WM peer attach) |
| 65 `sys_wmctl` | — | 2 (REGISTER + REQUEST_PRESENT) |
| kernel user-blits | 20 | 0 (skips=22) |

## Interpretation vs the WMS9 baselines

- WMS9 already cut per-pixel fills to span batches (~39x fewer SVCs for a
  dense text line). Seam B eliminates the fill syscall **entirely** for
  migrated apps: 576 SVCs → 0, and the composite work the kernel used to do
  (blit) is replaced by the WM's compose-N (one 196,608-byte copy), leaving
  the kernel with a pure skip + flush-only present.
- The measurement is **measured, not asserted**: every number above is a
  serial-visible counter from the same boot (the gate's grep targets are
  pinned host-side in the three apps' unit tests).

## Honest finding (pre-existing, out of this card's scope)

The first bring-up used cooperative yield-spins (`sys_yield`) to pace
frames. A user task in a SUSTAINED yield-spin was observed to stall after
the first timer preemption (~1 s, ~9-17 yields): the task stops being
scheduled while the kernel's shell/worker keep advancing (heartbeats
continue, no fault line, no exit). This reproduces with a single app and
no WM (SB6OLD alone), so it is independent of the seam-B machinery.
Existing gates that yield-loop forever (WINLOOP, WINMOVE, SB4DAM) pass
only because their evidence is captured before the stall and a stalled
process keeps its windows. The SB6 apps pace with `sys_sleep(1)` instead
(blocking, the proven app pacing — winmove/notepad/status43 use it) and
the gate is green. The yield-spin stall deserves its own scheduler
investigation card (candidate: the EL0 timer preemption vs the
cooperative-yield resume path in `scheduler.tick()`/`switch_context`).
