// GOOS=virelai phase 0c probe (issue #1228): fault delivery to panic.
//
// Three serial-ordered phases, each printing one exact completion line:
//  1. main goroutine forces a REAL data abort (a load from unmapped
//     0x8 through an opaque pointer, so the compiler cannot rewrite it
//     into an explicit nil panic), recovers, and reports the
//     runtime.Error text — proves kernel delivery + recover().
//  2. the same fault on a worker goroutine (a different M / kernel
//     task) — proves delivery is per-thread, not main-only.
//  3. a fault whose deferred probe walks runtime.CallersFrames BEFORE
//     recovering: finding runtime.sigpanic + the faulting function in
//     the frames proves the unwinder crosses the injected sigpanic
//     frame (the traceback machinery, in-process, exit still 0).
//
// Zero standard-library OS imports — runtime only. os/time are phase 2.
package main

import (
	"runtime"
	"unsafe"
)

// faultAddr is package-level (opaque to the compiler) so the load below
// is a genuine faulting instruction, never an explicit panicnil.
var faultAddr = uintptr(0x8)

var sink byte

func readUnmapped() byte {
	return *(*byte)(unsafe.Pointer(faultAddr))
}

func faultAndRecover() (msg string) {
	defer func() {
		if r := recover(); r != nil {
			if e, ok := r.(runtime.Error); ok {
				msg = e.Error()
			} else {
				msg = "non-runtime-error"
			}
		}
	}()
	sink = readUnmapped()
	return "no-fault"
}

func worker(ch chan<- string) {
	ch <- faultAndRecover()
}

func probeFrames() (foundSigpanic, foundProbe bool) {
	defer func() {
		_ = recover()
	}()
	defer func() {
		// While the panic is still active (before recover), the stack
		// still spans the injected sigpanic frame: walk it.
		var pcs [16]uintptr
		n := runtime.Callers(0, pcs[:])
		frames := runtime.CallersFrames(pcs[:n])
		for {
			f, more := frames.Next()
			if f.Function == "runtime.sigpanic" {
				foundSigpanic = true
			}
			if f.Function == "main.probeFrames" {
				foundProbe = true
			}
			if !more {
				break
			}
		}
	}()
	sink = readUnmapped()
	return false, false
}

func main() {
	println("go-panic procs=" + itoa(runtime.GOMAXPROCS(0)))
	println("go-panic main recovered=" + faultAndRecover())
	ch := make(chan string, 1)
	go worker(ch)
	println("go-panic worker recovered=" + <-ch)
	sp, pr := probeFrames()
	println("go-panic frames sigpanic=" + itoa(b2i(sp)) + " probe=" + itoa(b2i(pr)))
	println("go-panic done")
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
