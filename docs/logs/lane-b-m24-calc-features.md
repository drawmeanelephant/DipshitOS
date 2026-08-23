# Log — lane-b/m24-calc-features

Lane B — CALC (M24). Owns `user/src/calc.zig` + `user/src/calc/*.zig`.
Zero kernel/toolkit edits. Append-only per coordination rules.

## Entries

### 2026-08-22 — Claim opened: M24 K6–K16 continuation (claim 5381)

Branch fast-forwarded to `origin/main` @ `4d11713` (K5 history command
already landed via #484). K6–K16 remain open as GitHub #370–#380. Working
one issue per commit+PR. Baseline verified: `zig test user/src/calc.zig`
61/61 PASS, working tree clean.

### 2026-08-22 — M24 K6–K16 complete (one PR per issue)

All eleven remaining Lane B cards implemented, unit-tested, and PR'd:
K6 sci notation #486 (merged), K7 trig #487 (merged), K8 log/exp
#489, K9 expression editor #491, K10 clipboard #492, K11 CLI mode
#493 (stacked), K12 formatting #494, K13 dates #495, K14 random #496,
K15 defs #497, K16 stats #498. Stack order: 491→493→494→495→496→497→498
(each later branch contains its predecessors; squash-merging in order
avoids rebase churn). Final host suite: 116/116 calc tests; monitor
modules green; verify-bss-budget PASS throughout. Documented honest
deviations: K14 uses a timer-seeded PRNG (zero-slot ABI budget, no EL0
entropy seam); K13 now() reads CNTFRQ/CNTPCT_EL0 directly; fractional
rendering (K12/K15) applies to float-valued paths since the engine is
checked-integer. Live VM gate bring-up for the whole M24 set remains a
follow-up pass, consistent with K1–K5's "live gate pending" notes.
