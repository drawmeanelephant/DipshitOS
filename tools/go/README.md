# tools/go — the GOOS=virelai gc toolchain fork

Issue #1163 (phase 0a). This directory holds the **source of truth** for
VirelaiOS's Go support: an overlay + a set of small source edits applied to
a stock Go distribution, producing a `GOOS=virelai GOARCH=arm64` gc
toolchain. No POSIX, no libc, no Linux ABI — the runtime talks to the
kernel through the ADR 0007 `svc #0` seam only.

## Why a fork

Upstream Go has no third-party-GOOS mechanism (golang/go#35956 declined
`GOOS=none`; golang/go#73608's `GOOSPKG` overlay proposal is still open).
Every non-POSIX port (Fuchsia, TamaGo, IBM z/OS) is a maintained fork
tracking each release. The maintenance surface here is deliberately tiny:
**6 file edits + 7 new GOOS-gated files** (proc.go's phase-0a thread gates retired in 0b round 2, ADR 0027; signal_virelai.go is phase 0c, #1228; the phase-2 edit is `apply.sh` step 3h, which widens `runtime/netpoll.go`'s build tag so the platform-independent poller core compiles for virelai); everything else is stock.

## Layout

| Path | Role |
|---|---|
| `overlay/runtime/os_virelai.go` | the GOOS layer: osinit, write1, exit, time, readRandom, goenvs, futex-backed lock_sema, sbrk over sys_mmap (the signal surface moved to signal_virelai.go in 0c) |
| `overlay/runtime/signal_virelai.go` | phase 0c (#1228): initsig registers sigtramp via slot 75, virfaulthandler arms sigpanic, crash() exits through the syscall |
| `overlay/runtime/sys_virelai_arm64.s` | the syscall gateway: `svc #0` with x8=slot (ADR 0007), CNTPCT_EL0 nanotime |
| `overlay/runtime/rt0_virelai_arm64.s` | entry (`_rt0_virelai_arm64`): argc/argv block → SysV argv array + envp (issue #1226) |
| `overlay/runtime/netpoll_virelai.go` | phase 2 (#1163): the REAL integrated poller (netpollinit/open/close/arm/poll/break) driving slot 76 `sys_sock_ready`; the parked G comes back through stock `netpollready -> netpollunblock -> goready` |
| `overlay/internal/goos/zgoos_virelai.go` | generated GOOS consts (gengoos shape, hand-applied) |
| `apply.sh` | copies a stock distribution + applies everything, idempotently, committing a git delta in the fork |
| `build-go.sh` | runs the host make.bash pass on first use (the cross-std pass is `GOVIRELAI_STD=1` opt-in for phase 2), then links programs with `-ldflags "-s -w"` at the Go default base (the gap loader maps at declared vaddrs; stripped to fit the 2 MiB exec staging bound) |
| `hello.go` / `goargs.go` / `goroutines.go` / `gostress.go` / `gopanic.go` / `gonet.go` | the class-B fixtures: console + sbrk heap growth + a full GC cycle; raw-ELF argv+envp (`GOMAXPROCS` override); goroutines + futex + the cross-core proof; 0b breadth (GC/channel/timer/futex, issue #1227); 0c fault delivery + recover + traceback (issue #1228) |

## Prerequisites

- A stock Go 1.27.1 distribution (Homebrew default:
  `/opt/homebrew/Cellar/go/1.27.1/libexec`, or point `GOROOT_STOCK` at it).
- `rsync`, `gsed` (GNU sed — see AGENTS.md's env-check note).

## Usage

```bash
bash tools/go/apply.sh            # create/patch the fork (../go-virelai)
just go-toolchain                  # builds .build/go/{GOHELLO,GOARGS,GOROUT,GOSTRESS,GOPANIC}.ELF
just gate go-hello                 # class-B VZ gate: execs it, asserts serial
just gate go-args                  # class-B VZ gate: raw-ELF argv + envp / GOMAXPROCS
just gate go-goroutines            # class-B VZ gate: threads/futex + cross-core
just gate go-stress                # class-B VZ gate: GC / channel / timer / futex breadth
just gate go-panic                 # class-B VZ gate: fault delivery + recover + traceback
```

**The Go-runtime gates are not hermetic**: `just verify-vz` includes them,
and each refuses to run (honest setup failure) until
`just go-toolchain` has produced its `.build/go/*.ELF` fixture. The first
build takes several minutes (one `make.bash` pass; the cross-std pass is
phase-2 opt-in via `GOVIRELAI_STD=1`); every Go release
rebase re-runs `apply.sh` on a fresh distribution copy. Auto-building the
fork inside the gate was considered and rejected — a multi-minute external
toolchain build inside every fleet run hides gate latency and couples the
fleet to the host's Go install.

The fork lives OUTSIDE the repo (`../go-virelai` by default; `--fork-dir`
or `GO_FORK_DIR` to move it) — it is a build artifact; this directory is
the reviewable patch series. `GOTOOLCHAIN=local` is exported by
`build-go.sh` so cmd/go can never silently swap back to a stock toolchain.

## Phase map (issue #1163 / #1194)

- **0a**: single-thread, no sysmon (one `proc.go` delta), sbrk memory, no
  signals, cooperative preemption only. Kernel side: 3-segment gap-layout
  ELF loader, mmap cap lifts, `sys_getrandom` (slot 72, M51 #1166), FPEN
  armed. Landed #1187/#1196.
- **0b (this round, #1214)**: kernel slots 73/74 (`sys_thread`/`sys_futex`,
  ADR 0027) — **every `proc.go` delta is retired** (`patch_proc.py` is
  deleted; proc.go is byte-identical to upstream), newosproc maps Ms onto
  same-process kernel tasks, lock_sema parks on the futex,
  `numCPUStartup = 2`, exec argv on the gap path. The gate is
  `go-goroutines` (N=8 goroutines > GOMAXPROCS=2, `sys_thread` calls >= 2,
  the cross-core `task=GOROUT.ELF` smp proof). Round 2 also root-caused the
  go-args boot flake: the sbrk heap reservation (~1.2 GiB) swallowed the old
  ASLR stack band — the band moved to [0x1_0000_0000, 0x2_0000_0000) and
  `sys_mmap` now refuses collisions with the caller's own apertures
  (ADR 0007 amendment).
- **0b remaining**: none — envp half landed (#1226): gap-path `KEY=VALUE`
  block after argv, `goenvs` fills `envs`, `set GOMAXPROCS=N` overrides
  the default. `numCPUStartup` stays **2** (ADR 0027 D6; two vCPUs).
  Breadth stress (#1227): `go-stress` (GC churn, channel fan-out, timer
  pacing, futex contention at N=32).
- **0c**: landed (#1228) — kernel fault-delivery seam (slot 75
  `sys_exnotify`, ADR 0007 amendment) in the Fuchsia-exception-channel
  pattern, synchronous form: deliverable EL0 faults redirect to
  `sigtramp`, `virfaulthandler` arms `sigpanic` on the faulting stack
  (recover() works, the unwinder crosses the injected frame — proven by
  `go-panic`), `crash()` exits through the syscall instead of faulting.
  Async preemption stays OFF (no signals, only synchronous delivery).
- **2**: `syscall`/`os` packages over the file channel; real netpoll over
  ADR 0009 events (landed #1350).
- **2.1**: user-space clock (`vsys.Nanotime` reads CNTPCT_EL0) so `Conn`
  deadlines are wall-clock instants instead of scheduler-tick budgets;
  `Write` reports `ErrShortWrite` on truncation (claim #1358).

## Releasing upstream (someday)

Watch golang/go#73608 (`GOOSPKG`/`runtime/goos` overlay): if accepted, this
fork collapses into an overlay package (TamaGo's repo shows the migration
shape). Until then, rebase the fork each Go release (Aug/Feb cadence) —
expect a few hours per release; conflicts concentrate in `runtime/proc.go`
and `internal/platform/zosarch.go`.
