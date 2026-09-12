# tools/ locale-sensitivity audit (issue #1186)

Companion to the captured sweeps in `locale-audit.txt` and the guard evidence in
`parity-guard.txt`. Both files are raw command output, not retyped.

## The question

Issue #1177 fixed the one place where a locale-dependent operation reached a
**tracked** file: `tools/inventory-gates.sh` truncated spec headers with
`cut -c1-100`, which counts bytes under `LC_ALL=C` and characters under a UTF-8
locale, so `docs/gate-fleet-inventory.md` rendered differently depending on the
author's shell. This audit asks the follow-up question: does the same class
exist anywhere else under `tools/`?

The class has two halves, and both matter:

1. **A locale-dependent byte** — the output is committed, compared, or used as
   an artifact name, so two environments disagree.
2. **Reachability** — the operation has to actually see non-ASCII text for the
   disagreement to be possible.

## What was swept

`cut -c`/`cut -b`; the locale-sensitive POSIX classes (`[[:space:]]`,
`[[:alpha:]]`, `[[:upper:]]`, `[[:lower:]]`, `[[:digit:]]`, `[[:punct:]]`,
`[[:alnum:]]`); bracket ranges (`[a-z]` in `grep`/`sed`); `printf '%.Ns'`
precision truncation (byte-oriented in libc); bash substring expansion
(`${v:0:N}`, locale character counting); unpinned `sort`/`uniq` collation;
`tr` case tables; `grep -i` case folding; and Python text I/O without an
explicit encoding. Results (`locale-audit.txt`, sections B–G):

| construct | live sites under `tools/` | reachable? | action |
|---|---|---|---|
| `cut -c` / `cut -b` | **0** (one mention, in the fixed generator's own comment) | — | none |
| `[[:space:]]` etc. | 2 in `inventory-gates.sh` (pinned render, invariant asserted) + 3 in the new `lint-workflows.sh` parity guard | guard input is ASCII YAML/justfile, and its result is never committed | none |
| bracket ranges `[a-z]` in grep/sed | **0** | — | none |
| `printf '%.Ns'` | **0** | — | none |
| bash `${v:0:N}` | **0** | — | none |
| `tr '[:lower:]' '[:upper:]'` | 2 in `verify-zc-corpus.sh` (case name → artifact name) | yes: a locale such as `tr_TR.UTF-8` maps ASCII `i` differently, which would change a generated ELF/`outname` and break the dual-run leg's expectations | **pinned** `LC_ALL=C` here |
| unpinned `sort -u` | 3: `verify-zc-corpus.sh` (case-list dedupe — **pinned** here), `verify-pointer-manual.sh:127` (count of distinct focus ids), `probe-pointer-routes.sh:38` (a diagnostic string) | collation can reorder a *set*; the two remaining sites feed a count and a human-readable diagnostic in class C/D gates | pinned in the corpus gate; the two class C/D sites left as-is (see below) |
| Python text I/O without `encoding=` | `tools/ragshit/` internals + one test helper | dev tooling, writes no tracked file, decodes UTF-8 explicitly where it matters | none |

Two structural facts settle the question:

- **`inventory-gates.sh` is the only tool that writes a tracked file.** Every
  other `REPORT=` in `tools/` resolves through `art()` into gitignored
  `artifacts/` (`locale-audit.txt`, section H). So half 1 of the class — a
  locale-dependent committed byte — has exactly one instance in the tree, and
  it is fixed and asserted.
- **The reachable non-ASCII is concentrated in one place.** 51 of the 210
  `tools/gate/specs/*.spec` files contain non-ASCII, but only **2** carry it in
  the first-line header the generator scrapes: `live-m21-persist-title-orphan`
  (em dash) and `live-wnd5-gate2-policy` (en dash). Only the first crosses its
  truncation boundary — which is exactly why one row, and not two, differed
  between locales.

## Left as-is, deliberately

`verify-pointer-manual.sh:127` and `probe-pointer-routes.sh:38` keep their
unpinned `sort -u`. Both sort a set extracted from serial logs and then discard
the order: one is piped to `wc -l` (a count, collation-independent), the other
is joined into a diagnostic line in a class-D probe. Neither can change a
committed byte, a compared filename, or a pass/fail verdict. They are class
C (interactive, needs a TTY) and class D (diagnostic, needs a route probe), so
pinning them here would ship an edit this claim cannot verify on hardware —
noted rather than silently changed. If they ever start feeding a comparison,
they should be pinned with the rest.
