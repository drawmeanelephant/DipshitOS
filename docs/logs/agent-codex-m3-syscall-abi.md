# Log — `agent/codex/m3-syscall-abi`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-09** — *Codex (`agent/codex/m3-syscall-abi`)*: claim 3594 filed
  from `main` at `6b1b8cd`, after confirming PR #60 merged as `65ad6af` and
  reviewing claim 8215, its branch log, diff, and landed SVC/scheduler seams.
  Preflight found that prompt-only commit `6b1b8cd` incorrectly transcribed
  the proven ABI as number+result in x0; landed code/evidence use x8 for the
  selector and x0 for argument/result. The implementation will preserve that
  real contract, document the discrepancy, add the runtime 64-slot syscall
  layer + strictly required scheduler hooks, and verify class A before any VZ
  run. No uaccess/process/address-space/loader work is claimed. · 🔄 in progress

- **2026-08-10** — *Codex (`agent/codex/m3-syscall-abi`)*: claim 3594
  completed. Added ADR 0007, runtime 64-slot x8-selected syscall dispatch,
  `ping`/bounded `write`/`yield`/non-returning `exit`, exact counters and
  monitor output, scheduler return-frame hooks, user-aperture validation, and
  the live-SVC gate. Review invalidated the first live artifact (escaped LF,
  replaying FIFO, and cooperative yield before the inherited timer witness);
  all three were fixed before publication. Corrected class B: live-svc 1/1
  with a 3,987-byte one-shot transcript and exact counts; live-userspace,
  live-timer, and live-tasks 1/1 each. Affected class A passed, including all
  present module tests, guest build, and Swift runner build. `just` is absent
  on the host; the explicit aggregate recipe was run manually, with its old
  live-SVC output explicitly superseded by the corrected gate. · ✅ done
