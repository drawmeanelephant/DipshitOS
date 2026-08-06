# Coordination logs (append-only, per branch)

**Why this exists:** the project changelog used to live entirely inside
`docs/status.md`. Every agent appended to that one file, so parallel work
collided on every merge — PR #8/#10 collided once, and PR #12/#13 collided
again on the same section. Coordination state is now **sharded by branch**:
each branch owns its own log file, and cross-branch merges never touch the
same lines.

**The rule is unchanged and still binding** (AGENTS.md): log files are
**append-only**. Never rewrite or delete an entry — including entries in
other branches' logs. Corrections are *new* entries that reference the old
one.

## How to log

1. Your branch's log file is `docs/logs/<branch-slug>.md` (e.g.
   `agent/buffy/m15-commands` → `docs/logs/agent-buffy-m15-commands.md`).
   Create it on your first entry.
2. **Append** an entry in this format:

   `- **YYYY-MM-DD** — *owner (branch)*: claim → what changed → evidence → status.`

   Status legend: ⬜ claimed · 🔄 in progress · ✅ done · ⛔ blocked.
3. Cite `artifacts/` evidence files. No observed claim without a saved log.
4. Do **not** edit `docs/status.md` for logging — only for milestone-level
   facts (gates, march steps, position). If you must touch
   `README.md`/`roadmap.md`/`testing.md`, prefer pointer-level changes.

## Log index

| Branch | Log file |
|--------|----------|
| M1.5 tracker origin (pre-branch era) | [`m1.5-tracker.md`](m1.5-tracker.md) |
| `agent/buffy/m2-kernel-proper` (PR #10) | [`agent-buffy-m2-kernel-proper.md`](agent-buffy-m2-kernel-proper.md) |
| `agent/buffy/m2-badhandoff-fix` (PR #11) | [`agent-buffy-m2-badhandoff-fix.md`](agent-buffy-m2-badhandoff-fix.md) |
| `agent/buffy/m15-commands` (PR #12) | [`agent-buffy-m15-commands.md`](agent-buffy-m15-commands.md) |
| `agent/buffy/m15-host-plumbing` (PR #13) | [`agent-buffy-m15-host-plumbing.md`](agent-buffy-m15-host-plumbing.md) |
