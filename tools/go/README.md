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
**5 file edits + 5 new GOOS-gated files** (the sixth edit — proc.go's phase-0a thread gates — retired in 0b round 2, ADR 0027); everything else is stock.

## Layout

| Path | Role |
|---|---|
| `overlay/runtime/os_virelai.go` | the GOOS layer: osinit, write1, exit, time, readRandom, goenvs, no-signal surface, sbrk over sys_mmap |
| `overlay/runtime/sys_virelai_arm64.s` | the syscall gateway: `svc #0` with x8=slot (ADR 0007), CNTPCT_EL0 nanotime |
| `overlay/runtime/rt0_virelai_arm64.s` | entry (`_rt0_virelai_arm64`): argc=0/argv=nil, jumps to rt0_go |
| `overlay/runtime/netpoll_virelai.go` | blocking stub netpoll (copy of plan9's netpoll_stub) |
| `overlay/internal/goos/zgoos_virelai.go` | generated GOOS consts (gengoos shape, hand-applied) |
| `apply.sh` | copies a stock distribution + applies everything, idempotently, committing a git delta in the fork |
| `build-go.sh` | runs the host make.bash pass on first use (the cross-std pass is `GOVIRELAI_STD=1` opt-in for phase 2), then links programs with `-ldflags "-s -w"` at the Go default base (the gap loader maps at declared vaddrs; stripped to fit the 2 MiB exec staging bound) |
| `GOHELLO.GO` | the phase-0a first target: console + sbrk heap growth + a full GC cycle |

## Prerequisites

- A stock Go 1.27.1 distribution (Homebrew default:
  `/opt/homebrew/Cellar/go/1.27.1/libexec`, or point `GOROOT_STOCK` at it).
- `rsync`, `gsed` (GNU sed — see AGENTS.md's env-check note).

## Usage

```bash
bash tools/go/apply.sh            # create/patch the fork (../go-virelai)
bash tools/go/build-go.sh         # toolchain + .build/go/GOHELLO.ELF
                                   # (go-args needs both: add tools/go/goargs.go)
just gate go-hello                # class-B VZ gate: execs it, asserts serial
```

**The go-hello gate is not hermetic**: `just verify-vz` includes it, and it
refuses to run (honest setup failure) until
`bash tools/go/build-go.sh` has produced `.build/go/GOHELLO.ELF`. The first
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
- **0b remaining**: exec envp half (a `GOMAXPROCS` env override needs it).
- **0c**: kernel fault-delivery seam → `sigtrampgo`/`sigpanic` (recover(),
  tracebacks), Fuchsia-exception-channel pattern.
- **2**: `syscall`/`os` packages over the file channel; real netpoll over
  ADR 0009 events.

## Releasing upstream (someday)

Watch golang/go#73608 (`GOOSPKG`/`runtime/goos` overlay): if accepted, this
fork collapses into an overlay package (TamaGo's repo shows the migration
shape). Until then, rebase the fork each Go release (Aug/Feb cadence) —
expect a few hours per release; conflicts concentrate in `runtime/proc.go`
and `internal/platform/zosarch.go`.
