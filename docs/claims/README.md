# Active claims (one file per claim)

**Why this exists:** claims used to live in a single table inside
`docs/status.md`. Every agent edited that table to claim work, so parallel
agents collided on the same file (PR #8/#10, then PR #12/#13). Claims are
now **one file per claim**: claiming work means creating a new file, never
editing a shared table.

**The rule is unchanged and still binding** (AGENTS.md): claim **before**
you start. Non-trivial work gets a claim file (and a log entry in
`docs/logs/<branch>.md`) *before* code is written. Unclaimed work is fair
game; claimed work is not.

## How to claim

1. Copy [`TEMPLATE.md`](TEMPLATE.md) to `docs/claims/<NNN>-<slug>.md`
   (next number, kebab-case slug).
2. Fill in Owner (agent id + branch), Prompt / plan, Scope, Depends on.
3. Set Status to `🔄 <branch>` **before** starting work.
4. Add a row to the [Active claims index](#active-claims-index) here in
   `docs/claims/README.md` (this is the canonical index; `docs/status.md`
   only links the claim files).
5. On completion or blockers: flip Status in **your claim file** to `✅`
   (with evidence) or `⛔` (note why), and append to
   `docs/logs/<branch>.md`.

Never edit another agent's claim file. Corrections are new entries in your
own branch's log that reference the old one.

## Active claims index

**This table is the canonical index** (status included). `docs/status.md`
only links the claim files — keep status in sync here.

| Claim | Owner (branch) | Status |
|-------|----------------|--------|
| [0001-bad-handoff-gate](0001-bad-handoff-gate.md) | buffy (`agent/buffy/m2-badhandoff-fix`) | ✅ fixed 2026-08-06 |
| [0002-vz-serial-gate](0002-vz-serial-gate.md) | — | ⬜ |
| [0003-m15-host-plumbing](0003-m15-host-plumbing.md) | buffy (`agent/buffy/m15-host-plumbing`) | ✅ 2026-08-06 |
| [0004-m15-console-shell-core](0004-m15-console-shell-core.md) | — | ⬜ |
| [0005-m15-commands-personality](0005-m15-commands-personality.md) | buffy (`agent/buffy/m15-commands`) | ✅ 2026-08-06 |
| [0006-status-machinery](0006-status-machinery.md) | buffy (`agent/buffy/m2-kernel-proper`) | ✅ |
