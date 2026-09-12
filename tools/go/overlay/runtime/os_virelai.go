// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

//go:build virelai

package runtime

import (
	"internal/runtime/atomic"
	"unsafe"
)

// The VirelaiOS GOOS layer (issue #1163, GOOS=virelai phase 0a).
//
// VirelaiOS is a from-scratch AArch64 kernel (Zig) booted by Apple's
// Virtualization.framework: NO POSIX, NO libc, NO Linux ABI, no signals,
// no fork/exec. The EL0 syscall seam is a single `svc #0` with the number
// in x8, args in x0-x5 and the result in x0 (negative = the kernel's own
// errno encoding, ADR 0007) — see kernel/src/syscall.zig.
//
// Phase 0a is a SINGLE-THREAD target: sysmon is disabled (one fork delta
// in proc.go's haveSysmon), newosproc throws, and locks come from
// lock_sema.go (spinning semaphores, no OS primitives). Phase 0b adds
// thread_create/futex slots 72/73 and removes the sysmon delta.
//
// Memory uses the runtime's sbrk platform (mem_sbrk.go, build-tagged for
// virelai): the heap grows contiguously from firstmoduledata.end via
// sys_mmap with an address hint — Linux-brk semantics over the kernel's
// demand-backed anonymous mmap (slot 63), with zero kernel-side heap
// changes. physPageSize must be 4096 (the kernel's page size; the arm64
// default of 64K would misalign every sbrk round).

// Syscall numbers (ADR 0007, kernel/src/syscall.zig).
const (
	virSysWrite     = 1  // sys_write(fd, buf, len): console, <=256B/call
	virSysYield     = 2  // sys_yield()
	virSysExit      = 3  // sys_exit(status)
	virSysTime      = 66 // sys_time(): boot wall-clock epoch, unix seconds
	virSysGetrandom = 72 // sys_getrandom(buf, len): CSPRNG bytes (M51 #1166)
)

// virWrite1 issues ONE sys_write (the kernel caps len at 256 bytes).
//
//go:noescape
func virWrite1(fd uintptr, p unsafe.Pointer, n int32) int32

func virYield()

//go:noescape
func virExit(code int32)

//go:noescape
func virTime() int64

//go:noescape
func virGetrandom(p *byte, n int) int

//go:noescape
func virCntFreq() uint64

// nanotime1 reads CNTPCT_EL0 and scales by monoMul (below).
func nanotime1() int64

// write1 is the runtime's whole fatal/print output surface (writeErr ->
// write1). The kernel accepts <=256 bytes per call, so chunk here. The
// chunk loop keeps write1 nosplit-safe: it calls only NOSPLIT asm.
//
// virWriteStaging lives in the image's RW data segment, which the exec
// gap path registers as a task uaccess region. sys_write's copy_in
// validates the BUFFER address against those regions, and Go stacks live
// in the sbrk heap (an unregistered sys_mmap region) — printing straight
// from a stack buffer would EFAULT. Stage every chunk here first.
var virWriteStaging [256]byte

//go:nosplit
func write1(fd uintptr, p unsafe.Pointer, n int32) int32 {
	const chunkMax = 256
	total := int32(0)
	for n > 0 {
		chunk := int32(chunkMax)
		if n < chunk {
			chunk = n
		}
		memmove(unsafe.Pointer(&virWriteStaging), p, uintptr(chunk))
		w := virWrite1(fd, unsafe.Pointer(&virWriteStaging), chunk)
		if w < 0 {
			if total == 0 {
				return w
			}
			break
		}
		total += w
		if w < chunk {
			break // short write: give up honestly
		}
		p = add(p, uintptr(w))
		n -= w
		_ = virWriteStaging
	}
	return total
}

//go:nosplit
func osyield() {
	virYield()
}

// usleep busy-yields to the scheduler until the deadline elapses (the
// kernel has no timed sleep yet; slot 75 nanosleep is phase 0b).
//
//go:nosplit
func usleep(usec uint32) {
	deadline := nanotime() + int64(usec)*1000
	for nanotime() < deadline {
		osyield()
	}
}

