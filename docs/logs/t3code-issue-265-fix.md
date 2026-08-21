# Log — `t3code/issue-265-fix`

Append-only per-branch changelog (AGENTS.md). One entry per change.

- **2026-08-21** — *ox-alpha (t3code/issue-265-fix)*: claim 5828 — repo
  hygiene issue #265 → **done**: `docs/gate-inventory.md` compressed from
  262 lines / ~112 KiB of prose to a 167-line lean reference (82-gate table:
  ID / class / exact command / status / last-verified date; non-gate class-C
  + class-D registers; notes; known-flakes registry kept append-only in
  place). Per-gate evidence paragraphs, phase assertions, claim numbers, and
  the machine-readable `GATE_INVENTORY` block moved VERBATIM to new
  `docs/archive/gate-inventory-detail.md` with an archival banner. CI's
  "gates NOT proven" step (`ci.yml`) now extracts the block from the archive
  path (extraction re-run locally, output identical). Honest-status notes:
  `live-pointer-cg` is ⚠️ open (not pass) per its own record; `date*` rows
  use the introducing milestone's close date where no individual PASS date is
  recorded (derivation stated in the doc). Issue #265's 80–100-line target
  was unreachable with one-row-per-gate fidelity (92 gates) — trade agreed
  on the issue thread. Pointer updates: `site/development.md`. Class-A gates
  unaffected by content; coordination gates green after refresh-indexes. ✅
