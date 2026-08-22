# Claim: M24 K6–K16 — CALC grows up (Lane B continuation)

- **Owner:** ox-alpha (`lane-b/m24-calc-features`)
- **Prompt / plan:** `docs/agent-concurrency-plan.md` Lane B + `docs/march-m24.md`
- **Scope:** M24 cards K6–K16 (GitHub #370–#380), all in `user/src/calc.zig` +
  `user/src/calc/*` modules only. Zero new syscall slots, negligible BSS.
  One commit+PR per issue: K6 sci notation (#370), K7 trig (#371), K8 log/exp
  (#372), K9 expression editor (#373), K10 clipboard (#374), K11 CLI mode
  (#375), K12 formatting controls (#376), K13 date/time arithmetic (#377),
  K14 random numbers (#378), K15 saved expressions (#379), K16 statistics
  mode (#380).
- **Depends on:** K1–K5 landed on `main` (#482, #484). Nothing else — Lane B
  is fully independent per the concurrency plan.
- **Status:** 🔄 in progress

## Notes

Continuation of claim 5301 (K1–K5) on the same lane/branch. Each issue is
implemented, unit-tested (`zig test user/src/calc.zig`), committed with a
`closes #N` message, and PR'd before starting the next. Gate scripts for
live verification are named per march-m24 notes; live VM gates run when the
card's code lands (live-gate bring-up may follow the K1–K5 pattern of a
separate pass).
