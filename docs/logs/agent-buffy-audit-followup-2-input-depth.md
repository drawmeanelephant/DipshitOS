# Log — agent/buffy/audit-followup-2-input-depth

## 2026-08-15 — claim 7302 (audit follow-up 2: XHCI depth 8 + per-device report buffers)

Opened from the 2026-08-15 strong audit of `main` `3013b17` (issues #115–
#123 filed). This claim is the input tranche per the maintainer's go-ahead:
per-device interrupt-IN report buffers sized to the device maxpkt (issue
#118), multi-TRB depth-8 arming with top-up accounting re-testing claim
6050's single-TRB conclusion on the fixed code (issue #117), the runner's
`--input-chords-delay` knob, and the new `verify-live-input-depth` class-B
gate registered in the `verify-vz` aggregate.

Claim-time measurement: VZ's keyboard delivers ~one report per full-frame
present (~1.5–2 s); the full 18-chord sequence lands byte-exact at 2.0 s
with dropped=0, and ≤1.0 s delivers nothing (host-side state coalescing,
not a guest bug). Depth-8 is the correct XHCI shape + burst buffering; the
fast-typing ceiling is VZ's delivery model, documented honestly in the
gate and the claim.
