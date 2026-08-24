# Claim: M19 P3 command chaining (`;`, `&&`, `||`) + P4 exit status propagation

- **Owner:** ox-alpha (`agent/ox-alpha/m19-p3p4-chaining-exit-status`)
- **Prompt / plan:** GitHub milestone 7 ("M19 — Shell as programming environment"),
  issues #292 and #293; tracker `docs/march-m19.md`
- **Scope:** milestone nineteen, Lane-A shell — two cards landed as one slice
  because `&&`/`||` are meaningless without a real exit status.
- **Depends on:** P1 pipes (#290, PR #504), P2 redirection (#291, PR #505),
  P11 conditionals (#300, PR #516 — `last_exit_ok` bool already exists).
- **Status:** ✅ done (2026-08-23)

## Notes

### P3 — command chaining (issue #292)

* Split the RAW line on top-level `;`, `&&`, `||` outside double quotes,
  BEFORE any expansion, and expand each segment at its own execution time.
  The first bring-up expanded the whole line up front; the VZ gate caught
  it (`exec NOTEXIST.BIN ; echo exit=$?` printed `exit=0` because `$?`
  was baked in pre-execution) and the split moved above the expansion
  pipeline (`expand_and_dispatch` per segment) — POSIX ordering.
* Precedence per the issue: `;` lowest; `&&`/`||` equal, left to right,
  short-circuit on the last actual status (a skipped segment leaves the
  status untouched, so `a && b || c` behaves like POSIX).
* Bounded: max 4 commands per chain; more is refused honestly, nothing runs.
* Structured forms are bypassed un-split: lines starting `fn `/`for `/`while `
  /`if ` keep their internal `;` semantics (function bodies, loop headers,
  if/then/else). Empty segments are skipped at run time (status preserved).
* `exit` inside a chain stops script execution as before (remaining segments
  do not run).
* A side benefit of raw-line splitting: `echo a > f ; ls` now redirects to
  the file `f` and then lists — previously redirect_split saw the filename
  as `f ; ls`.

### P4 — exit status propagation (issue #293)

* `last_exit: u8` module global next to `last_exit_ok`; helpers keep the two
  in sync (`set_exit_ok`, `set_exit_code`). Dispatch-level mapping:
  `.none`=0, `.unknown_command`=127, `.usage`=2, others=1.
* Optimistic-success default at `shell_handle_expanded` entry so simple
  successful builtins propagate 0 without touching all ~30 return sites;
  failure paths overwrite explicitly.
* `$?` substitutes the decimal status in `env_expand` (read-only, never in
  the env table; delayed correctly inside fn/for/while bodies because those
  skip pre-expansion).
* Prompt integration: colored prompt goes green on 0, red otherwise
  (T5/T15 seam).
* Honest boundary: external programs are fire-and-forget spawns today (the
  shell does not block on them), so `$?` reflects spawn/dispatch results —
  exactly what the issue's class-B example asserts (`exec NOTEXIST.BIN;
  echo $?` nonzero). Process-exit capture would need a wait seam and is out
  of scope here.

### Verification

* Class A: 706/706 shell-module host tests (13 new: chain_split parsing
  incl. quote immunity, lone-`|` non-operator and the 4-command bound;
  sequencing, short-circuit, issue precedence example; `$?` round-trips,
  127/2/1 mappings, and the execution-time-expansion regression pin);
  full portable gate green (`artifacts/claim-5759-class-a.txt`).
* Class B: `tools/verify-live-chain.sh` PASS 1/1 on VZ — `echo chain-a &&
  echo chain-b`, `false && echo chain-skip ; echo chain-seq` (skip never
  printed as an exact line), `exec NOTEXIST.BIN ; echo exit=$?` →
  `exit=1`, `true ; echo ok=$?` → `ok=0`
  (`artifacts/live-chain-gate.txt`, `-serial-01.log`).
