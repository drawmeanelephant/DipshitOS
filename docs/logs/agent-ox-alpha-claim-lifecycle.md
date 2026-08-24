# Log — claim lifecycle: declared files + staleness

- **2026-08-24** — *ox-alpha*: Opened. Implements #523 items 4–5. Claims
  gain optional `Touches:` (paths/globs) and `Heartbeat:` fields;
  verify-coordination.sh fails on overlapping Touches between ACTIVE
  claims of different branches and warns on stale 🔄 claims (last commit
  > STALE_DAYS, default 14). Optional fields keep the grandfathered files
  valid. Also flips merged claims 2564/4928 to ✅. Claim 6014.

- **2026-08-24** — *ox-alpha*: DONE. PR #527 merged as 8420a89. Follow-up:
  the claim file itself stayed 🔄 after merge (missed in that PR), which
  the new Touches-conflict gate then flagged against claim 6637 declaring
  AGENTS.md — first real catch by the machinery this claim added. Flipped
  to ✅ here.
