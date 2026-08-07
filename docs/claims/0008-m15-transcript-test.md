# Claim: M1.5 march step 19 — automated transcript test (`zig build test-console`)

- **Owner:** buffy (`freebuff/m15-transcript-test`)
- **Prompt / plan:** `docs/march-m15.md` step 19; `docs/m15-shell-core-design.md` §6 (the exact transcript already proven in-test)
- **Scope:** a named `zig build test-console` gate that proves the `dipshit>` prompt + command loop without manual typing: canonical transcript fixture checked in at `tests/transcript-console.txt`, the shell e2e test emits the captured mock transcript to `artifacts/`, and `tools/verify-transcript.sh` runs the shell module tests and diffs the emitted bytes against the fixture. Wired into `just test-console`, `just verify`, and CI.
- **Depends on:** M1.5 console & shell core (PR #16, claim 0004 ✅ — the mock-fed e2e transcript test in `kernel/src/shell.zig`)
- **Status:** ✅ 2026-08-06 — mock-level transcript gate landed; live `vm-serial.log` assertion deferred to claim 0002

## Notes

March row 19: "Feed `help`, `version`, `mem`, `echo test`; assert exact output in
`vm-serial.log`. `zig build test-console` proves prompt + commands without
manual typing. Gate on bytes the kernel actually sent, not on file evidence."

Live RX is gated on the VZ serial gate (claim 0002, 🔄, claimed by
`agent/buffy/m15-vz-serial-gate`) — the kernel adapter's `readByte` is an
`[inferred]` no-RX stub until a device is proven, so keystrokes cannot reach
a live VM today. The transcript test is therefore proven **at the mock
level**: the shell loop is transport-agnostic and its e2e test asserts the
exact output bytes on the same prompt/read/tokenize/exec path the kernel
will drive. The `vm-serial.log` assertion is the live half of the row and
stays deferred to claim 0002.

What this slice adds over PR #16 (whose e2e assertion lives inside
`kernel/src/shell.zig` as a string constant):

- `tests/transcript-console.txt` — the canonical expected transcript as a
  checked-in, human-reviewable fixture (the DoD screen in exact bytes).
- The e2e test additionally writes the captured mock output to
  `artifacts/m15-mock-transcript.txt` so the fixture is a generated,
  diffable artifact.
- `tools/verify-transcript.sh` — gate: `zig test kernel/src/shell.zig` must
  pass, then `diff -u tests/transcript-console.txt
  artifacts/m15-mock-transcript.txt` must be byte-identical.
- `zig build test-console` (build.zig), `just test-console`, `just verify`
  and CI wiring.

**Observed (2026-08-06):** `zig build test-console` PASS — emitted mock
transcript (2299 B) byte-identical to `tests/transcript-console.txt`; all 65
shell tests pass; all 7 modules pass `verify-unit-tests.sh`; `zig fmt
--check` and `zig build` pass; `verify-coordination.sh` ok — evidence
`artifacts/m15-transcript-{gate,unit-tests,coord}.txt`.

**Not claimed:** the live VM half of march row 19 (asserting the same bytes
in `vm-serial.log`) — gated on the VZ serial gate (claim 0002, 🔄); the
kernel adapter's `readByte` is an `[inferred]` no-RX stub, no device
register read.
