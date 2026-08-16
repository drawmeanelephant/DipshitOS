# Log — `m13-u4-pointer-classb`: finish the U4 class-B CG gate (claim 5776)

## 2026-08-16 — branch opened

- Issue #151: finish `tools/verify-live-pointer-cg.sh` for U4's class-B
  pointer evidence. Branch from `origin/main` (`b53bfe7`).

## 2026-08-16 — branch work

- Gate fixes: no-trust → SKIP (exit 0) per issue acceptance; guarded the
  empty `--request-trust` array (bash 3.2 `set -u` crash); `|| true` on the
  `DISTINCT_FOCUS` pipeline (pipefail crash when there are zero focus
  lines); removed the bogus `--expect pointer-cg-done` and made
  `pointer-cg-ready` the single run marker.
- Trusted live run (trust granted): `pointer-cg: rc=0 ready=1 focus-lines=0
  distinct=0 ptr-reports=0 done=1 cursor=0 untrusted=0` — the CG route posts
  the clicks but the guest reports zero pointer events. Confirms claim 4993:
  synthesized pointer events don't reach VZ's USB device even with trust.
- U4 stays ⛔ at the live seam; class-C (real mouse, claim 9015) remains the
  honest automated-adjacent proof.
