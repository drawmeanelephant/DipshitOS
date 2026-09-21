# btmath — Bubble Tea on VirelaiOS

`BTMATH.ELF` is a Bubble Tea program (`charm.land/bubbletea/v2`, pinned v2.0.9)
running as a **VirelaiOS userland app** under `GOOS=virelai`, `GOARCH=arm64`.

It exists to answer one question with evidence: *can we use Bubble Tea on this
operating system?* Nothing in the framework is reimplemented. The same
`tea.Model` / `Init` / `Update` / `View` program, the same `tea.Cmd` plumbing,
the same key decoding and `WindowSizeMsg` handling run here; only the two I/O
seams come from the guest.

## What the OS supplies

| Bubble Tea seam | VirelaiOS backend |
|---|---|
| Input (`tea.WithInput`, an `io.Reader`) | `keyScript` — a paced byte script, fed through Bubble Tea's real key decoder |
| Output (`tea.WithOutput`, an `io.Writer`) | `consoleWriter` — the kernel console (`vi.Console`) |
| Window size | `tea.WithWindowSize(80,24)`; a VirelaiOS console is not a POSIX tty to `ioctl` a size from, and Bubble Tea still delivers it as a `WindowSizeMsg` |
| Terminal size / raw mode | none — `charmbracelet/x/term` degrades to its `term_other.go` stubs for a GOOS it does not ship |

## The port: four symbols

Upstream Bubble Tea defines its terminal hooks only for the OSes it ships.
`termios_other.go` already covers unknown GOOS values, but four symbols live
exclusively in the Unix/Windows files, so `GOOS=virelai` fails to link with:

```
tea.go:698:8:  p.listenForResize undefined
tea.go:780:8:  undefined: suspendSupported
tty.go:18:2:   undefined: suspendProcess
tty.go:28:11:  p.initInput undefined
```

The vendored copy therefore carries two `//go:build virelai` files:

- `tty_virelai.go` — `initInput` (no termios to capture: the guest console has
  no raw-mode state) and `suspendSupported = false` / `suspendProcess() {}`.
- `signals_virelai.go` — `listenForResize` (no SIGWINCH; the loop only ends
  with the program context).

Nothing else was needed: all of Bubble Tea's dependencies are pure Go and
compile for the target unchanged.

## Layout

```
user/go/btmath/{main.go,model.go}   the app
user/go/vendor/charm.land/bubbletea/v2/   pinned Bubble Tea + the virelai backend
user/go/vendor/…                    its transitive dependencies (vendored)
tools/go/build-btmath.sh            the guest build
tools/gate/specs/go-btmath.spec     the live-VZ gate
```

## Build

```sh
bash tools/go/build-btmath.sh      # -> .build/go/BTMATH.ELF
```

Needs the `GOOS=virelai` fork toolchain (`tools/go/apply.sh && just go-toolchain`).

