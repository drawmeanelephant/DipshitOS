# Claim: M8 U4 pointer class-B gate completion (verify-live-pointer-cg.sh)

- **Owner:** buffy (`agent/buffy/m13-u4-pointer-classb`)
- **Prompt / plan:** issue #151 — finish the class-B CG pointer gate
- **Depends on:** U4 (claim 4993, ⛔), the CG gate (claim 3692), the class-C
  gate (claim 9015), U5 (claim 0935)
- **Status:** 🔄 in progress

## Notes

Issue #151 asks for the class-B CG gate to be completed so U4 has automated
live evidence. Claim 3692 built the gate but its trusted path had never run
(the one-time Accessibility grant was pending). This card exercises it and
finishes the gate.

Gate fixes landed in `tools/verify-live-pointer-cg.sh`:

- **SKIP semantics** (issue #151 acceptance 1): no Accessibility trust now
  exits **0** with a SKIP message instead of failing (exit 1). CI-safe.
- **bash 3.2 crash**: `"${EXTRA[@]}"` on the empty `--request-trust` array
  is unbound under `set -u` (macOS default bash) — guarded with the `+`
  expansion so the trusted path no longer dies before the VM run.
- **`set -euo pipefail` crash**: `DISTINCT_FOCUS=$(grep … | sort | wc | tr)`
  aborts the whole script when the pointer route yields zero focus lines
  (`grep` exits 1 → `pipefail` propagates). Added `|| true` (also in
  `verify-pointer-manual.sh`).
- **Marker consistency**: the gate referenced `pointer-cg-done` (via the
  boot `--expect` and the screenshot/DONE greps) but nothing produced it.
  Removed the bogus `--expect`; the script's `pointer-cg-ready` is now the
  single run marker for the screenshot and the DONE assertion.

## Live result (the honest finding)

With Accessibility trust granted (`CGPreflightPostEventAccess=true`,
`AXIsProcessTrusted=true`), the gate ran end to end:

```
pointer-cg: rc=0 ready=1 focus-lines=0 distinct=0 ptr-reports=0 done=1 cursor=0 untrusted=0
```

The runner posted the full CG sequence (`PTR-SEQ: 6 steps ok=true`,
`PTR-EVT entered/move/click ×N` — trust=post:true ax:true), but the guest
reported **zero** `dui: pointer focus=` lines and **zero** pointer reports.
This confirms claim 4993's hardware contract: synthesized pointer events —
even the CG HID-tap route under Accessibility trust — do not reach VZ's USB
pointing device. U4's automated live proof therefore stays class-C (a real
mouse, claim 9015). The gate is now correct and self-gating, and will pass
unchanged if a future runner route ever delivers to the guest.
