# Claim: repo hygiene — trim gate-inventory.md (issue #265)

- **Owner:** ox-alpha (`t3code/issue-265-fix`)
- **Prompt / plan:** GitHub issue #265
- **Scope:** docs-only + one CI line: compress `docs/gate-inventory.md` to a
  lean per-gate table (name / command / status / last-verified); move the
  verbatim pre-trim content (evidence paragraphs, claim numbers,
  machine-readable `GATE_INVENTORY` block) to
  `docs/archive/gate-inventory-detail.md`; point CI's class-B listing step at
  the archived block. No kernel, user, tools, or gate-script changes.
- **Depends on:** —
- **Status:** ✅ done (2026-08-21)

## Notes

Issue #265 asked for ~80–100 lines; the inventory holds 92 gates, so per-gate
fidelity (one exact-command row each — the option agreed on the issue thread)
floors the file near 167 lines. The chosen trade: every gate keeps its own
exact row; prose evidence graduated to the archive instead.

## Verified

- `sed -n '/^<!-- GATE_INVENTORY:START -->$/,...'` extraction re-run against
  `docs/archive/gate-inventory-detail.md` locally — the CI pipeline's grep +
  sed still list every class-B gate with its command.
- `bash tools/status/refresh-indexes.sh` re-run; `bash
  tools/verify-coordination.sh` green after claim/log registration.
