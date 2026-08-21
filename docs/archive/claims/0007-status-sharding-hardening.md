# Claim: Status/changelog machinery hardening (generated indexes + verify gate)

- **Owner:** buffy (`agent/buffy/m15-commands`)
- **Prompt / plan:** this claim — make the coordination surface merge-safe (finish 0006)
- **Scope:** generated claim/log index tables, coordination verify gate, `docs/status.md` shrinkage (claims table → pointer, changelog stragglers → branch logs), M1.5 march moved to `docs/march-m15.md`, docs/CI updates
- **Depends on:** sharded claims/logs system (claim 0006)
- **Status:** ✅ 2026-08-06 — indexes generated; gate in just/CI; status.md pointers-only incl. gate work

## Notes

The sharding (0006) moved claims and logs into per-claim / per-branch
files, but four shared edit surfaces remain and still collide on merge:
the claim index table in `docs/claims/README.md`, the log index table in
`docs/logs/README.md`, the claims table inside `docs/status.md`, and two
changelog entries still inline in `docs/status.md`. Plan:

1. Generate the claim/log index tables from the actual files
   (`tools/status/refresh-indexes.sh`) so claiming/logging means *create a
   file, run the script* — never hand-editing a shared table.
2. Add a coordination gate (`tools/verify-coordination.sh`, `just
   verify-coordination`, CI) that fails if indexes drift from files or a
   claim/log file is malformed.
3. Shrink `docs/status.md` to pointers: drop its claims table, migrate the
   last changelog entries verbatim into `docs/logs/agent-buffy-m15-commands.md`,
   and move the twenty-step march + agent split to `docs/march-m15.md`
   (one file per milestone) so step updates never collide with status.md.
4. Enforce the invariants in `tools/verify-coordination.sh`: no changelog
   entries, claims rows, march, or agent-split tables may appear in
   `docs/status.md` (content-based tripwires, not just headings).
5. "Immediate gate work" statuses in `docs/status.md` reduced to pointers
   to the claim files — a gate passing never needs an edit in status.md.

Gate: `bash tools/verify-coordination.sh` exits 0 with the indexes
regenerated; status.md contains no hand-edited claims/changelog/march
tables. Log: `docs/logs/agent-buffy-m15-commands.md`.
