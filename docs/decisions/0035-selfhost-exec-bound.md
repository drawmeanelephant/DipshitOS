# ADR 0035: self-hosting M70c — what the guest can actually exec

- Status: ACCEPTED
- Date: 2026-09-19
- Issue: #1455 (M70c — this measurement is its first deliverable) · milestone
  #1437 (M70) · split card **#1504** (M70c-K)
- Related: ADR 0007 (syscall ABI — unchanged), ADR 0013 D3.1 (kernel .bss
  budget), ADR 0026 (Go runtime port — D6, the loader's accepted shape),
  ADR 0030 (Go is EL0), `docs/line-of-sight.md` (the Z0.5–Z4 ladder),
  #1434 (M66 — durable multi-MB staging, still open)

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
| exec staging | **2 MiB fixed whole-file buffer**; a larger image is refused `too_large` | `kernel/src/exec.zig:100` (`exec_program_max`), `:184` (`var program: [exec_program_max]u8`), `parse_dsk3` `image_size > buf.len` |
| ELF load bound | 2 MiB **total PT_LOAD memory**, ≤3 PT_LOADs | `kernel/src/elf.zig:164`,`:167` (`load_max` — "mirrors `exec.exec_program_max`, the shared staging buffer bound") |
| GOOS=virelai link recipe | text 0x10000..0x80000 (**448 KiB**), rodata →0x110000, data at 0x110000 | `tools/go/build-go.sh`'s layout guard (the guard exists because a shifted layout "loads but misbehaves on target") |
| gap vaddr bound | every gap segment's vaddr below `gap_base_max` = 0x1000_0000 | `kernel/src/elf.zig:158` |
| page tables | fixed **512×4 KiB (2 MiB) .bss carve-out, never reclaimed** — a *total-roots* budget | `kernel/src/mmu.zig:66-71`; `tables_used()`/`tables_capacity()` at `:146` |
| kernel .bss budget | 11,534,336 B (11.0 MiB) | ADR 0013 D3.1, `tools/verify-bss-budget.sh` |
| guest RAM | **256 MiB** | `host/vm-runner/Sources/VMRunner/main.swift:1347` |
| host `cmd/compile` | **27,061,906 B**, of which `__TEXT` (code+rodata) **20,660,224 B**; `strip -x` → 25,233,584 B (−6.8%) | measured 2026-09-19, Go 1.27.1, darwin/arm64 |
| host `cmd/link` | 6,878,850 B — `__TEXT` 5,423,104 B; `strip -x` → 6,503,808 B | same |
| host `cmd/asm` | 5,341,682 B | same |
| largest in-guest Go program today | `GOSH.ELF` at 1,376,416 B — a real shell, and it already uses 66% of the file bound | `.build/go/GOSH.ELF` |
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
file through a static array of exactly that size, and `cmd/compile` is more
than an order of magnitude larger than the bound *before* stripping. Running
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

# the exact GOOS=virelai figures (opt-in cross-std pass; the fork has no
# virelai std yet, so this is the step that turns the inference into an
# observation)
GOVIRELAI_STD=1 bash tools/go/build-go.sh
cd "${GO_FORK_DIR:-../go-virelai}/src" && GOOS=virelai GOARCH=arm64 go build \
    -ldflags "-s -w" -o /tmp/compile-virelai cmd/compile && ls -l /tmp/compile-virelai
```
