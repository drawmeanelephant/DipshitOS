# Log — `freebuff/ragshit-review`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-08** — *buffy (freebuff/ragshit-review)*: claim 0020 — Ragshit `review` budgeted reviewer packet (task 2026-08-08); claim filed; reuse `tools/ragshit/impact` as input; scope `tools/ragshit/` only; plan in `artifacts/review-plan.md`. 🔄 in progress
- **2026-08-08** — *buffy (freebuff/ragshit-review)*: review implemented — `review/{candidates,coverage,redundancy,selection,report}.py` + CLI `--budget-chars/--json/--explain` + baseline + docs; tests 23 new, full suite 124 passed, doctor ok. 🔄
- **2026-08-08** — *buffy (freebuff/ragshit-review)*: dogfood done — HEAD~1/~5/~10 at 10k/25k/50k under `artifacts/review-packets/`; 10k contains most valuable impl, 25k improves coverage, 50k adds secondary evidence without duplicates; timing ~110ms HEAD~1, ~230ms HEAD~5, ~290ms HEAD~10 (index reuse); determinism verified. ✅ done
