# ADR 0035: self-hosting M70c — what the guest can actually exec

- Status: ACCEPTED
- Date: 2026-09-19
- Issue: #1455 (M70c — this measurement is its first deliverable) · milestone
  #1437 (M70) · split card **#1504** (M70c-K)
- Related: ADR 0007 (syscall ABI — unchanged), ADR 0013 D3.1 (kernel .bss
  budget), ADR 0026 (Go runtime port — D6, the loader's accepted shape),
  ADR 0030 (Go is EL0), `docs/line-of-sight.md` (the Z0.5–Z4 ladder),
  #1434 (M66 — durable multi-MB staging, still open)

> **Superseded in part by Amendment 2 (below):** the kernel capability this
> verdict names landed as #1504, and S1/S2 are now blocked on a Go-side port
> (`syscall`/`os` for `GOOS=virelai`, card #1525). The measurement below —
> "the verdict does not depend on it" — still stands.
>
> **The verdict, up front: M70c's S1/S2 are blocked on a kernel capability,
> not on the Go side.** The guest stages every program through a fixed 2 MiB
> whole-file buffer, and the host's own `cmd/compile` carries 20.66 MB of code
> and read-only data alone. This ADR is docs-only: no code, no syscall, no
> kernel change, no boot-default move. It records the measurement the card
> asked for first, freezes its decisions, and carries the card split —
> **#1504** (the enabling kernel work) and **S3** (the reachable half).

## Context

M70c (#1455) wants the in-guest system to stop depending on the host
toolchain for the code it runs. S1 makes `GOVIRELAI_STD=1` the normal path and
has "the guest compile and link the pinned hello fixture **with the in-guest
toolchain**"; S2 is the in-guest build loop (a driver invoking `compile` then
`link`, no host `go build` in the loop); S3 is the Zig dialect capstone.

The card's enabling fact is real: `cmd/compile`, `cmd/link` and `cmd/asm` are
ordinary Go programs, and the fork already carries the machinery to produce
`GOOS=virelai` binaries. What had never been measured is whether the **guest**
can run programs that size. The card says so itself — "this is as much a
staging problem as a compiler one … measure the honest transfer and `mmap`
story first and record it". This is that measurement.

## Measurement (observed)

Each row is read off the current tree or measured on this machine; the
re-measure commands are at the end.

| bound | value | where |
| --- | --- | --- |
| exec staging | **2 MiB fixed whole-file buffer**, and there are **two** of them — `program` and `interp_program` (the PT_INTERP/LD.SO path), **4 MiB of .bss** — plus the 16 KiB header window the streamed path adds; the *staged* shapes (DSK1/DSK3/contiguous ELF/PT_INTERP) are still bounded by that buffer. Since K1 the gap-layout ELF path **streams** and is bounded instead by `exec_image_max` = 32 MiB (see the amendment) | `kernel/src/exec.zig` (`exec_program_max`, `exec_image_max`, `header_window`), `parse_dsk3` `image_size > buf.len` |
| ELF load bound | **32 MiB total PT_LOAD memory** (K1 raised it from 2 MiB; it no longer mirrors the staging buffer — the streamed path is not a buffer), ≤3 PT_LOADs | `kernel/src/elf.zig` (`load_max`, `max_segments`) |
| GOOS=virelai link recipe | text base 0x10000 with its end ≤0x80000 (**448 KiB** of text), rodata base 0x80000 with its end ≤0x110000, data base 0x110000 | `tools/go/build-go.sh`'s layout guard (the guard exists because a shifted layout "loads but misbehaves on target") |
| gap vaddr bound | every gap segment's vaddr below `gap_base_max` = 0x1000_0000 | `kernel/src/elf.zig:158` |
| page tables | fixed **512×4 KiB (2 MiB) .bss carve-out, never reclaimed** — a *total-roots* budget | `kernel/src/mmu.zig:66-71`; `tables_used()`/`tables_capacity()` at `:146` |
| kernel .bss budget | 11,534,336 B (11.0 MiB) | ADR 0013 D3.1, `tools/verify-bss-budget.sh` |
| guest RAM | **256 MiB** | `host/vm-runner/Sources/VMRunner/main.swift:1347` |
| host `cmd/compile` | **27,061,906 B**, of which `__TEXT` (code+rodata) **20,660,224 B**; `strip -x` → 25,233,584 B (−6.8%) | measured 2026-09-19, Go 1.27.1, darwin/arm64 |
| host `cmd/link` | 6,878,850 B — `__TEXT` 5,423,104 B; `strip -x` → 6,503,808 B | same |
| host `cmd/asm` | 5,341,682 B | same |
| largest in-guest Go program today | `GOBIG.ELF` at **9,502,880 B** (the K1 fixture — 8,416,224 B of it one initialized `.data` payload); before K1 the largest was `GOSH.ELF` at 1,376,416 B, 66% of the old file bound | `.build/go/` |
| file-channel transfer | 32 KiB reply cap, **stateless offset-carrying READ**, paths ≤255 B | `docs/host-file-channel-scoping.md` |

### What is observed and what is inferred

- **Observed:** every bound in the table, and the host tool binaries' sizes.
- **Inferred (labelled, not asserted):** the exact size of a `GOOS=virelai`
  `cmd/compile`. A cross-std build (`GOVIRELAI_STD=1` — the fork at
  `../go-virelai` has no `pkg/virelai_arm64` yet) would produce it. **The
  verdict does not depend on it:** a GOOS swap exchanges the runtime/OS layer,
  which is a small fraction of `cmd/compile`; the *floor* is already
  `__TEXT` minus the darwin-only code, i.e. ~20 MB, against a 2 MiB bound.
  Nobody should read "we have not built it" as "it might fit".
- **Unmeasured (named, not guessed):** in-guest transfer throughput, and
  `compile`+`link` peak RSS in-guest. Both are acceptance criteria on #1504,
  not assumptions here.

## Verdict

**S1 and S2 are blocked. The precise blocked step:** the guest cannot `exec`
a program larger than `exec_program_max` (2 MiB), the loader stages the whole
file through a static array of exactly that size (two of them, in fact —
`program` plus the interpreter's `interp_program`, so 4 MiB of .bss is spent
on staging before any image is read), and `cmd/compile` is more than an order
of magnitude larger than the bound *before* stripping. Running
the toolchain in-guest therefore needs a capability that does not exist today:
**a streamed, per-process-aperture exec path** that does not copy the whole
image through fixed storage, plus page tables that are not drawn from a fixed
2 MiB carve-out. That is kernel work, and it is filed as **#1504 (M70c-K)**.

Two facts that keep this from being a dead end:

- **Staging is not the hard part.** The file channel already reads
  statelessly at an explicit offset with 32 KiB replies, so a 27 MB payload is
  ~845 reads and never has to exist in guest RAM as one buffer — *if* the
  loader streams. It is the exec seam, not the transfer, that forbids it.
- **The output half already fits.** A stripped in-guest-built hello is in the
  same size class as the existing fixtures (GOHELLO.ELF is 1.06 MiB of file /
  1.21 MiB of PT_LOAD memory), so once a large *toolchain* can run, the
  binary it produces is buildable today. The blocker is one-directional.

**S3 is not blocked.** `user/src/zc.zig` (3,910 lines) already compiles the
in-guest Zig dialect and `live-zc` runs its output on-machine — that is the
self-hosting capability that exists, and the Z4b step is described in
`docs/line-of-sight.md` as "explicitly a negotiation, not assumed", to be read
before promising anything.

## Decisions

**D1. No new compiler.** Unchanged from the card: this arc cross-compiles
upstream `cmd/*` for `GOOS=virelai`; writing a Go compiler is not on the
table.

**D2. Offline inputs only.** Unchanged: no `GOPROXY`, no module fetch, no
`net/http`; vendored or pinned inputs from the host share.

**D3. The guest stays the guest.** Unchanged: the in-guest build produces
`GOOS=virelai` guest programs, never host binaries.

**D4. Staging remains a host dependency, and so does the payload's size.**
The card already required stating which part stays host-provided; this ADR
extends it: *today the host also decides whether the toolchain can run at
all*, because the guest's exec seam cannot hold it. Nobody may read S1 as
"self-hosted" while that is true.

**D5. The enabling work is a kernel card, not a tools change (#1504).** No
build flag, linker recipe, `-ldflags`, or "smaller compile" trick closes a
10× gap in code size. The load path gains a streamed, non-fixed-aperture form
whose bounds are visible and whose refusals are named.

**D6. The bar for S1 stays behavioral.** "The in-guest-built binary runs and
prints the pinned line" — byte-equality with the host-built binary is not the
bar (build IDs and paths differ), exactly as the card already said. Add to
that: **a peak-RSS figure in-guest**, because "it builds" in a 256 MiB guest
is otherwise unfalsifiable.

**D7. Page-gate hygiene.** #1504 changes the exact-count page and page-table
gates' inputs. Those gates get **re-derived and amended with their own
measurement** — never loosened so that a large image can pass.

## Card split

| piece | card | acceptance | state |
| --- | --- | --- | --- |
| streamed exec + per-process text aperture + the RAM floor | **#1504** (M70c-K) | a >8 MiB stripped Go ELF execs in-guest and prints its pinned marker; oversized and truncated images still refuse by name; .bss gate green (or ADR 0013 amended with the observed number) | **filed, unclaimed — the blocker** |
| S1/S2 (toolchain in-guest, in-guest build loop) | #1455 | behavioral: the in-guest-built binary runs; peak RSS recorded | **blocked on #1504 and #1434** |
| S3 (Zig dialect capstone) | #1455, riding `live-zc` | whatever the Z4 ladder notes support, landed as its own shard or recorded precisely | **reachable now** |
| multi-MB durable staging | #1434 (M66) | already its own card | **open — dependency of #1504** |

## Non-goals

No dynamic linking beyond what #1504's mapping work needs; no new syscall
without an ADR 0007 amendment; no .bss budget change without amending ADR
0013 D3.1 with the observed post-change measurement; no change to the
GOOS=virelai code shape or the boot default; no in-guest `go test`, no module
resolution, no self-hosting the kernel, no replacing `zc`, no `cgo`; and no
attempt at S1/S2 code until #1504 lands.

## Amendment — K1 (M70c-K, #1504)

This amendment is part of the change that lands K1; it records what changes
and what is still open. The decision text above is history and stays as
written (its card-split table is the pre-landing state: since then S3 landed
as PR #1511 and #1504 was claimed). K2 — the aperture bound — is the same
change: `elf.load_max` moved with the loader. K3 is not; see below.

**What the loader does now.** The gap-layout static ELF path — every
`GOOS=virelai` Go binary — no longer stages the file. The loader reads a
16 KiB header window, parses the plan from it (`elf.parse_head` validates
segment *payload* ranges against the file's STAT size instead of a buffer),
then streams each segment straight from the host share into the physical
pages that will be mapped. Every other shape (DSK1, DSK3, the contiguous ELF
layout, PT_INTERP) keeps the staged path exactly — same one-read behaviour,
same `exec_program_max` bound. One pre-existing hole closed on the way: a
*contiguous* three-segment image used to reach the staging copy that only
represents `[text][data]`, i.e. it loaded with its rodata and data silently
missing; it is now refused.

**The refusals name the bound, not "too large".** One old name,
`ExecResult.too_large`, covered three different truths — and the monitor
printed one buffer bound for all of them, so a reader could not tell which
limit an image had crossed. It is now three:

| result | means | monitor line |
| --- | --- | --- |
| `image_too_large` | the FILE is past `exec_image_max` (32 MiB), whatever its shape | `error: <name>: image too large (acceptance bound 0x0000000002000000 bytes)` |
| `staging_too_large` | the shape must transit the 2 MiB staging buffer (DSK1, DSK3, contiguous ELF, PT_INTERP) and does not fit | `error: <name>: image too large for the 0x0000000000200000-byte staging buffer (only a gap-layout static ELF streams past it)` |
| `image_truncated` | the file ends before the bytes its own header promises | `error: <name>: truncated image (file ends before the bytes its header promises)` |

The truncation condition has **two detections and one name**, deliberately:
the header-window parse refuses a segment whose payload range escapes the
volume's STAT size (`elf.file_too_short`), and — if the file changes between
that parse and the load — the streamed segment read hits EOF. Which check
noticed is not the caller's problem; the DSK3 path reports it the same way
(a declared image that never arrived is `image_truncated`). No path ever
maps a half-filled segment.

**Observed acceptance (VZ, class B).** `go-hello` run 02 execs
`GOBIG.ELF` — a real stripped `GOOS=virelai` Go image of 9,502,880 B whose
last segment carries 8,416,224 B of initialized data — and the program
prints a banner it reads back at runtime from 1, 4 and 8 MiB into that
payload (`A B C E D`, `big: sum 335`), with the kernel reporting
`datapages=2097`. Run 01 (the 1.19 MiB `GOHELLO.ELF`, staged) is unchanged
and still green. Run 03 execs two real fixtures made from that image —
`XL.ELF` (34 MiB, past the acceptance bound) and `TRUNC.ELF` (its first
4 MiB, laid out so its data segment is cut off) — and asserts each refusal
by its own message, in order, with neither reporting a successful load.

**Both new run shapes were shown able to fail.** Aiming the streamed read
4096 bytes past each segment's own file offset (a one-line mutation): run
02 **FAILs** on `big: banner A B C E D` (and the load marker stays green —
the banner is what catches a read that succeeds against the wrong bytes),
while run 01 and run 03 stay green. Replacing the acceptance bound with the
staging bound in the size refusal (a one-line mutation): run 03 **FAILs**
by name, `XL.ELF: image too large (acceptance bound` = 0 and
`serial-absent 'staging buffer'` = 0, while run 01/02 stay green. Both
reverted; the gate then reports 3/3 again. Host tests cover the same path
with the channel's real 32 KiB reply bound pinned (`read_chunk`'s test
override now clamps like the wire does).

**K3 is not satisfiable yet, and not because of this card.** It measures
`compile`+`link` peak RSS *in-guest*, which needs the toolchain to run
in-guest — i.e. S1/S2 themselves. The host-side figures in the table remain
the best available upper bound, and the RSS figure stays an acceptance
criterion on #1455's S1/S2, not on #1504.

**D7 (page-gate hygiene).** K1 does not change how many pages any existing
shape takes: the streamed path maps exactly the declared segments, the
staged path is untouched, and the acceptance run reports the fixture's own
page counts (`datapages=2097`; the host test pins the exact delta,
1 + 768 + 2 + 1 + 48 + 48). The loader/exec regression set is green *on this
change*: `live-elf`, `live-exec`, `live-el0-exec`, `live-m16-image`,
`live-scale`, `live-oliver` (7/7) and `go-hello` (3/3).

Five further gates D7 names are **red on the base commit already**, for
reasons this change does not touch. Each was re-run at `81ebaa9d` with the
work stashed (`dirty-files=0`) and then on this change; each fails
identically both times, which is the evidence — the short cause notes below
are context, not a diagnosis this card owes:

| gate | observed failure (same at base and on this change) | note |
| --- | --- | --- |
| `live-long-lived` | `FAIL: running rows absent` | its `procs: id=… state=running` regex predates the `uid=`/`caps=` columns |
| `live-m16-resources` | `expected 8 running COUNTER rows, got 0` | same regex, same columns |
| `live-kill` | `page recovery off first=61844 second=61941` | a pinned `+17`-page recovery that predates the 192 KiB task stack (observed `97` = 1 text + 48 stack + 48 kernel stack) |
| `live-m16-guards` | `procs GUARD.BIN exited status=1` where the spec wants `139` | `GUARD.BIN`'s 36 KiB step predates the same stack growth, so it exits through its own closed-guard-gap branch instead of faulting |
| `live-m16-composition` | `missing GLOBALS.BIN exited status 42`, `serial-count [exec: loaded USER.BIN size=]=0 (min 7)` | its scripted composition stops before its later phases |

None of the five is re-derived or loosened here, and none may be: a large
image is not going to be made to pass by relaxing a page or row gate. They
are answered as one card instead — **#1522** (re-derive or retire, with the
measurement in its own PR).

**`.bss` gate:** green, `12,020,408 B / 13,631,488 B` (1,611,080 B
headroom) with the 16 KiB header window in place; the two 2 MiB staging
arrays stay, because the staged shapes still need them. ADR 0013 D3.1 is
unchanged.

## Amendment 2 — M70c (#1455): the exec blocker is retired, the port layer is the blocker

#1504 landed (PR #1523, merge `1e757d15`): the gap-layout path streams, its
acceptance bound is 32 MiB, and a 9.5 MiB `GOOS=virelai` image execs on VZ. The
"precise blocked step" named in the verdict above — *the guest cannot `exec` a
program larger than `exec_program_max`* — is **closed**. This amendment records
the two things the card's S1/S2 still wait on: the step that blocks them now,
and the transfer measurement the card asked for first and never got.

### The new blocked step: there is no `syscall`/`os` port for `GOOS=virelai`

Observed on the fork (Go 1.27.1, `GOROOT=../go-virelai`):

```
$ GOOS=virelai GOARCH=arm64 go build -o /dev/null fmt
# syscall
../go-virelai/src/syscall/syscall.go:50:15: undefined: EINVAL
../go-virelai/src/syscall/syscall.go:80:11: undefined: Timespec
../go-virelai/src/syscall/syscall.go:85:11: undefined: Timeval
# internal/poll
../go-virelai/src/internal/poll/fd_mutex.go:212:11: undefined: FD
```

`fmt` is the smallest interesting target; `os`, `path/filepath`, `go/ast` and
every `cmd/*` package sit behind the same two. The fork's virelai-tagged files
are **runtime only** — `runtime/{os,signal,netpoll}_virelai.go`,
`runtime/{sys,rt0}_virelai_arm64.s`, `internal/goos/zgoos_virelai.go`, plus the
`mem_sbrk`/`lock_sema`/`stubs*` tag lists — and `src/syscall`/`src/os` carry
nothing for this GOOS. Three consequences, and the first two are sharper than
the original verdict:

- **`GOVIRELAI_STD=1` cannot build.** S1's "cross-std on by default" half is
  not a flag flip: a full `GOOS=virelai make.bash` starts by compiling
  `syscall` for a GOOS with no `syscall` type/const surface. The re-measure
  command in the section below (`GOVIRELAI_STD=1 bash tools/go/build-go.sh`)
  fails one package in.
- **No toolchain binary for `GOOS=virelai` can be produced today at all** —
  not "it builds but cannot run", which is what the original verdict
  described. So the `cmd/compile`-size row above stays an **inference** (a
  GOOS swap exchanges the runtime/OS layer, a small fraction of the binary),
  and the size gate S1 needs cannot be closed by building it.
- **The fix is a port, not a knob.** `build-go.sh` already names its shape
  ("the syscall/os port layer (the wasip1 mirror)"):
  `syscall/syscall_wasip1.go`, `fs_wasip1.go`, `net_wasip1.go`,
  `internal/poll/fd_wasip1.go` and the `os` glue — hand-written file-ABI
  plumbing, which here means ADR 0010's file surface over the ADR 0007 slots
  the kernel already serves. Filed as its own card, **#1525** (M70c-S1P);
  S1/S2 wait on it.

**D4 stands, for a new reason.** The toolchain payload stays host-produced.
The old reason (the guest's exec seam cannot hold it) is retired; the current
one is that the guest cannot yet compile the toolchain's own source for itself.

### Amendment 3 — M70c-S1P (#1525): the ported `syscall`/`os` build, and the link windows become the next wall

Observed on the fork, same toolchain, after the port landed
(`tools/go/overlay/{syscall,internal/syscall/unix,internal/poll,time,os}`):

```
$ GOOS=virelai GOARCH=arm64 go build fmt      # exit 0 — no output
$ GOOS=virelai GOARCH=arm64 go build os       # exit 0
```

That is the S1/S2 prerequisite the section above names, so `fmt` — and with it
`os`, `path/filepath`, `go/ast` — now **compiles** for this GOOS. What the
guest runs is a different claim, and the card's fixture (`tools/go/gosyscall.go`)
settles it the hard way: it **builds, links, loads and starts** —
`exec: loaded GOSYSCALL.ELF size=0x98194 … datapages=51` — and then dies in
`runtime.mallocinit`:

```
fatal error: runtime: cannot allocate memory
runtime.throw({0xb4404?, 0x0?})
	runtime/panic.go:1243
runtime.persistentalloc1(0x100, 0x0?, 0x1b01c0)
	runtime/malloc.go:2363
… runtime.mheap.init → runtime.mallocinit → runtime.rt0_go
```

Why, and this is the finding that outlives the card: **any image that imports
`os` no longer fits the link recipe's windows.** Measured
(`tools/go/build-go.sh`'s guard, `tools/go/gosyscall.go` with `os` only, no
`fmt`):

```
text ends 0x92fc4 > 0x80000; rodata base 0xa0000 != 0x80000;
rodata ends 0x149558 > 0x110000; data base 0x150000 != 0x110000
```

448 KiB of text was a runtime-only budget. The Go linker then shifts the later
segments, the kernel faithfully maps them at their declared vaddrs (#1504's
gap streaming) — and the runtime's sbrk heap starts at
`memRound(firstmoduledata.end)`, which for the shifted layout is page-rounded
into the **loaded data aperture**, so the kernel's `mmap_collides` check
(system 1214's rule: a mapping may never alias a region the process owns)
refuses the process's first heap mapping. The unshifted images did not hit this
by geometry, not by design: their data aperture ends exactly where the linked
`end` rounds to.

Consequences, stated as constraints rather than guesses:

- **The recipe's apertures, not the port, are now the gate**, filed as **#1540**
  (M70c-S1L). Widening them (explicit link bases) or making the break's base
  page-safe relative to the loader's aperture end is that card's work. Until it
  lands, no in-guest fixture that imports `os` can pass, which is why
  `go-hello` had no std-fixture run at this point — **amendment 4 has both the
  resolution and the correction to the diagnosis below**.
- **`cmd/compile` is ~40x past the text window** (448 KiB here vs 27 MB of
  host `cmd/compile`), so this wall has to come down for S1/S2 regardless of
  which std packages they link.
- **Link-time gaps are invisible to `go build`.** The port's first link failure
  was `os.(*File).Write: relocation target os.sigpipe not defined` — the
  virelai runtime's `os_sigpipe` had never carried its `//go:linkname`, and no
  earlier fixture used `os`, so nothing had ever referenced the symbol. Fixed
  in the same card; the general lesson is that "`go build fmt` succeeds" is a
  **compile-time** claim and must not be read as "a guest program using `fmt`
  runs".

### The transfer half, measured

The card's other half — "measure the honest transfer and `mmap` story" — now
has both numbers. The `mmap` half is K1's (`datapages=2097` for an 8.4 MiB
payload, run 02). The transfer half is `go-hello` **run 04**: `GOREAD.ELF`
reads a 9.5 MiB `GOOS=virelai` image back out of the host share end to end with
nothing staged in between, and the host recomputes both the byte count and the
FNV-1a hash of the bytes the guest actually read.

| transfer, observed on VZ (2 vCPU, 256 MiB) | value |
| --- | --- |
| EL0 read cap | **2048 B per `sys_file_read`** (`kernel/src/syscall.zig`: `@min(count, 2048)`), against a **32 KiB** wire reply cap (`virtio_file.reply_cap`) — so a payload is served in ~15× more calls than the wire would allow |
| payload read | **9,502,880 B in 4,641 calls**, largest single call **2048** — exactly `ceil(bytes/2048)`, i.e. every call moved a full chunk (run 2: identical) |
| elapsed | **298,379 µs** (run 2: **311,010 µs**) |
| goodput | **31,101 KiB/s** (run 2: 29,838) ≈ **30 MB/s**, **~15,300 calls/s** |
| per call | **64,292 ns** (run 2: 67,013) — one virtio round trip; the guest-side fold is under 4 % of it |
| hash | FNV-1a 64 of the bytes READ = the same file hashed on macOS (`0x7085f0327a474278`) |

**What it means for S1/S2 — arithmetic, labelled as extrapolation:** a
27,061,906 B `cmd/compile` is ~13,200 calls at this cap ≈ **0.85 s** of channel
time (`27,061,906 × 298,379 / 9,502,880` µs; this measures the rate, not that
file). Writes are capped identically (2048 B per `sys_file_write`), so a few MB
of object output is ~0.2 s. **Transfer is not the blocker.** At the ABI's own
cap a toolchain-scale payload costs well under a second per pass, and the
whole-file-buffer shape the old verdict worried about is not needed to read one
— bounded memory and the existing offset-carrying READ are enough.

A widened cap would show up as a changed call count in run 04, which is
asserted: the run's exact line (`bytes <n> calls <ceil(n/2048)> max 2048`) is a
deliberate tripwire, because these numbers are what S1's cost estimate rests
on. Both halves of that assert were shown able to fail before landing — a
fixture that counts a chunk without folding it fails the hash half with the
byte/call line still exact; one that stops 1 MiB short fails the byte/call
half — with runs 01–03 green in both cases.

## Amendment 4 — M70c-S1L (#1540): the std fixture RUNS, and the wall was neither the port nor the linker

Observed on VZ, `go-hello` **run 05** (class B, `tools/go/gosyscall.go`):

```
exec: loaded GOSYSCALL.ELF size=0x98644 entry=0x807e0 datapages=51
gosyscall: os mkdir ok
gosyscall: os write PAYLOAD.TXT bytes 32
gosyscall: os write SECOND.TXT bytes 24
gosyscall: os readback PAYLOAD.TXT ok bytes 32
gosyscall: read 2048
gosyscall: second read 1 byte 0
gosyscall: stat size 9502880 isdir false
gosyscall: fstat size 9502880
gosyscall: raw dirent bytes 80
gosyscall: absent no such file or directory
gosyscall: os bytes 9502880 hash 0x7eb82998
gosyscall: os stat size 9502880 isdir false
gosyscall: os stat PAYLOAD.TXT size 32 isdir false
gosyscall: os dir entries 2 files 2 dirs 0
gosyscall: os remove ok 2
gosyscall: os dir entries 0 files 0 dirs 0
gosyscall: GOSYSCALL OK
```

`0x7eb82998` is the host's own FNV-1a 32 of the staged 9.5 MiB image,
recomputed off the share (the 64-bit sum in run 04 is a different fold of the
same file). The host also checks from its side that the guest's `os.Mkdir`
landed in the share and that the two `os.Remove` calls really took the files
away. So "the standard library drives this kernel" is now observed bytes, not a
compile exit code. Negative controls, each run before landing: with the runtime
floor below removed the run dies in `mallocinit` with `cannot allocate memory`
(runs 01–04 still pass); with one byte dropped from the guest's fold the host's
hash assert fails while every other line still matches.

### What the wall actually was (amendment 3 was one step off)

Amendment 3 read the `mallocinit` death as "the shifted layout puts the sbrk base
inside the loaded data aperture". The aperture half is right; **the segment shift
is a coincidence, not the cause.** The two rules that collide are:

- the kernel reserves the writable segment's extra tail page for the packed
  argv+envp block and protects the data aperture *through that block*: the
  collision span is `max(pageRound(mem_size), align8(mem_size) + 2304)`
  (`process.zig mmap_collides`; `exec.zig` packs 8×32 + 16×128 = 2304 B there);
- the runtime starts its heap at `memRound(firstmoduledata.end)`, i.e. at
  `round_up(mem_size)` — which is INSIDE that span whenever the block reaches
  past the page-rounded image end: `mem_size mod 4096 > 4096 − 2304 = 1792`.

Runs 01–04 pass because their data segments leave `r = 688` and `r = 1072` of
slack; the std fixture has `r = 3280`. Measured across every `GOOS=virelai`
image built in this worktree, GOSYSCALL is the **only** one on the wrong side of
that boundary — every other has `r ≤ 1520`.

None of this was unknown: `user/go/sh/main.go` and `user/go/sshd/main.go` each
carry an `argvEnvpGuard` padding array for exactly this refusal ("adjust this
array's size when it trips"), and `tools/go/build-gosh.sh` asserts the same
boundary from the linked ELF (`slack ≥ 0x908`). So the mechanism was understood
and worked around **per program, by hand**. What #1540 changes is who owns the
rule: the runtime, once, instead of every new std program having to discover the
boundary and pad its bss to sit on the right side of it. The pads and that
assert stay — harmless, and they name the invariant if it ever regresses — but
they are no longer what keeps a Go program alive. That is the difference between
a 1792/4096 coin flip and a rule.

### The fix, on the runtime side

`initBlocFloor` (`overlay/runtime/os_virelai.go`) starts the break on the page
after the block the kernel packed, using the block VA the rt0 stub records
before it converts that block to rt0_go's SysV array. Raising the floor only
ever skips the block's own page — the only thing living there — so an image
whose slack already clears the block is byte-for-byte unchanged, which is why
runs 01–04 stayed green.

**Widening the recipe was not needed**, and that is a finding: the loader maps
each segment at its declared vaddr (#1504), so a shifted image is legal — only
the break base was unguarded. Explicit link bases remain useful for the S1/S2
40× text gap (`cmd/compile` vs the 448 KiB window) and are that card's business,
not this one's.

### Two port bugs the fixture caught that no earlier gate could

Amendment 3's own warning — "`go build fmt` is a compile-time claim" — came true
twice, and both bugs were in the **port**, not the kernel:

1. **The POSIX→kernel open-flag translation was wrong.** `kernelOpenFlags`
   passed the POSIX word through: a read-only open sends `O_RDONLY = 0`, which
   `file_table.open` refuses (`flags == 0`, and `MODE_READ` is `0x1`), while
   `O_CREAT = 0x40` is not a MODE bit at all. The port now keeps a separate
   MODE_* word (`kmodeRead`/`kmodeWrite`/`kmodeCreate`/`kmodeAppend`/`kmodeDir`)
   and translates; it failed closed with EINVAL, which is why it was visible
   immediately.
2. **`O_TRUNC` was implemented by calling the port's by-path `Truncate`, which
   is an honest `ENOSYS`** (slot 36 is handle-addressed) — so every
   `os.WriteFile` failed with ENOSYS. The kernel's write-open already truncates
   (replace semantics), so the call was both broken and unnecessary; removed,
   with the reason at the site.

Both survived #1525's review as "the thing to press on" and both are precisely
what the missing in-guest run would have caught — the case for run 05 existing.

### A found limit, named rather than papered over

`Stat` has no slot: the port answers from a row on the entry's PARENT. That
listing has **no cursor and the kernel clamps one call to 16 rows**, and this
gate's share (the seeded app bundle) holds ~30 entries — so
`os.Stat("/host/GOBIG.ELF")` returned ENOENT for a file that was right there.
The port now falls back to what the ABI can still say: listing the path itself
proves a directory, otherwise it opens the file and reads to EOF to learn its
size. Correct, and **O(size)** — stated in the port and here rather than hidden
(a `stat` verb, or a listing cursor, is a kernel-surface card, not this one).

### Still unmeasured, and why

**`compile`+`link` peak RSS in-guest** — unchanged from K3, and unmeasurable for
the same reason: it needs the toolchain to run in-guest, which needs S1/S2 to be
possible at all. It remains an acceptance criterion on #1455; the host-side
figures in the table above are still the best available upper bound. **Transfer
throughput is no longer unmeasured**, and the std layer is now *executed*, not
merely compiled.

### Card split, as it now stands

| piece | card | state |
| --- | --- | --- |
| streamed exec + per-process text aperture + the RAM floor | #1504 (M70c-K) | **landed** (PR #1523, `1e757d15`) |
| the `GOOS=virelai` `syscall`/`os` port | **#1525** (M70c-S1P) | **landed** (PR #1541) |
| the std fixture runs (`go-hello` run 05) | **#1540** (M70c-S1L) | **landed** (this amendment) |
| S1/S2 (toolchain in-guest, in-guest build loop) | #1455 | unblocked in principle: the std layer builds AND executes; the 40× text gap is the remaining structural work |
| S3 (Zig dialect capstone) | #1455, riding `live-zc` | **landed** (PR #1511) |
| multi-MB durable staging | #1434 (M66) | cards landed; index issue open |

## Re-measuring (so the next agent does not have to take this on faith)

```bash
# the guest walls
sed -n '95,110p;180,190p' kernel/src/exec.zig          # exec_program_max, the buffer
sed -n '155,170p' kernel/src/elf.zig                   # load_max, max_segments, gap_base_max
sed -n '64,72p;144,155p' kernel/src/mmu.zig            # the fixed table carve-out
bash tools/verify-bss-budget.sh                        # 11,534,336 B, observed value in the log
grep -n memorySize host/vm-runner/Sources/VMRunner/main.swift
grep -n -A4 'FIXED text aperture' tools/go/build-go.sh  # the 448 KiB recipe window

# the payload (host; Go 1.27.1)
size -m "$(go env GOROOT)/pkg/tool/$(go env GOOS)_$(go env GOARCH)/compile"
cp "$(go env GOROOT)/pkg/tool/darwin_arm64/compile" /tmp/c && strip -x /tmp/c && ls -l /tmp/c

# the exact GOOS=virelai figures (opt-in cross-std pass). Since #1525 the port
# exists and std closes except `net`/`net/internal/socktest` (no socket slots)
# and `internal/testenv` (test support wants a per-GOOS Sigquit) — run
# `GOOS=virelai go build std` to see the current list rather than trusting this
# comment.
GOVIRELAI_STD=1 bash tools/go/build-go.sh
cd "${GO_FORK_DIR:-../go-virelai}/src" && GOOS=virelai GOARCH=arm64 go build \
    -ldflags "-s -w" -o /tmp/compile-virelai cmd/compile && ls -l /tmp/compile-virelai

# the port layer, one package in (amendment 3+
# `apply.sh` installs it; both of these are rc=0 since #1525)
export GOROOT="${GO_FORK_DIR:-../go-virelai}"; export PATH="$GOROOT/bin:$PATH"
GOOS=virelai GOARCH=arm64 GOTOOLCHAIN=local go build -o /dev/null fmt
GOOS=virelai GOARCH=arm64 GOTOOLCHAIN=local go build -o /dev/null os

# the aperture arithmetic amendment 4 is about, per built image: the data
# segment's page slack (r <= 1792 clears the kernel's argv+envp block, and the
# runtime walks past it either way since #1540)
python3 - .build/go/GOSYSCALL.ELF <<'EOF'
import struct, sys
d = open(sys.argv[1], "rb").read()
phoff, phes, phnum = struct.unpack_from("<Q", d, 32)[0], struct.unpack_from("<H", d, 54)[0], struct.unpack_from("<H", d, 56)[0]
segs = [struct.unpack_from("<IIQQQQQQ", d, phoff + i * phes)[4:7] for i in range(phnum)]
last = [s for s in segs if struct.unpack_from("<I", d, phoff + segs.index(s) * phes)[0] == 1][-1]
print("data va=%#x mem_size=%#x slack=%d" % (last[0], last[1], last[1] % 4096))
EOF

# the transfer numbers (class B; run 04 of go-hello asserts the byte count,
# the call arithmetic and the hash, and prints the rate) and the std layer's
# run (run 05: the host recomputes the 32-bit hash and checks the share)
just gate go-hello
grep -a 'goread:' artifacts/go-hello-serial-04.log
grep -a 'gosyscall:' artifacts/go-hello-serial-05.log
```
