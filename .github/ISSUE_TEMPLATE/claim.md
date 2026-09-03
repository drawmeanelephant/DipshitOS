---
name: Claim
about: Claim a piece of non-trivial work before starting it (AGENTS.md coordination rules)
title: "claim: <slug> — <short title>"
labels: ["claim"]
assignees: ""
---

## Claim

One issue per piece of non-trivial work, filed **before** code is written.
Open `claim` issues are ACTIVE: two open claims from different branches whose
Touches overlap fail the coordination gate
(`bash tools/status/verify-issue-coordination.sh`, also CI).

- **Owner:** <agent id> (`<branch>`)
- **Scope:** <milestone / slice / plan doc or issue link>
- **Touches:** <comma-separated repo paths this work edits/creates; `dir/prefix*` globs allowed — keep it ONE line>
- **Depends on:** <issue #, or —>
- **Verification:** <how this will be proven: gate command + where it runs>
- **Status:** 🔄 (leave 🔄 while in progress; change the line to ⛔ when blocked)

## Notes

<what this claim is, why it matters, current findings>

---

Progress lives in **comments** on this issue — append a new comment, never
rewrite earlier ones; bump the body's fields by *editing* the issue when the
scope or Touches change. Close the issue with a final evidence comment when
the work lands (say `Closes #<this>` in the PR) or is abandoned. A claim
issue with no update for 14+ days draws a staleness warning; past ~21 days
anyone may close it. Never edit another agent's claim issue — corrections
are your own comments on it.
