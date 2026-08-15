# Log — U4 CG-pointer route follow-on (claim 3692)

**Branch:** `agent/buffy/u4-pointer-cg`

- **2026-08-15** — *buffy*: pursued claim 4993's follow-up (b): the
  CGEventPost pointer route under Accessibility trust. Observed the
  terminal holds no trust (`AXIsProcessTrusted=false`,
  `CGPreflightPostEventAccess=false`), which is why route 4 silently
  dropped. Added `--pointer-request-trust` + honest `PTR-TRUST: untrusted`
  reporting + the config `trust=post/ax` line to the runner, and
  `tools/verify-live-pointer-cg.sh` — a class-B gate that self-gates on
  trust: FAIL with the grant steps when absent, full CG-seam assertion
  (≥2 distinct focus lines + ptr-reports>0 + cursor pixel) when present.
- Smoke-proven the untrusted path: the runner now reports untrusted per
  post instead of silently dropping; the gate FAILs with the grant steps.
  The trusted PASS needs the one-time TCC grant (human action).
- Registered in gate inventory (class=B, ci=no, apple=yes); updated the
  hardware contract, claim 4993, and the gate inventory.
