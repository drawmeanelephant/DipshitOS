# Claim: <short title>

- **Owner:** <agent id> (`<branch>`)
- **Prompt / plan:** `docs/<prompt-file>.md`
- **Scope:** <milestone / steps / slice>
- **Touches:** <comma-separated repo paths this work edits/creates; `dir/prefix*` globs allowed>
- **Depends on:** <what must land first, or —>
- **Heartbeat:** <YYYY-MM-DD — update while Status is 🔄 so staleness checks see life>
- **Status:** ⬜ unclaimed · 🔄 in progress · ✅ done · ⛔ blocked

Copy to `docs/claims/<NNNN>-<slug>.md`, fill it in, set Status to
`🔄 <branch>` **before** starting work, then run
`bash tools/status/refresh-indexes.sh` to regenerate the index (never
hand-edit it). Flip Status to `✅`/`⛔` on completion.

While a claim is 🔄:
- **Touches** is machine-checked: two ACTIVE claims from different branches
  declaring overlapping files fail `verify-coordination.sh`. Keep tokens
  space/comma-free paths.
- **Heartbeat**: commit a heartbeat bump at least every couple of weeks. A
  🔄 claim whose file has no commit for STALE_DAYS (default 14) gets a
  gate warning; past ~21 days anyone may flip it ⛔ via their own branch
  log entry referencing the claim.

The claim number is **not** "next NNNN" — derive it deterministically with
`bash tools/status/claim-id.sh "<branch>" "<slug>"` (kebab-case slug). The
ID is a pure function of branch+slug, so concurrent claimers cannot pick
the same number; claims `0024+` are gate-enforced by
`tools/verify-coordination.sh` (legacy `0001–0023` are grandfathered).

## Notes

<what this claim is, why it matters, how it will be verified>
