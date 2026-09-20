// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

//go:build virelai

package runtime

import (
	"internal/abi"
	"unsafe"
)

// The VirelaiOS fault-delivery surface (issue #1228, GOOS=virelai phase
// 0c). The kernel delivers a deliverable EL0 fault synchronously: it
// redirects the faulting task to `sigtramp` with the fault record in
// registers (x0=sig, x1=addr, x2=pc, x3=esr, x4=sp_el0, x5=lr, x6=r29 —
// see exceptions.zig `fault_deliverable`). sigtramp switches to the
// gsignal stack, runs virfaulthandler (which arms sigpanic on the
// faulting stack, the preparePanic shape), then resumes the faulting g
// at sigpanic. From there it is an ordinary panic: recover() works, an
// unrecovered one prints the traceback and exits via crash().
//
// There is no sigreturn and no resume-the-faulting-instruction path: a
// delivered fault always panics (or throws when panicking is illegal).
// A fault INSIDE the handler is refused delivery by the kernel (ELR ==
// handler) and reaps the process — the backstop against handler loops.

type sigset [1]uint32

const _NSIG = 0

const (
	_SIGILL  = 0x4
	_SIGBUS  = 0x7
	_SIGSEGV = 0xb
)

func signame(sig uint32) string {
	switch sig {
	case _SIGILL:
		return "illegal instruction"
	case _SIGBUS:
		return "bus error"
	case _SIGSEGV:
		return "segmentation violation"
	}
	return "unknown signal"
}

func initsig(preinit bool) {
	// The plan9 shape: register the trampoline once the runtime is up.
	// The abi.FuncPCABI0 reference keeps sigtramp alive through
	// dead-code elimination (cmd/link keeps nothing unreferenced).
	if !preinit {
		if virExnotifyRegister(unsafe.Pointer(abi.FuncPCABI0(sigtramp))) != 0 {
			throw("initsig: sys_exnotify register failed")
		}
	}
}

func sigdisable(sig uint32) {}
func sigenable(sig uint32)  {}
func sigignore(sig uint32)  {}

func sigsave(p *sigset)          {}
func msigrestore(sigmask sigset) {}
func clearSignalHandlers()       {}
func sigblock(exiting bool)      {}
func minit()                     {}
func unminit()                   {}
func mdestroy(mp *m)             {}
// os_sigpipe backs os's bodyless declaration `func sigpipe()` in
// os/file_unix.go, which os.File.Write reaches through epipecheck when a
// write to stdout/stderr fails with EPIPE. The //go:linkname is what makes
// this function BE that symbol: without it the declaration links against
// nothing and the guest dies at link time with
//
//	os.(*File).Write: relocation target os.sigpipe not defined
//
// which is a link-time gap a `go build os` cannot see (found by the M70c-S1P
// in-guest fixture, #1525). The body is empty on purpose: nothing here
// delivers signals, so there is no SIGPIPE to raise and the EPIPE the writer
// already has is the entire report.
//
//go:linkname os_sigpipe os.sigpipe
func os_sigpipe()                {}
func setProcessCPUProfiler(hz int32) {}
func setThreadCPUProfiler(hz int32)  {}

// Called to initialize a new m (including the bootstrap m). The gsignal
// stack backs the fault-delivery path: sigtramp runs virfaulthandler on
// it so a fault on an exhausted goroutine stack still panics cleanly.
func mpreinit(mp *m) {
	mp.gsignal = malg(32 * 1024)
	mp.gsignal.m = mp
}

func crash() {
	// Phase 0c: exit through the syscall, never through a fault.
	// abort()'s deliberate nil-deref would re-enter the fault handler
	// with no demotion backstop (unix has isAbortPC; virelai has the
	// kernel's nested-fault reap, which would hide the traceback), so the
	// fatal traceback that already printed is the whole report.
	virExit(2)
	for {
		osyield() // not reached; belt and braces if the kernel ever returns
	}
}

// sigtramp is the kernel's fault entry (sys_virelai_arm64.s, ABI0): the
// fault record arrives in x0-x6, g (R28) is the faulting g.
func sigtramp()

//go:noescape
func virExnotifyRegister(handler unsafe.Pointer) int

// virfaulthandler runs on the gsignal stack (see sigtramp). It records
// the fault on the faulting gp and returns the resume triple that makes
// the faulting stack look like the faulting PC called sigpanic directly
// (the unix preparePanic shape, inlined — sigctxt is unix-only).
//
// The triple is applied by sigtramp's epilogue; virfaulthandler itself
// never resumes anything. Throwing (rather than returning) kills the
// process through crash() when panicking is illegal.
//
//go:nosplit
//go:nowritebarrierrec
func virfaulthandler(gp *g, sig uint32, addr, pc, esr, sp, lr, r29 uintptr) (newsp, newlr, newpc uintptr) {
	if gp == nil || gp.m == nil {
		throw("fault on foreign thread")
	}
	if !canpanic() {
		throw("unexpected signal during runtime execution")
	}
	gp.sig = sig
	if sig == _SIGSEGV || sig == _SIGBUS {
		gp.sigcode0 = 0
		gp.sigcode1 = addr
	}
	gp.sigpc = pc
	// Always push the sigpanic frame (fault PCs are never nil calls —
	// those are compiler-emitted explicit panics, never faults — so the
	// shouldPushSigpanic refinement has nothing to say here). Carve 16
	// aligned bytes, stash the fault LR + R29 for the unwinder.
	newsp = sp - 16
	*(*uintptr)(unsafe.Pointer(newsp)) = lr
	*(*uintptr)(unsafe.Pointer(newsp - unsafe.Sizeof(uintptr(0)))) = r29
	newlr = pc
	newpc = uintptr(abi.FuncPCABIInternal(sigpanic))
	return
}

// sigpanic converts the delivered fault into a panic (the unix sigpanic
// shape, minus the siginfo/sigtable parts that are unix-only). Fault
// addresses below 4 KiB are nil-dereference-shaped and panicmem so the
// message names the bug; anything else is an honest throw.
func sigpanic() {
	gp := getg()
	if !canpanic() {
		throw("unexpected signal during runtime execution")
	}
	switch gp.sig {
	case _SIGSEGV, _SIGBUS:
		if gp.sigcode1 < 0x1000 {
			panicmem()
		}
		// Support runtime/debug.SetPanicOnFault.
		if gp.paniconfault {
			panicmemAddr(gp.sigcode1)
		}
		print("unexpected fault address ", hex(gp.sigcode1), "\n")
		throw("fault")
	case _SIGILL:
		panic(errorString("illegal instruction"))
	}
	panic(errorString(signame(gp.sig)))
}
