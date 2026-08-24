# Claim: M19 P7 foreground/background jobs (`&`)

- **Owner:** ox-alpha (`agent/ox-alpha/m19-p7-background-jobs`)
- **Prompt / plan:** GitHub milestone 7 ("M19 — Shell as programming environment"),
  issue #296; tracker `docs/march-m19.md`
- **Scope:** milestone nineteen, Lane-A shell capstone — background job table,
  `jobs`, and `fg` over the existing fire-and-forget spawn model.
- **Depends on:** P3/P4 (PR #521) for operator scanning + status plumbing;
  P5 (PR #522) for the quote/escape-aware scanners that decide what `&` means.
- **Status:** ✅ done (2026-08-23)

## Notes

* Honest scope: only PROGRAM LAUNCHES spawn processes here (the registry
  `exec` path). Builtins are synchronous EL1 calls — there is nothing to
  put in the background. So `&` backgrounds the launch and tracks the PID;
  a `&` on a non-spawning command completes synchronously and records no
  job (documented, not silent: nothing observable happens because nothing
  asynchronous happened).
* Parsing: exactly ONE unquoted/unescaped `&` followed only by whitespace
  ends the line → background request, stripped before dispatch. Any other
  `&` shape is left untouched (the tokenizer refuses it as today).
* Table: 4 slots max, module BSS (`BgJob{pid, name, done_reported}`); full
  table → honest refusal, child still launches untracked.
* Reaping: the Shell.poll idle path checks each tracked pid against the
  process registry and prints `[N] Done: NAME (exit=CODE)` exactly once —
  the child's REAL registry exit status (the P4 `$?` seam stays
  dispatch-level; this is the process-level view).
* `jobs` lists live slots (`[N] Running:`/`[N] Done:` read live);
  `fg [N]` (default: most recent occupied slot) reports immediately when
  already exited, else bounded-waits ~5 timer ticks (1 s cadence, WFE
  between checks, no console reads so typed-ahead input survives) and
  honestly reports `fg: job N still running` on timeout, leaving it
  backgrounded. A job freed before `fg` names it reports `already done`
  (reap-vs-fg race is order-nondeterministic on hardware).
* Verification: host tests for parse/track/reap/empty paths (diskless host
  cannot spawn, so the nonexistent-pid reap path pins the loop logic);
  class-B `tools/verify-live-jobs.sh` — `exec COUNTER.BIN &` (eternal
  child) survives across later commands, `exec STATUS43.BIN &` produces
  exactly one `[2] Done: … (exit=43)` line, `fg 2` / `fg 1` cover the
  done and still-running branches.
