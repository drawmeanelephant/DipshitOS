# Claim: milestone eight, card U4 follow-on — the CG pointer route as a self-gating class-B gate

- **Owner:** buffy (`agent/buffy/u4-pointer-cg`)
- **Prompt / plan:** user request 2026-08-15 — "re-try the CGEventPost
  pointer route with Accessibility trust granted to the terminal, and if
  reports arrive, upgrade the pointer proof from class C to an automatable
  class-B gate". This resolves claim 4993's open follow-up (b).
- **Scope:** the runner's pointer-seam trust handling (`--pointer-request-trust`,
  `PTR-TRUST: untrusted` honest reporting, the config `trust=post/ax` line)
  and `tools/verify-live-pointer-cg.sh` (a NEW class-B gate that self-gates
  on the trust). NO guest/kernel change — the claim-4993 guest side is
  driven as-is.
- **Depends on:** U4 (claim 4993, ⛔), the class-C real-mouse gate (claim
  9015, ✅), U5 chrome (claim 0935, ✅).
- **Status:** ✅ done (2026-08-15) — trust detection + honest reporting +
  the self-gating gate landed and are smoke-proven on the untrusted path;
  the trusted path awaits the one-time human grant (TCC — a gate cannot
  grant it).

## Notes

The claim-4993 route-4 observation was "silently dropped without
Accessibility trust" — the runner posted to the HID tap and said nothing.
The probe answers WHY, mechanized: the terminal holds no Accessibility
trust (`AXIsProcessTrusted=false`, `CGPreflightPostEventAccess=false`,
observed 2026-08-15). The runner now:

1. reports trust in the config line (`trust=post:<bool> ax:<bool>`) and
   prints `PTR-TRUST: untrusted … skipped-post` instead of silently
   dropping the HID-tap post;
2. gains `--pointer-request-trust`, which prompts the system via
   `AXIsProcessTrustedWithOptions` (the one-time grant path).

The gate self-gates on that trust: WITHOUT it, the gate FAILS with the
exact System Settings grant steps (a TCC grant is a human action, not
something a gate can automate); WITH it, the `--pointer` seam over route
`cg` drives synthesized clicks that the gate asserts as ≥2 distinct
`win: pointer focus=` lines + `ptr-reports>0` + the magenta cursor pixel
(calibrated in claim 9015) — the class-B upgrade the request asked for.
The class-C gate (claim 9015) remains the honest no-trust path.

## Verified

- ✅ runner builds + config report shows `trust=post:false ax:false`.
- ✅ untrusted-cg negative path: `--pointer-route cg` now prints
  `PTR-TRUST: untrusted … skipped-post` for every step and the guest stays
  `ptr-reports=0` — no silent drop.
- ✅ the gate's trust preflight (a CGPreflightPostEventAccess probe) and
  the untrusted FAIL path with the grant steps, exercised locally.
- ⬜ the trusted PASS run needs the one-time Accessibility grant (System
  Settings → Privacy & Security → Accessibility → the terminal), then
  `bash tools/verify-live-pointer-cg.sh` — that is the machine-local
  precondition, the same shape as Screen Recording for the screenshot
  gates.
- ✅ `bash tools/verify-coordination.sh`
