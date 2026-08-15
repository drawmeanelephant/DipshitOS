# Claim: audit follow-up 1 — gate machinery + docs drift (issues 115/116/120/121/122/123)

- **Owner:** buffy (`agent/buffy/audit-followup-1-gates-docs`)
- **Prompt / plan:** the 2026-08-15 strong audit of `main` `3013b17` — issues
  #115–#123 filed; this claim is the mechanical first tranche (audit rule 12:
  "Do not fix the findings during this audit" is lifted by the maintainer's
  explicit go-ahead to implement in the recommended order).
- **Scope:** (1) `justfile` — add `bash tools/verify-live-exceptions.sh` to the
  `verify-vz` aggregate (issue #115) and delete the duplicated
  `verify-live-win-move.sh` line in the `verify-live-win-move:` recipe (issue
  #116); (2) public site — `site/roadmap.md` no longer says "There is no
  milestone eight defined yet"; name the U4–U8 ladder (issue #120); (3)
  `AGENTS.md` current-milestone + the obsolete "G4–G6 are NOT committed work"
  sentence, `docs/status.md` current-position table gains a milestone-eight
  row, `docs/roadmap.md` M6/M7 section headers stop saying "sketched, not
  committed"/"Scope sketch" (issue #121); (4) `kernel/src/shell.zig` stale
  "no GIC programming this milestone" comment corrected to the claim-9187
  reality (issue #122); (5) a tracked known-flake record for the N11 NAT
  ARP-learn flake whose baseline evidence was lost to `.gitignore` (issue
  #123).
- **Depends on:** — (docs/gate only; no kernel behavior change).
- **Status:** 🔄 agent/buffy/audit-followup-1-gates-docs

## Notes

Every item is the "stale/missing mechanical fix" class: no new behavior, no
claim upgrades. Historical sweep counts in `docs/status.md` (e.g. "38-gate
verify-vz aggregate") stay historical — the append-only changelog convention
means we do not rewrite past entries; the aggregate fix is the code, and the
site/AGENTS/roadmap "current" prose is what gets refreshed. The flake record
goes into `docs/gate-inventory.md` (a tracked file agents already consult)
rather than a new doc — issue #123's acceptance is "a tracked file listing
known flakes, the gate, the evidence path, and the closing PR".

**Verification:** class A (fmt, unit tests, byte-identical transcript) +
`bash tools/verify-coordination.sh` after `refresh-indexes.sh`; the
`verify-vz` recipe change is verified by grep (the aggregate gate itself is
class B and re-runs live per batch 2/3 where relevant); the site edit is
verified by `boris validate` if the pinned toolchain is available locally,
else by the docs-gate CI on the PR.
