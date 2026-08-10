# Claim: Milestone-three ragshit dogfood pass

- **Owner:** Codex (`agent/codex/m3-ragshit-dogfood`)
- **Prompt / plan:** `docs/m3-ragshit-dogfood-prompt.md`
- **Scope:** Fresh local index and milestone-three userspace/syscall bundle; coverage and ranking diagnosis with only evidence-driven fixes under `tools/ragshit/`; dogfood review of the syscall-ABI prompt against canonical status/roadmap; saved artifacts and coordination records
- **Depends on:** —
- **Status:** ✅ done 2026-08-09 — fresh index + complete anchored milestone-three bundle; doctor/determinism/coordination green; syscall and runner contract findings recorded; no engine change justified

## Notes

Deterministic claim ID from
`bash tools/status/claim-id.sh 'agent/codex/m3-ragshit-dogfood' 'm3-ragshit-dogfood'`
= 1594.

Planned verification: fresh `ragshit index`, milestone-three bundle, targeted
queries with scoring explanations and bundle coverage audit, full ragshit test
suite if the engine changes, `ragshit doctor`, deterministic bundle comparison,
and `bash tools/verify-coordination.sh`. This card makes no VZ run and claims no
new hardware observation.

## Review findings

Full review with file/line evidence: `artifacts/m3-ragshit-review.md`.

- The syscall prompt contradicts the landed x8-selector/x0-argument ABI and
  the architectural SPSR modes (EL0t=0, EL1t=4, EL1h=5), and incorrectly
  attributes an ELR increment to the handled SVC path.
- Required `yield`/`exit` behavior has no landed scheduler lifecycle or
  exception-return seam: `SvcDispatcher` can resume only the same frame, and
  the fixed scheduler has no yield/terminate/reap/task-state API. Reaping also
  overlaps the later user-lifecycle card.
- `sys_write` needs an explicit allowed-EL0-range check and a console
  serialization/deferred-output rule; bounded pointer arithmetic alone does
  not keep the kernel from reading privileged identity-mapped memory on the
  caller's behalf, and the polled console is documented as non-reentrant.
- The prompt's table test reserves slot 3 despite requiring `sys_exit` there;
  `syscalls` is called optional although both class-A and class-B gates require
  it; and `sys_ping` is described as an arbitrary echo although the landed
  proof returns a monotonic call count.
- PR #60 is already landed but still called a draft, while canonical status
  and roadmap still say userspace is later/next and need reconciliation by
  the active syscall stream.
- The optional runner card is substantially already complete from claim 6684:
  `--script`/`--script-expect`, duplex injection, teeing, fixture assertions,
  and live evidence all exist. Only per-burst/delay grammar remains as a
  plausible narrowed follow-up.

The runtime-built ADR 0005 rule, current registry-count bump, transcript
fixture note, and new live-gate registration requirement are aligned.

Retrieval result: the broad example query was under-specified, while an
exact-identifier/contract-phrase query produced the required surface (68
sources; only four unrelated score<0.6 omissions). Repeated renders were
byte-identical. This did not justify changing ranking or bundle code.
