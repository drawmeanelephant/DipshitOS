# Claim: milestone eight, card U4 follow-on — the real-mouse pointer path as a class-C gate

- **Owner:** buffy (`agent/buffy/u4-pointer-classc`)
- **Prompt / plan:** user request 2026-08-15 — "observe a real-mouse click
  moving focus under the existing pointer_tick path on real VZ and wire it
  as a class-C gate". This resolves claim 4993's open follow-up (a): the
  five synthesized pointer delivery routes each produced `ptr-reports=0`,
  so only a REAL mouse over the `--display` window can prove the guest
  stack live — and only a human can move one.
- **Scope:** `tools/verify-pointer-manual.sh` (a NEW class-C gate), its
  gate-inventory registration (human + machine-readable rows, class=C),
  and the follow-up bookkeeping in the hardware contract, claim 4993, the
  march-m8 U4 row, and `docs/status.md`. NO kernel or runner change: the
  guest side (`pointer_tick`, the cursor, the click edge) and the runner
  seam were already landed by claim 4993, and the gate drives them as-is.
- **Depends on:** U4 (claim 4993, ⛔ blocked at the live seam), U5's chrome
  (claim 0935, ✅), I2/I3 input (✅).
- **Status:** ✅ done (2026-08-15) — the gate is written, registered, and
  its boot/setup plumbing smoke-proven; the human-at-the-mouse observation
  is the gate's runtime (class C by construction).

## Notes

Class C is the correct class, not B: a gate that needs a human at the mouse
is not automatable and cannot run in CI. The gate makes the ONE remaining
unknown mechanically observable: whether a real mouse over the
VZVirtualMachineView produces pointer reports for the
`VZUSBScreenCoordinatePointingDevice` (and therefore whether a real click
moves focus through `pointer_tick`). The smoke run proved the honest
negative — boot reaches `pointer-manual-ready`, WINLOOP opens, and with no
real mouse there are zero `win: pointer focus=` lines and `ptr-reports=0` —
so the gate cannot false-PASS.

The gate's assertions (the guest's own serial evidence):
1. the setup `pointer-manual-ready` marker;
2. ≥2 DISTINCT `win: pointer focus=<id>` lines — a real click moved focus
   between windows (D4's headline);
3. `ptr-reports=<N>` with N>0 — a real pointer report reached the guest
   (the exact evidence every synthesized route failed to produce);
4. the magenta cursor pixel in the marker-driven capture (calibrated live:
   0xff00ff renders as ~(234,51,247) through the host's color-managed
   pipeline; no other on-screen element matches the R+B-high/G-low family);
5. the `pointer-gate-done` completion marker + runner exit 0.

## Verified

- ✅ class A unchanged: `zig fmt --check`, `zig build`, `zig build image`,
  `swift build` all green (the gate script itself passes `bash -n`).
- ✅ calibration: a marker-driven `screen fill ff00ff` capture measured the
  magenta transform at ~(234,51,247), so the cursor-pixel assertion reads
  the color FAMILY, not the raw triple (the claim-6053 color-managed
  precedent).
- ✅ smoke (class C plumbing): a 60 s `--input --display` run reached
  `pointer-manual-ready` + `winloop: present ok` + the `win` registry
  (windows=2) and produced the honest negative — no focus lines, no
  pointer reports — proving the gate FAILs without a human, never false-PASS.
- ⬜ the PASS run itself requires a human at the mouse (class C by
  definition); the gate prints the step-by-step instructions and asserts
  the evidence after the run.
- ✅ `bash tools/verify-coordination.sh`
