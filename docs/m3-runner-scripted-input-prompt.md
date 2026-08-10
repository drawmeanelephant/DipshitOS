# Milestone three — host runner scripted-input mode (OPTIONAL / deferrable)

Planning-first agent prompt for DipshitOS. Feed this file to the
implementing agent. **Optional card:** add a fixture-driven scripted-input
mode to the Swift host runner so live gates can inject deterministic
keystroke sequences into the guest serial input without a human at the
keyboard. Defer if it risks the EL0/SVC or syscall-ABI streams' live-gate
runs (they rebuild and boot the runner on the same dev host).

- Branch: `agent/.../m3-runner-scripted-input` (claim first via
  `docs/claims/` + a log entry in `docs/logs/`; merge per ADR 0003)
- Date: 2026-08-09
- Depends on: — (touches `host/vm-runner/` only — disjoint from
  `kernel/`, `tools/`, and `docs/`; agents on separate branches build the
  runner from their own branch, so concurrent live-gate runs are not
  affected by in-flight edits)
- Inputs (read first): `AGENTS.md`, `host/vm-runner/Package.swift`,
  `host/vm-runner/Sources/VMRunner/main.swift` (the `--console` duplex
  attachment and the evidence-path attachment — claims 0003/6684),
  `docs/status.md` (live-gate section), `docs/gate-inventory.md`.

## Scope

1. Add a `--script <file>` mode (or equivalent flag) to the Swift runner:
   read a keystroke fixture (plain text, one line per input burst or a
   simple delay grammar) and inject it into the guest serial input handle,
   teeing guest output live as `--console` does.
2. Keep the default `--console` behavior and the evidence path
   (`zig build run`) byte-compatible and unchanged.
3. Prove it with a deterministic fixture: boot the VM, run a short script
   (e.g., `help` → `version` → `echo scripted-ok`), and assert the
   replies in the teed log. This is the seed for future live gates like
   the syscall card's `tools/verify-live-svc.sh` (which may adopt it or
   keep its own harness — do not edit that script; it is the syscall
   card's file).

## Do not

- Touch `kernel/`, `tools/verify-*.sh`, or `docs/status.md` /
  `docs/gate-inventory.md` (active-stream files; the syscall card owns the
  live-svc gate).
- Change the evidence-path attachment semantics (nil-input file handle for
  `zig build run` must stay nil-input — claims 0003/6684).
- Claim any new hardware behavior; this is host tooling, class C/D at most.

## Process (hard gate)

1. Claim before you start (claim-id.sh, 🔄), append to your branch log.
2. Implement in `host/vm-runner/`; add host-side tests if the runner has
   any test scaffolding (keep them out of the kernel test suite).
3. Verify: `swift build --package-path host/vm-runner` (both default and
   the macOS-27 spike define used by CI), plus one manual/scripted VZ run
   with evidence saved under `artifacts/m3-runner-script-*`.
4. Append the log, flip the claim to ✅, refresh indexes, open a draft PR
   with `gh` (ADR 0003).

## Definition of done

A `--script` fixture mode that injects a deterministic input sequence and
tees the transcript, proven by a saved VZ run, with the evidence path and
`--console` unchanged. If the syscall card's live-gate runs are on the
same host at the same time, **defer this card** — the queue is long enough
without risking a flaky class-B gate.