//go:nosplit
func osyield_no_g() {
	virYield()
}

//go:nosplit
func usleep_no_g(usec uint32) {
	usleep(usec)
}

func exit(code int32) {
	virExit(code)
	for {
		osyield() // not reached; belt and braces if the kernel ever returns
	}
}

func exitThread(wait *atomic.Uint32) {
	// Phase 0a is single-threaded: no thread ever exits but the caller.
	throw("exitThread: unimplemented on virelai (phase 0b adds threads)")
}

// osinit runs before mallocinit; it must set physPageSize and
// numCPUStartup, and (sbrk platforms) init the break.
func osinit() {
	physPageSize = 4096
	numCPUStartup = 1
	getg().m.procid = 1
	initMonoScale()
	wallEpochSec = virTime()
	initBloc()
}

// getCPUCount backs cgroup_stubs.go's defaultGOMAXPROCS path: the phase
// 0a target is one core.
func getCPUCount() int32 {
	return 1
}

// Per-GOOS extensions of m (runtime2.go embeds mOS) and the unused
// signal-stack type (plan9/wasm shape — no signals exist on virelai).
type mOS struct {
	// lock_sema.go's semaphore slot (the openbsd shape, userspace-only:
	// single-threaded phase 0a never contends; semasleep yields).
	waitsemacount uint32
}

// gsignalStack is unused on virelai (no signal delivery in phase 0a).
type gsignalStack struct{}

// ---- lock_sema.go's required semaphore primitives (userspace-only) ----
// The kernel has no futex; phase 0a never contends (one M), so semasleep
// spins on the m's count with osyield backoff. Phase 0b replaces this
// with futex over slot 73.

//go:nosplit
func semacreate(mp *m) {}

//go:nosplit
func semasleep(ns int64) int32 {
	gp := getg()
	var deadline int64
	if ns >= 0 {
		deadline = nanotime() + ns
	}
	for {
		v := atomic.Load(&gp.m.waitsemacount)
		for v > 0 {
			if atomic.Cas(&gp.m.waitsemacount, v, v-1) {
				return 0 // acquired
			}
			v = atomic.Load(&gp.m.waitsemacount)
		}
		if ns >= 0 && nanotime() >= deadline {
			return -1 // timed out
		}
		osyield()
	}
}

//go:nosplit
func semawakeup(mp *m) {
	atomic.Xadd(&mp.waitsemacount, 1)
}

// libpreinit: hook for libc-initialized systems (libinit.go); a no-op —
// virelai has no libc and no constructor phase.
func libpreinit() {
}

// Time: the guest counter is EL0-readable (CNTKCTL_EL1 arms EL0VCTEN, the
// kernel's timer.allow_el0_counter), so nanotime is a pure register read
// scaled by a per-boot multiplier — no syscall on the hot path.
//
// ns = (ticks * monoMul) >> monoShift, with monoMul = floor(2^monoShift *
// 1e9 / cntfrq_el0) computed once at boot. monoShift = 44 keeps monoMul
// under 64 bits for any counter frequency above ~1 MHz (VZ guests run at
// 24 MHz) and the 128/64 division's high word (1e9 >> 20 = 953) below the
// divisor.
const monoShift = 44

var monoMul uint64

// wallEpochSec is the wall-clock (unix) second at CNTPCT=0 — the boot
// epoch from sys_time (slot 66). wall = epoch + elapsed monotonic.
var wallEpochSec int64

func initMonoScale() {
	freq := virCntFreq()
	if freq < 1_000_000 {
		freq = 1_000_000 // paranoia: never scale time faster than real
	}
	// 128/64 restoring division: q = (hi:lo) / y, valid because hi < y.
	// (hi:lo) is the 128-bit representation of 1e9 * 2^monoShift: runtime
	// shifts (not constants — 1e9<<44 overflows a uint64 constant).
	oneE9 := uint64(1_000_000_000)
	hi := oneE9 >> (64 - monoShift)
	lo := oneE9 << monoShift
	r := hi
	var q uint64
	for i := 0; i < 64; i++ {
		r = r<<1 | lo>>63
		lo <<= 1
		q <<= 1
		if r >= freq {
			r -= freq
			q |= 1
		}
	}
	monoMul = q
}

