# Claim: Re-verify every gate on merged `main` and refresh status evidence (2026-08-07)

- **Owner:** buffy (`freebuff/let-s-get-the-latest-github-and-do-something-benef-e128807b-0418-4d4e-aebe-ba30b18c18c5`)
- **Prompt / plan:** fast-forward `main` (4702548) into the working branch, then re-run the full gate suite so `docs/status.md`'s gate table carries fresh 2026-08-07 evidence instead of the 2026-08-06 re-run dates
- **Scope:** verification only (host suite + VZ-backed marker / bad-handoff / host-console gates) + `docs/status.md` gate-table refresh; no kernel or runner code changes
- **Depends on:** claims 0009/0010/0011/0012 (merged 2026-08-07)
- **Status:** ✅ done 2026-08-07 — all gates re-run green on merged `main`; evidence saved under `artifacts/` and cited in `docs/status.md`

## Notes

Every gate row in `docs/status.md` previously cited 2026-08-06 re-runs.
This claim re-ran the whole surface on the post-merge tree and confirmed:

- The MMU takeover still completes on VZ — the NVRAM ladder reaches
  `M2_SERIA` (the serial probe runs to completion and finds no usable
  device), re-confirming claim 0010's state, not regressing it.
- The bad-handoff failure path still returns `kernel_rc=0x0000000000000002`.
- The M1.5 host-console plumbing (scripted run + PTY character-mode/SIGINT
  terminal restore) still passes.
- The entire host-only suite (fmt, unit tests, transcript byte-diff, build,
  image, inspect, swift build, context snapshot, coordination) is green.

The VZ serial gate stays blocked on device absence — re-confirmed, not
regressed. Evidence: `artifacts/status-reverify-20260807.txt`,
`artifacts/m2-marker-reverify-20260807.txt`,
`artifacts/m2-badhandoff-reverify-20260807.txt`,
`artifacts/m15-host-console-reverify-20260807.txt`.