Size: **3,604,640 bytes**, well inside `exec_image_max` (32 MiB). The 2 MiB
figure in the older build scripts is the *whole-file staging buffer*, which a
gap-layout Go image never uses — the loader streams its segments
(`kernel/src/exec.zig`, M70c-K / #1504).

## Run (in the guest)

```
exec BTMATH.ELF
exec BTMATH.ELF --keys 1,7,ret --out /host/BTMATH/SESSION.TXT
```

Flags: `--rounds`, `--seed`, `--keys`, `--out`, `--w`, `--h`, `--sink stdout`
(`--sink stdout` is for host runs, where the guest console degrades to ENOSYS).

## Proof

- The **same source** built for the host runs a full scripted session:
  `played=5 score=65 correct=3 wrong=2` — rendered frames, key decoding,
  feedback, scoring and persistence all observed.
- Built for `virelai/arm64` it produces a static aarch64 ELF.
- `tools/gate/specs/go-btmath.spec` asserts the run on VZ, ending with a
  **host-side read** of `/host/BTMATH/SESSION.TXT`, so a stub that printed
  markers without playing the game cannot pass.

## Why the build passes `-tags virelaitoolchain` (and why that is temporary)

A first guest build loads and runs, but it needs one build tag, and the reason
is worth keeping.

`kernel/src/elf.zig` sets `load_max = 32 MiB` and compares it against the **sum
of every PT_LOAD `p_memsz`** — declared address space, not bytes read. Bubble
Tea's closure (154 packages) reaches `crypto/internal/fips140/drbg` through
`crypto/rand`, and that package declares:

    var memory entropy.ScratchBuffer     // exactly 33,554,432 B, .noptrbss

33,554,432 B is precisely `load_max`. One demand-backed scratch buffer consumed
the entire budget, so the image was refused with `segment_too_large`:

    exec: BTMATH.ELF
    error: image too large for the 0x200000-byte staging buffer
           (only a gap-layout static ELF streams past it)

That message is a fall-through for an oversized file, not a statement about the
layout — the image is gap-layout, identical in shape to `GOBIG.ELF`, which
streams. Measured totals:

| image | total memsz | verdict |
|---|---|---|
| `hello` (no Bubble Tea) | 1,226,404 | loads |
| `GOBIG.ELF` (no Bubble Tea) | 9,616,852 | streams |
| minimal Bubble Tea, no `fmt`/`time` | 37,229,892 | refused |
| this app | 37,269,084 | refused |
| this app, `-tags virelaitoolchain` | **3,707,660** | **loads and runs** |

`tools/go/apply.sh` §3g8 records the same object hitting `cmd/compile`, and its
tag is normally scoped to `cmd/compile` and `cmd/link` because a virelai guest
must keep a working `crypto/rand`. **btmath calls no crypto**, so the DRBG is
dead weight here — but the tag's stub `getEntropy` PANICS if it is ever reached,
by design. This is a deliberate, local trade, not the right end state.

**Remove the tag** once the loader stops charging demand-backed address space as
if it were resident memory — either bound the file-backed bytes (`filesz`) or
exempt `.bss`/`noptrbss` in `elf.zig`. That fixes this app, `cmd/compile`, and
any future large Go image at once.

## Proven on VirelaiOS

    exec: loaded BTMATH.ELF size=0x13bc54 entry=0x89070
    btmath: start
    Bubble Math  (Bubble Tea on VirelaiOS)
    ... Correct. +10 points / Not quite: 5, not 6. / Skipped. ...
    Session over. Final score 65.
    btmath: saved /host/BTMATH/SESSION.TXT 92B
    btmath: round played=5 score=65 correct=3 wrong=2
    btmath: OK

and the guest wrote `/host/BTMATH/SESSION.TXT`, read back on the host.

## Verifying it — inside the guest, with no shell

VirelaiOS has no bash, no `sh`, no libc and no Unix tooling. Nothing this app
needs is on that side of the line: `BTMATH.ELF` is a **static ELF with no
`PT_INTERP`** — no dynamic loader, no libc — and its entire OS surface is six
calls into the guest SDK:

| call | used for |
|---|---|
| `vi.Console` / `vi.ConsoleLine` | frames and markers, straight to the kernel console |
| `vi.FileOpen` / `vi.FileWriteAll` / `vi.FileClose` | the session record in the host share |
| `vi.Exit` | the exit status |

No `exec`, no fork, no `PATH` lookup, no `#!/bin/sh`. So the proof runs *in*
the guest — you type one line at the `virelai>` monitor and read the verdict
off the console:

    virelai> exec BTMATH.ELF --selftest

The app plays the scripted session through Bubble Tea and then checks its own
results, printing one line per check:

    btmath: selftest begin checks=12
    btmath: selftest rounds got=5 want=5 PASS
    btmath: selftest score got=65 want=65 PASS
    ...
    btmath: selftest RESULT PASS checks=12 failed=0

Exit status 0 on PASS, 1 on any failure, so it also works unattended in a gate.
`--selftest` adds no dependency: it is the same binary, the same seams.

**Inert dependency code, disclosed.** Two vendored files — `charm.land/bubbletea/v2/exec.go`
(`tea.ExecProcess`) and `github.com/charmbracelet/colorprofile/env.go` — reference
`os/exec`, and both are compiled in unconditionally. Neither is called by this
app or anywhere on Bubble Tea's own render/input path, so nothing forks; but the
code is present, and if it were ever invoked on VirelaiOS it would fail. Stated
rather than hidden.

**Host-side scripts are build tooling, not runtime.** `tools/go/build-btmath.sh`
and the gate spec are bash because every build and gate in this repository is;
they compile the artifact and boot the VM from macOS. They are never needed
inside the guest, and nothing they do is required for the app to run.

### What each layer proves

| Layer | Command | Runs where | Proves |
|---|---|---|---|
| Self-check | `exec BTMATH.ELF --selftest` | **in the guest** | the app plays the session and its results are what it claims |
| Gate | `just gate go-btmath` | macOS + VZ | the same, on a real boot, plus a host-side read of the record |
| Build | `bash tools/go/build-btmath.sh` | macOS | the artifact compiles for `GOOS=virelai` |