func walltime() (sec int64, nsec int32) {
	ns := nanotime()
	sec = wallEpochSec + ns/1_000_000_000
	nsec = int32(ns % 1_000_000_000)
	return
}

func cputicks() int64 {
	return nanotime()
}

// readRandom seeds the runtime PRNG (randinit calls it unconditionally).
// Returns the byte count filled; 0 on failure (randinit falls back to
// time-based seeding).
func readRandom(r []byte) int {
	if len(r) == 0 {
		return 0
	}
	n := virGetrandom(&r[0], len(r))
	if n < 0 {
		return 0
	}
	return n
}

// goenvs: no environment on virelai (exec passes none).
func goenvs() {
	envs = make([]string, 0)
}

// ---- signals: none (the kernel kills a faulting process; phase 0b/0c
// ---- add fault delivery -> sigtramp -> sigpanic) ----

type sigset [1]uint32

const _NSIG = 0

const _SIGSEGV = 0xb

func initsig(preinit bool) {}

func signame(sig uint32) string { return "" }

func sigdisable(sig uint32) {}
func sigenable(sig uint32)  {}
func sigignore(sig uint32)  {}

func sigsave(p *sigset)              {}
func msigrestore(sigmask sigset)     {}
func clearSignalHandlers()           {}
func sigblock(exiting bool)          {}
func minit()                         {}
func unminit()                       {}
func mdestroy(mp *m)                 {}
func os_sigpipe()                    {}
func setProcessCPUProfiler(hz int32) {}
func setThreadCPUProfiler(hz int32)  {}

// Called to initialize a new m (including the bootstrap m). The signal
// stack is never used on virelai (no signals), but mcommoninit calls
// mpreinit unconditionally — mirror os_wasm.go and allocate it.
func mpreinit(mp *m) {
	mp.gsignal = malg(32 * 1024)
	mp.gsignal.m = mp
}

func crash() {
	abort() // runtime·abort lives in asm_arm64.s for every arm64 GOOS
}

// sigpanic: no fault delivery exists in phase 0a (an EL0 data abort kills
// the process), so this is only reached through explicit panic paths.
// Phase 0c wires the kernel's fault seam into sigtrampgo.
func sigpanic() {
	gp := getg()
	if !canpanic() {
		throw("unexpected signal during runtime execution")
	}
	gp.sig = _SIGSEGV
	panicmem()
}

// ---- threads: phase 0a is single-threaded ----

func newosproc(mp *m) {
	throw("newosproc: unimplemented on virelai (phase 0b adds slot 72 thread_create)")
}

func newosproc0(stacksize uintptr, fn unsafe.Pointer) {
	throw("newosproc0: unimplemented on virelai")
}

const preemptMSupported = false

func preemptM(mp *m) {
	// No async preemption (no signals); cooperative safe points only.
}

// sbrk backs the mem_sbrk.go platform layer: grow the break to bl+n by
// mapping CONTIGUOUSLY at the current mapped end (sys_mmap honors
// page-aligned address hints), demand-backed — untouched pages cost
// nothing physical.
func sbrk(n uintptr) unsafe.Pointer {
	bl := bloc
	n = memRound(n)
	if bl+n > blocMax {
		if virMmap(unsafe.Pointer(blocMax), bl+n-blocMax) < 0 {
			return nil
		}
		blocMax = bl + n
	}
	bloc += n
	return unsafe.Pointer(bl)
}

// virMmap maps [addr, addr+n) anonymously (sys_mmap slot 63: x0=addr
// hint — page-aligned → honored, x1=len, x2=prot RW, x3=MAP_ANONYMOUS,
// no POPULATE: demand faults zero-fill and the kernel records touched
// pages). Returns the kernel's negative errno on failure, >= 0 on
// success (the mapped base).
//
//go:noescape
func virMmap(addr unsafe.Pointer, n uintptr) int
