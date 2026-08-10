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
| `swift-spike-build` | A | gate | yes | yes | no | `swift build --package-path host/vm-runner -Xswiftc -DSPIKE` on the `xcode-27` public-preview arm64 runner (macOS 27 SDK; compiles the custom-virtio spike, claim 5844; does not boot) |
| `context` | A | gate | yes | yes | no | `zig build context` |
| `coordination` | A | gate | yes | yes | no | `bash tools/verify-coordination.sh` |
| `coordination-tooling` | A | gate | yes | yes | no | `bash tools/status/test-coordination.sh` |
| `mmu-debt` | A | gate | yes | yes | no | `bash tools/verify-mmu-debt.sh` |
| `verify-portable` | A | aggregate | no | no | no | `just verify-portable` (= legacy `just verify`) — the full class-A set |
| `bad-handoff` | B | gate | yes | no | yes | `bash tools/verify-bad-handoff.sh` |
| `marker` | B | gate | yes | no | yes | `bash tools/verify-marker.sh` (mechanism: `zig build marker`) |
| `nvram-console` | B | gate | yes | no | yes | `bash tools/verify-nvram-console.sh` (mechanism: `zig build nvram-console`) |
| `host-console-pty` | B | gate | yes | no | yes | `bash tools/verify-host-console.sh` |
| `serial-takeover` | B | gate | yes | no | yes | `zig build run` — **PASS 2026-08-08** (claim 1517); in `verify-vz` |
| `live-transcript-rx` | B | gate | yes | no | yes | `bash tools/verify-live-transcript.sh` — **PASS 2026-08-08** (claim 6684): live RX, host scripted keystrokes reach the kernel end to end and the `dipshit>` transcript is asserted in `vm-serial.log` |
| `live-exceptions` | B | gate | yes | no | yes | `bash tools/verify-live-exceptions.sh` — **PASS 2026-08-08** (claim 9746): VBAR_EL1 vectors installed; `dipshit> fault` triggers a real synchronous `udf` reported and resumed live (shell continues) |
| `live-timer` | B | gate | yes | no | yes | `bash tools/verify-live-timer.sh` — **PASS 2026-08-09** (claim 9187): a real CNTP PPI enters the EL1 IRQ vector; requires first-IRQ evidence plus `ticks=5 irq=5 poll=0` and a responsive shell; 3/3 boots |
| `live-tasks` | B | gate | yes | no | yes | `bash tools/verify-live-tasks.sh` — **PASS 2026-08-09** (claim 5275): tick-driven round-robin scheduler; the worker's report line (`tasks worker advances=N`, N≥1 — only possible after ≥ 2 real context switches) plus a shell that keeps answering commands proves both tasks advance across ticks |
| `live-userspace` | B | gate | yes | no | yes | `bash tools/verify-live-userspace.sh` — **PASS 2026-08-09** (claim 8215): real EL0t execution, two sequenced `svc #0` entries, return to EL0, timer preemption, and a responsive EL1h shell |
| `live-svc` | B | gate | yes | no | yes | `bash tools/verify-live-svc.sh` — **PASS 2026-08-10** (claim 3594, 1/1): real EL0 write, timer preemption, yield, and non-returning exit through the runtime syscall table; exact one-shot counters and a post-exit shell reply |
| `live-uaccess` | B | gate | yes | no | yes | `bash tools/verify-live-uaccess.sh` — **claim 6120**: EL0 passes an unmapped bad pointer to `sys_write`, observes `-3`/EFAULT, and survives to write a marker; the `uaccess` monitor command runs a validated copy (`valid=1`) and a raw copy from an unmapped address that takes a real EL1 data abort, recovered into EFAULT (`recovered=1`) with the shell still responsive |
| `live-addrspaces` | B | gate | yes | no | yes | `bash tools/verify-live-addrspaces.sh` — **claim 5804**: per-task TTBR0 with an EL1-only kernel overlay (VZ TTBR1 fallback — TTBR1=0, kernel identity-mapped in TTBR0, `t0sz=16`), the EL1h shell/worker tasks on the kernel root, the EL0 task on its OWN root whose EL0-accessible leaves are exactly text+stack (`text=0x00400000 stack=0x80000000`, `el0 >= 3`) with **zero EL0-accessible Device leaves (`el0_device=0`, MMIO excluded from EL0)**; the EL0 payload + uaccess recovery still pass on the new address space |
| `live-lifecycle` | B | gate | yes | no | yes | `bash tools/verify-live-lifecycle.sh` — **claim 6729**: the user task lifecycle — the EL0 task's `sys_exit` turns it into a zombie (`tasks user-el0 exited status=7`), the scheduler-owned **idle task** reaps it (`tasks user-el0 reaped`, pool shrinks), a runtime `spawn` command registers the demo task which enters the ring and advances (`spawn: spawn-demo id=N`, `tasks spawn-demo advances=N`), the `tasks` command reports **explicit states** (`state=` per row + `pool=/5 zombies=` header), and the shell stays responsive throughout |
| `live-reboot-shutdown` | B | gate | yes | no | yes | `bash tools/verify-live-reboot.sh` — **PASS 2026-08-08** (claim 0527): hard gate 6 — a real EFI `ResetSystem` from a live `dipshit>` shell; `reboot` resets the machine (second full takeover, fresh map key), `shutdown` powers it off (VM state → stopped), 4/4 boots |
| `live-fs` | B | gate | yes | no | yes | `bash tools/verify-live-fs.sh` — **PASS 2026-08-09** (claims 3475/6420): hard gate 5 — `ls`/`cat`/`write` persist through reboot **on the disk** via the FAT32 storage driver (claim 6420: `fat.zig` over the virtio-blk transport, run A writes to the live FAT volume, run B — same disk image — still lists/cats it; NVRAM persistence replaced), 1/1 pair |
| `verify-vz` | B | aggregate | no | no | yes | `just verify-vz` — serial takeover + bad-handoff + marker + nvram-console + host-console + live-transcript + live-fs + live-exceptions + live-timer + live-tasks + live-userspace + live-svc + live-uaccess + live-addrspaces + live-lifecycle + live-reboot-shutdown (Apple silicon only) |
| `console` | C | interactive | yes | no | yes | `zig build console` — interactive host serial console; needs a human at the keyboard |
| `vz-irq-api-audit` | D | diagnostic | no | no | yes | `bash tools/audit-vz-irq-api.sh` — read-only selected-Xcode SDK audit of Virtualization.framework and Hypervisor.framework GIC surfaces; claim 9187; no VM boot |
| `preexit-tx` | D | diagnostic | no | no | yes | `bash tools/verify-preexit-tx.sh` (mechanism: `zig build preexit-tx`) — claim 0017 |
| `tx-diag` | D | diagnostic | no | no | yes | `bash tools/verify-tx-diag.sh` (mechanism: `zig build tx-diag`) — claim 0018 |
| `tx-transition` | D | diagnostic | no | no | yes | `bash tools/verify-tx-transition.sh` — claim 0020 |
| `fw-mmu-capture` | D | diagnostic | no | no | yes | `bash tools/verify-fw-mmu-capture.sh` — claim 0021 |
| `t0sz25` | D | diagnostic | no | no | yes | `bash tools/verify-t0sz16.sh` (mechanism: `zig build kernel -Dt0sz25`) — claims 6460/1517 (legacy start-level regression) |
| `walk-probe` | D | diagnostic | no | no | yes | `zig build kernel -Dwalk-probe` (cold-address probe battery, `M2_WP_*` markers) — claims 7896/1517 |
| `t0sz16-walkprobe` | D | diagnostic | no | no | yes | `bash tools/verify-t0sz16-walkprobe.sh` — claims 7896/1517 (start-level/residual separation + production regression matrix) |

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
- **`swift-spike-build` runs on the `xcode-27` public-preview runner.**
  GitHub announced the Xcode 27 image (arm64, macOS 26 OS with Xcode 27 /
  the macOS 27.0 SDK) on 2026-07-16. It is the only GitHub-hosted way to
  compile the macOS-27-only custom-virtio spike (claim 5844); the
  macos-latest job builds the base runner against the macOS 26 SDK. The
  spike check boots no VM, so it stays class A despite needing the newest
  SDK.

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
GATE id=swift-spike-build class=A kind=gate ci=yes apple=no gate=yes cmd=swift build --package-path host/vm-runner -Xswiftc -DSPIKE  # xcode-27 public-preview runner (macOS 27 SDK); claim 5844
GATE id=context class=A kind=gate ci=yes apple=no gate=yes cmd=zig build context
GATE id=coordination class=A kind=gate ci=yes apple=no gate=yes cmd=bash tools/verify-coordination.sh
GATE id=coordination-tooling class=A kind=gate ci=yes apple=no gate=yes cmd=bash tools/status/test-coordination.sh
GATE id=mmu-debt class=A kind=gate ci=yes apple=no gate=yes cmd=bash tools/verify-mmu-debt.sh
GATE id=verify-portable class=A kind=aggregate ci=no apple=no gate=no cmd=just verify-portable
GATE id=bad-handoff class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-bad-handoff.sh
GATE id=marker class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-marker.sh
GATE id=nvram-console class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-nvram-console.sh
GATE id=host-console-pty class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-host-console.sh
GATE id=serial-takeover class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=zig build run
GATE id=live-transcript-rx class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-transcript.sh
GATE id=live-exceptions class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-exceptions.sh
GATE id=live-timer class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-timer.sh
GATE id=live-tasks class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-tasks.sh
GATE id=live-userspace class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-userspace.sh
GATE id=live-svc class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-svc.sh
GATE id=live-uaccess class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-uaccess.sh  # claim 6120: EFAULT contract + fault recovery
GATE id=live-addrspaces class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-addrspaces.sh  # claim 5804: per-task TTBR0 + EL1-only kernel overlay, MMIO excluded from EL0 (VZ TTBR1 fallback)
GATE id=live-lifecycle class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-lifecycle.sh  # claim 6729: user task lifecycle — spawn / exit / reap + explicit states + idle task
GATE id=live-reboot-shutdown class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-reboot.sh
GATE id=live-fs class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-fs.sh  # claim 6420: FAT32 storage driver (persistence on the disk, not NVRAM)
GATE id=verify-vz class=B kind=aggregate ci=no apple=yes gate=no cmd=just verify-vz
GATE id=console class=C kind=interactive ci=no apple=yes gate=yes cmd=zig build console
GATE id=vz-irq-api-audit class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/audit-vz-irq-api.sh
GATE id=preexit-tx class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-preexit-tx.sh
GATE id=tx-diag class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-tx-diag.sh
GATE id=tx-transition class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-tx-transition.sh
GATE id=fw-mmu-capture class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-fw-mmu-capture.sh
GATE id=t0sz25 class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-t0sz16.sh
GATE id=walk-probe class=D kind=diagnostic ci=no apple=yes gate=no cmd=zig build kernel -Dwalk-probe
GATE id=t0sz16-walkprobe class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-t0sz16-walkprobe.sh
<!-- GATE_INVENTORY:END -->
