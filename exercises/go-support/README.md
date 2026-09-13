# Go support hands-on exercises (GOOS=virelai)

Three small exercises that let you verify VirelaiOS's Go support yourself,
on this machine, in under 15 minutes each. Each exercise has a goal, exact
commands, expected output, and a pass/fail check you perform yourself.

## What "Go support" means here

VirelaiOS is not Linux/Unix: it runs Go programs through a **fork of the
gc toolchain patched with a `GOOS=virelai` runtime** (source of truth:
`tools/go/`). The runtime talks to the kernel through the `svc #0` ADR 0007
syscall seam only — no libc, no POSIX. A Go program is cross-compiled on
the macOS host into a static ARM64 ELF, dropped into the host file channel
("share"), and `exec`'d from the `virelai>` console inside the VM.

## Prerequisites (one-time environment)

| Requirement | Check | Notes |
|---|---|---|
| Apple silicon Mac, macOS 27+ | `sw_vers -productVersion` | Virtualization.framework host |
| Zig 0.16.0 | `zig version` | must match `.zigversion` |
| Swift toolchain | `swift --version` | builds the VM runner |
| just | `just --version` | recipe runner |
| Homebrew bash/gnu-sed/jq/yq | `bash tools/env-check.sh` | run once per session |
| Go 1.27.x (stock) | `go version` | bootstrap for the fork build |
| Built kernel + disk image | `ls artifacts/disk.img` | recreate: `zig build` + `zig build image` |

One-time toolchain provisioning (several minutes on first run):

```bash
just go-toolchain
ls -l .build/go/     # expect GOHELLO/GOARGS/GOROUT/GOSTRESS/GOPANIC .ELF
```

## The exercises

1. **[Exercise 1 — Hello + GC inside the OS](exercise-1-hello-gc.md)**
   Run the prebuilt Go fixture in a real VM and watch the gc runtime boot,
   grow its heap, and complete a GC cycle.
2. **[Exercise 2 — Run your own Go program](exercise-2-your-own-go-program.md)**
   Write a Fibonacci program, cross-compile it with the fork toolchain,
   boot the OS, and see your own output come back from inside VirelaiOS.
3. **[Exercise 3 — Goroutines on two cores](exercise-3-goroutines-smp.md)**
   Run the concurrency fixture and prove goroutines, futex parking, and
   cross-core scheduling on the OS's two vCPUs.

## Where the evidence lives

- Verification logs: `artifacts/go-verify/` (gitignored).
- Gate specs (what each gate asserts): `tools/gate/specs/go-*.spec`.
- Go port overview + phase map: `tools/go/README.md`.

## Troubleshooting (shared)

- `bash tools/env-check.sh` complains → `brew install bash gnu-sed jq yq`
  and make sure `/opt/homebrew/bin` leads your `PATH`.
- A gate says `GOHELLO.ELF missing` → run `just go-toolchain` first.
- `artifacts/disk.img missing` → `zig build` then `zig build image`.
- VM window appears but nothing happens → close it and retry; VM boots are
  per-run isolated and safe to repeat.
- **`go-panic` FAILs with `exited status=139` and "no sys_exnotify row"**
  → your toolchain fork is stale (built before the phase-0c signal layer
  landed). Refresh it with the documented idempotent procedure and retry:
  `bash tools/go/apply.sh && just go-toolchain` — then re-run the gate.
  (Observed live on 2026-09-13: a fork provisioned before the 0c merge
  failed exactly this way; the refresh fixed it.)
- **`go build` says `cannot import absolute path`** for your program
  → the `.go` file does not exist at that path (Go reports a missing file
  confusingly in GOPATH mode). Check the path exists before building.
  (Observed live on 2026-09-13.)
- **VM fails to start: "Could not open variableStore ... Invalid argument"**
  → the `--vars` file exists but is empty or not a valid NVRAM store. Point
  `--vars` at a path that does not exist and let VMRunner create the fresh
  128 KiB store. (Observed live: a 0-byte store fails, a non-existent path
  boots.)
- **Runner refuses `--cvc-file`** ("require a SPIKE build")
  → rebuild the runner with the SPIKE flag:
  `swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE`.
- **"The process doesn't have the com.apple.security.virtualization
  entitlement"** after rebuilding the runner
  → re-apply the ad-hoc signature:
  `codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner`
  (a plain rebuild drops the entitlement; the gate fleet always re-signs).
  (Observed live on 2026-09-13.)
