# Claim: Milestone-three march tracker

- **Owner:** Codex (`agent/codex/m3-march-tracker`)
- **Prompt / plan:** `docs/m3-march-tracker-prompt.md`
- **Scope:** Milestone three per-step tracker and collision-free agent-split plan in `docs/march-m3.md`
- **Depends on:** —
- **Status:** ✅ done 2026-08-09

## Notes

Create the pure-docs milestone-three march tracker by mirroring
`docs/march-m15.md`, using only real claim references and honest statuses.
Verification is limited to the portable format and coordination gates; this
claim does not change or observe guest behavior.

Completed `docs/march-m3.md` with all eight canonical userspace cards, claim
8215's landed EL0/SVC evidence, active claim 3594 for the syscall ABI, honest
not-yet-claimed statuses for the six later cards, and a serialized agent split
that encodes both file ownership and shared-host VZ-run contention. No kernel,
host, tool, status, roadmap, gate inventory, or live-gate file changed.
`zig fmt --check` passed and the final
`bash tools/verify-coordination.sh` rerun passed; evidence is saved in
`artifacts/m3-march-tracker-zig-fmt.txt` and
`artifacts/m3-march-tracker-coordination-rerun.txt`.
