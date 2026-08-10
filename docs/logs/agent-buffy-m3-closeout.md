# Log — milestone-three close-out (lane E, `agent/buffy/m3-closeout`)

- **2026-08-10** — *buffy (`agent/buffy/m3-closeout`)*: claimed march-m3 step 8
  (claim 0707) — full class A + class B gate re-run at the candidate HEAD,
  docs reconciliation (status/roadmap/march-m3 + archiving the completed
  milestone-three and M1.5 prompt/design docs), and the milestone-three tag
  after every gate passes. 🔄 in progress.

- **2026-08-10** — *buffy (`agent/buffy/m3-closeout`)*: **claim 0707 done —
  milestone three CLOSED.** Full gate set re-run at the candidate HEAD
  `0c119d8` (merged main after PRs #60/#64/#66/#67): **class A 11/11**
  (fmt, unit tests, test-console, build, image, inspect, swift runner
  build, context, coordination, coordination tooling, mmu-debt) and
  **class B 17/17** on real VZ (serial takeover, bad-handoff, marker,
  nvram-console, host-console, live-transcript, live-fs, live-timer,
  live-tasks, live-userspace, live-svc, live-uaccess, live-addrspaces,
  live-lifecycle, live-exec, live-sleep, live-reboot). Evidence:
  `artifacts/gates-reverify-20260810-m3-closeout.txt` +
  `artifacts/classB-chunk{1,2,3,4}-m3-closeout.log`.

- **Doc consolidation (2026-08-10):** the completed one-shot prompt/design
  docs that sat `> ARCHIVED`-labeled in `docs/` root were moved into
  `docs/archive/` — `m3-syscall-abi-prompt`, `m3-ragshit-dogfood-prompt`,
  `m3-march-tracker-prompt`, `m3-runner-scripted-input-prompt` (its
  `--script` fixture mode landed inside claim 6684; now labeled),
  `m15-commands-design`, `m15-shell-core-design`,
  `m15-postmmu-t0sz-experiment-design`, `m2-kernel-proper-design`, and the
  M1.5 tracker `march-m15.md` — so `docs/` root holds only active docs.
  References updated in README/roadmap/status/march-m3, and the
  coordination gate + context builder + its test fixture now point at the
  active `docs/march-m3.md` (coordination gate green, tooling tests 15/15).
  Status/roadmap/march-m3/testing reconciled: milestone-three row closed,
  gate-table reverify chain extended to the close-out run, march-m3 row 8
  → ✅, roadmap Milestone-three header + reserved-slot fix (5–63),
  testing.md close-out reverify entry. Tagged **`m3-userspace`** at the
  verified commit `0c119d8`. ✅ done.
