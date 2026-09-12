# ADR 0026: The GOOS=virelai Go runtime port

- Status: ACCEPTED (phase 0a)
- Date: 2026-09-12
- Issue: #1163
- Related: ADR 0007 (syscall ABI), ADR 0005 (runtime-built tables),
  ADR 0013 D3.1 (.bss budget), M40 GF6 (gate rules)

## Context

VirelaiOS userland is Zig-only. The project wants first-class Go support —
natively compiled, statically linked gc-toolchain Go programs running at
EL0 — without a POSIX/libc layer and without Linux-ABI emulation.

Research (2026-09-11, three-track audit: Go 1.27.1 source, the kernel seam,
upstream policy) established:

- Upstream Go has no third-party-GOOS mechanism. `GOOS=none` was declined
  (golang/go#35956); the `GOOSPKG` overlay proposal (golang/go#73608) is
  active but unaccepted. Every non-POSIX port (Fuchsia, TamaGo, IBM z/OS)
  is a maintained fork. wasip1 (in-tree) proves a GOOS with ~7 host entry
  points, no signals and no threads passes the runtime.
- On arm64, `haveSysmon` starts a second M unconditionally
  (`GOARCH != "wasm"`), so a single-thread target needs one fork delta
  (`proc.go`) until a thread-create syscall exists.
- Pure-Go arm64 keeps `g` in R28 (no TLS programming at EL0), and the
  guest counter (CNTPCT_EL0) is already EL0-readable via CNTKCTL_EL1, so
  Go's monotonic clock is a register read.
- The kernel's `sys_mmap` honors page-aligned address hints, which makes
  Go's sbrk memory platform (`mem_sbrk.go`, build-tagged for virelai) map
  the heap contiguously with zero kernel-side heap changes.

## Decision

D1 — **A fork of the gc toolchain with `GOOS=virelai`, never a
Linux-syscall skin and never TinyGo.** The Linux skin imports Linux ABI
semantics (sigaction/ucontext synthesis, clone flags, Linux errno) the
kernel explicitly rejects; TinyGo is not the gc runtime (no `plugin`,
broken `os/signal`/`os/exec`, conservative GC, in-tree hook files). The
fork's maintenance surface is bounded: 6 source edits + 5 GOOS-gated files
(`tools/go/overlay/`, applied by `tools/go/apply.sh` to a copy of a stock
distribution outside the repo). Watch golang/go#73608 for an overlay
future.

D2 — **The runtime speaks ADR 0007 directly.** `svc #0`, number in x8,
args x0-x5, result in x0 (the kernel's own errno encoding). The syscall
package is authored fresh (as any non-Unix GOOS does); no errno
translation layer exists.

D3 — **Memory is the runtime's sbrk platform** (`mem_sbrk.go` build-tagged
for virelai) over `sys_mmap` with contiguity via address hints — Linux-brk
semantics, demand-backed. No sysReserve/mprotect/PROT_NONE machinery is
required in phase 0a. `physPageSize` is 4096 (set in osinit; the arm64
default 64K is wrong for this kernel).

D4 — **Time is a register read.** `nanotime` = CNTPCT_EL0 scaled by a
per-boot multiplier (`2^44 · 1e9 / CNTFRQ_EL0`, computed in osinit with a
128/64 restoring division); `walltime` = the slot-66 boot epoch plus
monotonic elapsed. No clock syscall on the hot path.

D5 — **Phase 0a is single-threaded and signal-less** (proven by bring-up:
the runtime demands multiple Ms the moment `gcenable` parks the main G on
a channel while bgsweep/bgscavenge sit in its P's runq). Fork deltas, all
behind one `canCreateM` const in `proc.go` plus wasm-pattern no-ops:
`haveSysmon` off, `newosproc`/`newosproc0` throw, the template thread
skipped, `startTheWorld`/`startm` spare-M handoffs dropped, `dolockOSThread`/
`dounlockOSThread` keep the accounting but never bind (a locked main G
would wedge `stoplockedm`), and `stopm` yields to the kernel scheduler
instead of parking (nothing exists to wake a parked M). Locks come from
`lock_sema.go` (self-contained spinning semaphores over a userspace
`waitsemacount`); preemption is cooperative only (known cost: a call-free
tight loop delays STW — shared with wasip1 and Fuchsia). Phase 0b adds
kernel slots 73/74 (`thread_create`, futex — 72 is `sys_getrandom`, #1166) and exec argv, removing every
delta; phase 0c adds fault delivery → `sigtrampgo` (recover(),
tracebacks).

D6 — **The loader accepts the Go linker's shape.** `elf.zig` takes up to
three PT_LOADs ([R+X][R][RW], W^X enforced) and a GAP layout — later
segments at their own page-aligned declared vaddrs — alongside the
original contiguous contract. `exec_program_max` is 1 MiB (Go images
exceed 512 KiB stripped). Programs link with `-T 0x400000 -s -w`.

D7 — **Kernel additions ride existing seams where they exist.**
`sys_getrandom` (the runtime's hash seed) is **ADR 0007 slot 72, landed by
M51 SSH-P1 (#1166, ADR 0025 D5)** — this port consumes it rather than
adding a second entropy slot; the rebase onto #1166 renumbered the
original phase-0a proposal (slot 74) accordingly. Port-specific lifts:
mmap per-call cap 16 MiB → 1 GiB; mmap-region cap 8 → 16; recorded
demand-page cap 128 → 4096 (~16 MiB/process; the Go working set exceeds
512 KiB within milliseconds of `mallocinit`). CPACR_EL1.FPEN is armed at
boot (Go is NEON-heavy; EL0 FP state was previously untested inherited
firmware state).

D8 — **Console writes stage through the image's data segment.**
`sys_write`'s copy_in validates the buffer against the task's uaccess
regions, and Go stacks live in the sbrk heap (an unregistered sys_mmap
region) — printing digits straight from a stack buffer silently EFAULTs.
`write1` memmoves every chunk into a static data-segment staging buffer
first. Phase 2's proper fix is uaccess awareness of registered mmap
regions.

## Bring-up record (2026-09-12)

The clean-room run — stock distribution → `apply.sh` → both toolchain
passes → `GOHELLO.ELF` → `just gate go-hello` — passed end to end with no
manual steps. Debugging used the kernel's strace seam (straced the child's
syscalls: time → getrandom → the contiguous sbrk mmap chain), a temporary
`procs` PC probe, and staged VDBG prints inside `schedinit`/`runtime.main`
(removed). The failure ladder, each fixed in this order: negative
`p_offset` in `-T`-linked images (link at the default base instead),
`load_max` below the real 1.21 MiB of PT_LOAD memory, mmap per-call cap
below Go's 512 MiB sysReserve, fd-2 console writes (EBADF), the
`nanotime1` operand-order bug (silent pre-main spin), and the two
scheduler wedges above.

## Verification

Class-B gate `go-hello` (`tools/gate/specs/go-hello.spec`): boots VZ,
execs `GOHELLO.ELF` (built by `tools/go/build-go.sh` from the fork),
asserts the console path, 1 MiB sbrk growth, a full GC cycle and a clean
exit on serial. The binary is a machine prerequisite built outside the
gate (the fork is not a repo artifact).

## Consequences

- Go programs can run on VirelaiOS; stdlib coverage grows per phase
  (syscall/os packages, real netpoll, threads).
- The fork is rebased per Go release (~hours, Aug/Feb cadence);
  conflicts concentrate in `proc.go` and `zosarch.go`.
- The 1 MiB staging bound and the 4096-page recording cap are the next
  ceilings; region-level memory accounting (a M29 follow-up) replaces the
  per-page array eventually.
