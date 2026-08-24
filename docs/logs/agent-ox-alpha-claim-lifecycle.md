# Log — claim lifecycle: declared files + staleness

- **2026-08-24** — *ox-alpha*: Opened. Implements #523 items 4–5. Claims
  gain optional `Touches:` (paths/globs) and `Heartbeat:` fields;
  verify-coordination.sh fails on overlapping Touches between ACTIVE
  claims of different branches and warns on stale 🔄 claims (last commit
  > STALE_DAYS, default 14). Optional fields keep the grandfathered files
  valid. Also flips merged claims 2564/4928 to ✅. Claim 6014.
