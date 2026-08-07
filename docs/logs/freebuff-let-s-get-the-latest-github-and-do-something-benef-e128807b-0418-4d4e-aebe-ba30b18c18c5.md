# Log — Status re-verification on merged main (claim 0014)

- **2026-08-07** — *buffy
  (`freebuff/let-s-get-the-latest-github-and-do-something-benef-e128807b-0418-4d4e-aebe-ba30b18c18c5`)*:
  fast-forward merged `main` (4702548 — claims 0009–0012 landed: marker
  fallback, MMU-takeover fix, real `ResetSystem` machine controls, milestone
  docs) → re-ran the full gate suite on the merged tree → claimed
  `docs/claims/0014-status-reverify.md` (✅) → refreshed `docs/status.md`
  gate table with 2026-08-07 evidence. All gates green: host suite
  (`artifacts/status-reverify-20260807.txt`), marker gate ladder
  `M2_ENTRY → M2_CMAP! → M2_PREX! → M2_EXIT! → M2_MAPD! → M2_MMUP! →
  M2_SERIA` (`artifacts/m2-marker-reverify-20260807.txt`), bad-handoff
  `kernel_rc=0x0000000000000002`
  (`artifacts/m2-badhandoff-reverify-20260807.txt`), host-console scripted +
  PTY (`artifacts/m15-host-console-reverify-20260807.txt`). VZ serial gate
  remains blocked on device absence (re-confirmed, not regressed).
