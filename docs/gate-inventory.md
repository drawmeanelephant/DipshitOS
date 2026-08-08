# DipshitOS verification gate inventory

> Canonical classification of every verification command. **A green GitHub CI
> badge proves class A only** — it says nothing about the Apple-silicon
> Virtualization.framework hardware gates (class B), the interactive gates
> (class C), or the diagnostics (class D). Run the class-B set with
> `just verify-vz` on a real Apple silicon host. Per-gate pass/fail status
> lives in [`docs/status.md`](status.md); this file is the classification,
> not the status.

## Classes

- **A — portable / build CI.** Deterministic, no Apple silicon, no VZ VM.
  Runs in GitHub CI (`.github/workflows/ci.yml`) and as `just verify-portable`
  (`just verify` is a legacy alias). A green CI badge means exactly these
  passed and nothing else.
- **B — Apple-silicon Virtualization.framework hardware gate.** Boots a real
  VZ VM on Apple silicon. GitHub-hosted CI does **not** run these and cannot
  prove them; run `just verify-vz` on a development host. Evidence lives
  under `artifacts/` and status in `docs/status.md`.
- **C — interactive / manual hardware gate.** Requires a human at the
  keyboard. Not automatable, not in CI.
- **D — diagnostic experiment.** Answers a question (claims 0017/0018/0020/
  0021); **not an acceptance gate**. Passing a diagnostic proves nothing
  about the milestone.

## Gate table

| ID | Class | Kind | Gate? | CI? | Apple silicon + VZ? | Command |
|----|-------|------|-------|-----|----------------------|---------|
| `fmt` | A | gate | yes | yes | no | `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` |
| `unit-tests` | A | gate | yes | yes | no | `bash tools/verify-unit-tests.sh` |
| `transcript-mock` | A | gate | yes | yes | no | `zig build test-console` (→ `bash tools/verify-transcript.sh`) |
| `guest-build` | A | gate | yes | yes | no | `zig build` |
| `image-build` | A | gate | yes | yes | no | `zig build image` |
| `inspect` | A | gate | yes | yes | no | `zig build inspect` |
| `swift-runner-build` | A | gate | yes | yes | no | `swift build --package-path host/vm-runner` (build only — does not boot) |
| `context` | A | gate | yes | yes | no | `zig build context` |
| `coordination` | A | gate | yes | yes | no | `bash tools/verify-coordination.sh` |
| `coordination-tooling` | A | gate | yes | yes | no | `bash tools/status/test-coordination.sh` |
| `mmu-debt` | A | gate | yes | yes | no | `bash tools/verify-mmu-debt.sh` |
| `verify-portable` | A | aggregate | no | no | no | `just verify-portable` (= legacy `just verify`) — the full class-A set |
| `bad-handoff` | B | gate | yes | no | yes | `bash tools/verify-bad-handoff.sh` |
| `marker` | B | gate | yes | no | yes | `bash tools/verify-marker.sh` (mechanism: `zig build marker`) |
| `nvram-console` | B | gate | yes | no | yes | `bash tools/verify-nvram-console.sh` (mechanism: `zig build nvram-console`) |
| `host-console-pty` | B | gate | yes | no | yes | `bash tools/verify-host-console.sh` |
| `serial-takeover` | B | gate | yes | no | yes | `zig build run` — **blocked** (claim 0002); not in `verify-vz` until it can pass |
| `live-transcript-rx` | B | gate | yes | no | yes | assert transcript bytes in `vm-serial.log` on a live VZ run — **deferred** to claim 0002; no script yet |
| `verify-vz` | B | aggregate | no | no | yes | `just verify-vz` — bad-handoff + marker + nvram-console + host-console (Apple silicon only) |
| `console` | C | interactive | yes | no | yes | `zig build console` — interactive host serial console; needs a human at the keyboard |
| `preexit-tx` | D | diagnostic | no | no | yes | `bash tools/verify-preexit-tx.sh` (mechanism: `zig build preexit-tx`) — claim 0017 |
| `tx-diag` | D | diagnostic | no | no | yes | `bash tools/verify-tx-diag.sh` (mechanism: `zig build tx-diag`) — claim 0018 |
| `tx-transition` | D | diagnostic | no | no | yes | `bash tools/verify-tx-transition.sh` — claim 0020 |
| `fw-mmu-capture` | D | diagnostic | no | no | yes | `bash tools/verify-fw-mmu-capture.sh` — claim 0021 |

