# Claim: M19 P5 quoting & escaping + P6 globbing

- **Owner:** ox-alpha (`agent/ox-alpha/m19-p5p6-quoting-globbing`)
- **Prompt / plan:** GitHub milestone 7 ("M19 — Shell as programming environment"),
  issues #294 and #295; tracker `docs/march-m19.md`
- **Scope:** milestone nineteen, Lane-A shell — two pure-parsing cards as one
  slice; both are argument-shaping stages feeding the same dispatch.
- **Depends on:** P3 chaining (#292) and P4 exit status (#293, PR #521) —
  the chain/pipe/redirect scanners must learn single-quote + backslash
  states so quoting composes with operators.
- **Status:** ✅ done (2026-08-23)

## Notes

### P5 — quoting & escaping (issue #294)

* `kernel/src/tokenizer.zig` becomes a real state machine: unquoted /
  in_single / in_double, with a caller-provided scratch buffer
  (`tokenize(line, scratch)`) because joined tokens (`ab"c d"e` → one arg)
  and escape stripping are not contiguous slices of the line. Scratch is
  bounded by the 256-byte line bound; shell.zig keeps it in BSS (the
  script_staging precedent), tests pass locals.
* Single quotes: everything literal to the closing `'`; `'\''` works via
  outside-quote escaping. Double quotes: spaces join, `$VAR` still expands
  (expansion runs before tokenization, unchanged), backslash escapes per
  the issue (`\"`, `\\`, `\$`, `\n`, `\t`; other `\c` keeps both bytes).
  Outside quotes: `\x` → literal x (so `\;`, `\|`, `\&` defuse operators).
* Supersedes two pinned M1.5 rules, with tests updated: quotes now join
  mid-token (previously a mid-token quote was literal), and single quotes
  exist. Unbalanced ANY quote → rest-of-line literal + warning (extended
  from double-only).
* `env_expand` goes single-quote-aware ($ never expands inside `'...'`)
  and passes `\X` pairs through verbatim so `\$VAR` survives to the
  tokenizer (which strips the backslash).
* The raw-line scanners — `chain_split`, `pipe_split`, `redirect_split` —
  learn single-quote + backslash states so `'a;b'`, `a\;b`, `'a|b'`,
  `a\|b` no longer split.

### P6 — globbing (issue #295)

* After tokenization, any argv slot whose text contained UNQUOTED/UNESCAPED
  `*`, `?`, or `[` (tokenizer reports this per-arg) expands against the ESP
  window listing (`esp.entries()`); bounded scope: the ESP root listing,
  like bare `ls`. No recursion, no `**`.
* Matcher: iterative fnmatch-style `*`, `?`, `[abc]`, `[a-z]` classes; no
  negation classes (documented). Matches are byte-sorted (insertion sort).
* Bounded: max 64 matches TOTAL per line; beyond that an honest refusal and
  nothing executes. No match → the literal pattern passes through
  (nullglob-off semantics).

### Verification

* Class A: tokenizer unit tests (rewritten + new), glob matcher unit tests,
  shell-level e2e via mock console (no-disk host env ⇒ empty listing ⇒
  literal passthrough path is exercised), full portable gate green.
* Class B: new `tools/verify-live-quote.sh` and `tools/verify-live-glob.sh`
  on the established VMRunner serial harness.
