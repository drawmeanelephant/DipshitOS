# Claim: Milestone-three docs reconciliation for the landed syscall ABI

- **Owner:** Buffy (`agent/buffy/m3-docs-reconcile-syscall-abi`)
- **Prompt / plan:** user request to fix stale milestone-three docs
- **Scope:** Docs-only reconciliation of `docs/march-m3.md`, `docs/roadmap.md`,
  and `docs/m3-syscall-abi-prompt.md` against the landed EL0/SVC and syscall
  ABI work (claims 8215/3594, PRs #60/#63/#64). No kernel, host, tool,
  status, gate-inventory, or live-gate file changed.
- **Depends on:** claims 8215 (EL0/SVC boundary) and 3594 (syscall ABI),
  PRs #63 and #64, and the coordination gate.
- **Status:** ✅ done 2026-08-10

## Notes

Deterministic claim ID from
`bash tools/status/claim-id.sh 'agent/buffy/m3-docs-reconcile-syscall-abi' 'm3-docs-reconcile-syscall-abi'`
= 5725.

Verification of the landed syscall ABI work against the march tracker and
coordination claims found three stale doc surfaces, all fixed:

- `docs/march-m3.md`: step 2 (syscall ABI + dispatch table) marked ✅ done
  with claim/ADR/card evidence links and the live-svc gate result; lane B's
  serialization rule noted as satisfied (claims 8215/3594).
- `docs/roadmap.md`: milestone-three header and intro updated to the full
  canonical order and "uaccess is the next milestone-three card"; the two
  missing EL0/SVC (claim 8215) and syscall ABI (claim 3594) DONE bullets
  added in the existing strikethrough style.
- `docs/m3-syscall-abi-prompt.md`: dependency line corrected from
  "PR #60 — draft" to "PR #60 — merged as `65ad6af`".

`bash tools/verify-coordination.sh` and
`bash tools/status/refresh-indexes.sh --check` pass; `git diff --check` clean.
