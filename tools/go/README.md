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
**6 file edits + 5 new GOOS-gated files**; everything else is stock.

## Layout

| Path | Role |
|---|---|
| `overlay/runtime/os_virelai.go` | the GOOS layer: osinit, write1, exit, time, readRandom, goenvs, no-signal surface, sbrk over sys_mmap |
| `overlay/runtime/sys_virelai_arm64.s` | the syscall gateway: `svc #0` with x8=slot (ADR 0007), CNTPCT_EL0 nanotime |
| `overlay/runtime/rt0_virelai_arm64.s` | entry (`_rt0_virelai_arm64`): argc=0/argv=nil, jumps to rt0_go |
| `overlay/runtime/netpoll_virelai.go` | blocking stub netpoll (copy of plan9's netpoll_stub) |
| `overlay/internal/goos/zgoos_virelai.go` | generated GOOS consts (gengoos shape, hand-applied) |
| `apply.sh` | copies a stock distribution + applies everything, idempotently, committing a git delta in the fork |
| `build-go.sh` | runs both make.bash passes, then links programs with `-ldflags "-T 0x400000 -s -w"` (the kernel's fixed text aperture; stripped to fit the 1 MiB exec staging bound) |
| `GOHELLO.GO` | the phase-0a first target: console + sbrk heap growth + a full GC cycle |

## Prerequisites

- A stock Go 1.27.1 distribution (Homebrew default:
  `/opt/homebrew/Cellar/go/1.27.1/libexec`, or point `GOROOT_STOCK` at it).
- `rsync`, `gsed` (GNU sed — see AGENTS.md's env-check note).

## Usage

```bash
bash tools/go/apply.sh            # create/patch the fork (../go-virelai)
bash tools/go/build-go.sh         # toolchain + .build/go/GOHELLO.ELF
just gate go-hello                # class-B VZ gate: execs it, asserts serial
```

The fork lives OUTSIDE the repo (`../go-virelai` by default; `--fork-dir`
or `GO_FORK_DIR` to move it) — it is a build artifact; this directory is
the reviewable patch series. `GOTOOLCHAIN=local` is exported by
`build-go.sh` so cmd/go can never silently swap back to a stock toolchain.

## Phase map (issue #1163)

- **0a (this)**: single-thread, no sysmon (one `proc.go` delta), sbrk
  memory, no signals, cooperative preemption only. Kernel side: 3-segment
  gap-layout ELF loader, mmap cap lifts, `sys_getrandom` (slot 72, M51 #1166), FPEN
  armed.
- **0b**: kernel slots 72/73 (`thread_create`, futex) + exec argv/envp →
  drop the haveSysmon delta, real threads, `GOMAXPROCS > 1`.
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
