# Claim: M23/M24 gate-evidence sweep (EDIT.BIN + CALC.BIN)

- **Owner:** buffy (`agent/buffy/m23-m24-gate-sweep`)
- **Prompt / plan:** user-directed; same verification pattern as claim 5220's
  Lane-D wave-2 (write + run the missing class-B gates for code-done cards)
- **Scope:** milestone twenty-three cards E1–E6 and milestone twenty-four cards
  K1–K16 whose march rows say "✅ code" without observed gate evidence. Write
  the named `tools/verify-live-editor-*.sh` / `tools/verify-live-calc-*.sh`
  class-B VZ gates, run them on real Apple silicon, fix any hardware-only bugs
  they surface (with regression tests), flip march rows only on observed PASS.
  11 gates referenced by the trackers; only verify-live-calc-prog.sh exists
  on disk (never run).
- **Touches:** tools/verify-live-calc-prog.sh, tools/verify-live-calc-memory.sh,
  tools/verify-live-calc-units.sh, tools/verify-live-calc-constants.sh,
  tools/verify-live-calc-history.sh, tools/verify-live-calc-cli.sh,
  tools/verify-live-calc-stats.sh, tools/verify-live-editor-basic.sh,
  tools/verify-live-editor-console.sh, tools/verify-live-editor-goto.sh,
  tools/verify-live-editor-tabs.sh, tools/verify-live-editor-syntax.sh,
  user/src/edit.zig, user/src/calc.zig, docs/march-m23.md, docs/march-m24.md
- **Depends on:** —
- **Heartbeat:** 2026-08-25
- **Status:** ⛔ blocked by #562 + #563

## Notes

Both apps already print serial markers for most card behaviors (`calc:
prog-on/mem-slot/conv-on/date-ok/rand`, `edit: ready/undo/redo/goto-ok/
tab-open/tab-close`); where a card has no observable marker the gate will
drive it via scripted keystrokes and assert what is observable — adding a
minimal marker to the app is in scope if nothing is observable at all.
Evidence rules apply: rows flip on real VZ PASS only, artifacts under
artifacts/live-*.
