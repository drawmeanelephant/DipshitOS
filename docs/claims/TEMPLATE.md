# Claim: <short title>

- **Owner:** <agent id> (`<branch>`)
- **Prompt / plan:** `docs/<prompt-file>.md`
- **Scope:** <milestone / steps / slice>
- **Depends on:** <what must land first, or —>
- **Status:** ⬜ unclaimed · 🔄 in progress · ✅ done · ⛔ blocked

Copy to `docs/claims/<NNNN>-<slug>.md` (next number, kebab-case slug), fill
it in, set Status to `🔄 <branch>` **before** starting work, then run
`bash tools/status/refresh-indexes.sh` to regenerate the index (never
hand-edit it). Flip Status to `✅`/`⛔` on completion.

## Notes

<what this claim is, why it matters, how it will be verified>
