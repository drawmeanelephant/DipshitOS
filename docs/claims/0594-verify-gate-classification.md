# Claim: Verification gate classification — portable/build CI vs Apple-VZ hardware gates

- **Owner:** buffy (`freebuff/pull-latest-dipshitos-main-ebe15999-a14a-4066-9551-00deb3d2323a`)
- **Prompt / plan:** inline — see Notes
- **Scope:** docs + command naming/wiring only. New `docs/gate-inventory.md`
  (canonical A/B/C/D classification with machine-readable records),
  `justfile` aggregates (`verify-portable`, `verify-vz`, `alias verify`),
  CI step labels + explicit "not proven by CI" step, `build.zig` step-help
  annotations, `docs/testing.md` classification section. NO kernel/host code
  changes, NO edit to `docs/status.md`.
- **Depends on:** —
- **Status:** ✅ done 2026-08-08 — classification + inventory + aggregates landed; full class-A set green, coordination gate green

## Notes

Goal: make it impossible for future agents to confuse "CI is green" with
"the Apple-VZ hardware gates passed". Every verification command is
classified into exactly one class:

- **A — portable / build CI:** deterministic, no Apple silicon, no VZ VM.
  This is the set GitHub CI proves. Green CI badge == these passed, nothing
  more.
- **B — Apple-silicon Virtualization.framework hardware gate:** boots a real
  VZ VM on Apple silicon. GitHub-hosted CI does not run these and cannot
  prove them.
- **C — interactive / manual hardware gate:** needs a human at the keyboard
  (`zig build console`).
- **D — diagnostic experiment:** answers a question (claims 0017/0018/0020/
  0021), NOT an acceptance gate.

Commands classified (minimum set + the rest):

| Command | Class |
|---------|-------|
| `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` | A |
| `bash tools/verify-unit-tests.sh` | A |
| `zig build test-console` / `bash tools/verify-transcript.sh` | A |
| `zig build` (guest build) | A |
| `zig build image` | A |
| `zig build inspect` | A |
| `swift build --package-path host/vm-runner` (build only) | A |
| `zig build context` | A |
| `bash tools/verify-coordination.sh` / `test-coordination.sh` / `verify-mmu-debt.sh` | A |
| `bash tools/verify-bad-handoff.sh` | B |
| `bash tools/verify-marker.sh` + `zig build marker` | B |
| `bash tools/verify-nvram-console.sh` + `zig build nvram-console` | B |
| `bash tools/verify-host-console.sh` | B |
| `zig build run` (live serial takeover gate, claim 0002) | B (blocked) |
| live M1.5 transcript/RX gate (assert in `vm-serial.log`) | B (deferred to claim 0002) |
| `zig build console` | C (interactive/manual) |
| `bash tools/verify-preexit-tx.sh` + `zig build preexit-tx` | D |
| `bash tools/verify-tx-diag.sh` + `zig build tx-diag` | D |
| `bash tools/verify-tx-transition.sh` | D |
| `bash tools/verify-fw-mmu-capture.sh` | D |

Deliverables:

1. `docs/gate-inventory.md` — canonical classification, human table + a
   fenced `GATE` record block (`GATE id=… class=A|B|C|D kind=… ci=… apple=…
   gate=… cmd=…`) that a future status preflight can grep/sed.
2. `justfile` — `verify` renamed to `verify-portable` with
   `alias verify := verify-portable` (backward compatible); new `verify-vz`
   aggregate (bad-handoff + marker + nvram-console + host-console; the
   blocked serial-takeover gate and the deferred live transcript gate are
   documented but intentionally not chained); class annotations on every
   recipe comment.
3. `.github/workflows/ci.yml` — header comment stating CI proves class A
   only; per-step class labels; a final step that prints the class-B gates
   from the inventory so the CI log itself says "these were NOT proven".
4. `build.zig` — step-help descriptions annotated with class (and
   blocked/diagnostic where applicable).
5. `docs/testing.md` — "Verification classes" section + pointer updates;
   no milestone-status duplication (that stays in `docs/status.md`, which is
   NOT edited).
