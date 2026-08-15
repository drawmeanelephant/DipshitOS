# Claim: audit follow-up 2 — XHCI interrupt-IN depth 8 + per-device report buffers (issues 117/118)

- **Owner:** buffy (`agent/buffy/audit-followup-2-input-depth`)
- **Prompt / plan:** the 2026-08-15 strong audit of `main` `3013b17` — issues
  #115–#123 filed; this claim is the input tranche per the maintainer's
  go-ahead to implement in the recommended order (audit rule 12 lifted).
- **Scope:** (1) `kernel/src/xhci.zig` — per-device interrupt-IN report
  buffers sized to `max_report_bytes` (10) with the armed TRB length taken
  from the DEVICE's maxpkt, never clamped to 8 (issue #118: the pointer's
  10-byte reports were silently truncated by fixed `[8]u8` buffers + a
  `@min(maxpkt, 8)` clamp); (2) multi-TRB interrupt-IN depth (`intr_depth`
  8) with top-up re-arming + `intr_armed` accounting — re-testing claim
  6050's "single-TRB is the correct shape" conclusion, which rested on a
  multi-TRB experiment that wrapped the transfer ring at the 8th report on
  the PRE-U2 (pre-`intr_slot_index`) arm code (issue #117); (3)
  `host/vm-runner` — the `--input-chords-delay` knob (default 3.0 s, so
  every existing gate stays byte-identical); (4) the new class-B live gate
  `tools/verify-live-input-depth.sh` registered in the `verify-vz`
  aggregate.
- **Depends on:** — (the U2 `intr_slot_index` wrap fix, claim 1809, is the
  precondition this re-test builds on; already on `main`).
- **Status:** 🔄 agent/buffy/audit-followup-2-input-depth

## Notes

The live re-test measured the honest VZ keyboard delivery model: the host's
keyboard is state-based and flushes the guest roughly one report per
full-frame Road Pops present (~1.5–2 s). At 2.0 s per keystroke the FULL
18-chord sequence (`echo fastok <Enter> input <Enter>`) lands byte-exact
with `dropped=0 events=18` on depth-8 arming (this claim's gate). At
≤1.0 s per keystroke VZ itself delivers NOTHING — a keyDown/keyUp pair
arriving inside the delivery window nets to zero state, so the flush
carries no report. That is a host delivery-model limit, not a guest arming
bug; no guest arming depth can raise the VZ steady-state rate. Depth-8's
value is the correct XHCI shape (several interrupt-IN TRBs, each owning its
own report buffer) plus buffering the bursts VZ delivers when its main
queue stalls behind display updates — the failure mode the chord injector's
own comment documents at depth 1. Claim 6050's "single-TRB is correct"
conclusion is therefore superseded on both grounds (it rested on the
pre-fix bug, and single-TRB depth is the wrong shape even after).

## Evidence

- `kernel/src/xhci.zig` unit tests: `intr_trb_len` never clamps a 10-byte
  pointer report to 8; report buffers are 10 bytes; the depth-8 top-up keeps
  the armed count constant across 1000 ring wraps with no slot double-armed.
- Live gate `tools/verify-live-input-depth.sh` (class B, VZ): typed
  `echo fastok <Enter> input <Enter>` at 2.0 s/chord — `fastok` echoed
  exactly once, `input` reported `armed=1 fifo=0/64 dropped=0 events=18
  kb-usage=0x28 kb-byte=0xa`, serial marker + runner flags all set. PASS.
- Measured ceiling (claim-time, same kernel): 1.0 s and 0.3 s per chord
  deliver zero reports; 2.0 s and 3.0 s deliver byte-exact.