Notes:

- **Raw build steps are classed with their gate.** `zig build marker`,
  `zig build nvram-console`, `zig build preexit-tx`, `zig build tx-diag`,
  `zig build bad-handoff` are the mechanisms behind their verify scripts and
  boot VZ VMs, so they carry the same class (B or D) and the same Apple
  silicon requirement. `zig build kernel` and `zig build bad-handoff` build
  artifacts only (no VM) and are class-A tooling, not gates.
- **Tooling that is not a verification gate:** `ragshit`, `just impact`,
  `just refresh-indexes` are developer tooling, not gates.
- **Class A is exactly what GitHub CI proves.** CI also builds the Swift
  runner, but a successful build is not a boot; only class-B runs on Apple
  silicon produce hardware-gate evidence.

## Machine-readable records

Fixed-width prefix, `cmd=` is the last field and may contain spaces. A
preflight can extract records with
`sed -n '/^<!-- GATE_INVENTORY:START -->$/,/^<!-- GATE_INVENTORY:END -->$/p'`
and filter on `class=…`, `ci=…`, `apple=…`, `gate=…`.

<!-- GATE_INVENTORY:START -->
GATE id=fmt class=A kind=gate ci=yes apple=no gate=yes cmd=zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
GATE id=unit-tests class=A kind=gate ci=yes apple=no gate=yes cmd=bash tools/verify-unit-tests.sh
GATE id=transcript-mock class=A kind=gate ci=yes apple=no gate=yes cmd=zig build test-console
GATE id=guest-build class=A kind=gate ci=yes apple=no gate=yes cmd=zig build
GATE id=image-build class=A kind=gate ci=yes apple=no gate=yes cmd=zig build image
GATE id=inspect class=A kind=gate ci=yes apple=no gate=yes cmd=zig build inspect
GATE id=swift-runner-build class=A kind=gate ci=yes apple=no gate=yes cmd=swift build --package-path host/vm-runner
GATE id=context class=A kind=gate ci=yes apple=no gate=yes cmd=zig build context
GATE id=coordination class=A kind=gate ci=yes apple=no gate=yes cmd=bash tools/verify-coordination.sh
GATE id=coordination-tooling class=A kind=gate ci=yes apple=no gate=yes cmd=bash tools/status/test-coordination.sh
GATE id=mmu-debt class=A kind=gate ci=yes apple=no gate=yes cmd=bash tools/verify-mmu-debt.sh
GATE id=verify-portable class=A kind=aggregate ci=no apple=no gate=no cmd=just verify-portable
GATE id=bad-handoff class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-bad-handoff.sh
GATE id=marker class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-marker.sh
GATE id=nvram-console class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-nvram-console.sh
GATE id=host-console-pty class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-host-console.sh
GATE id=serial-takeover class=B kind=gate ci=no apple=yes gate=yes status=blocked cmd=zig build run
GATE id=live-transcript-rx class=B kind=gate ci=no apple=yes gate=yes status=deferred cmd=(none -- deferred to claim 0002)
GATE id=verify-vz class=B kind=aggregate ci=no apple=yes gate=no cmd=just verify-vz
GATE id=console class=C kind=interactive ci=no apple=yes gate=yes cmd=zig build console
GATE id=preexit-tx class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-preexit-tx.sh
GATE id=tx-diag class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-tx-diag.sh
GATE id=tx-transition class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-tx-transition.sh
GATE id=fw-mmu-capture class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-fw-mmu-capture.sh
<!-- GATE_INVENTORY:END -->
