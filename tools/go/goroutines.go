// GOOS=virelai threads proof (ADR 0027 D6, issue #1214 round 2).
//
// N goroutines (N > GOMAXPROCS) each bump an atomic counter and send on a
// buffered channel; main drains N completions and prints the done line with
// counter == n. Proves the M:N machinery end to end on kernel slot-73
// tasks: newosproc maps Ms onto same-process kernel tasks, sysmon runs,
// locks park on the slot-74 futex, and goroutines migrate across cores —
// the gate also asserts task=GOROUT.ELF in the monitor smp report.
package main

import (
	_ "unsafe"

	"runtime"
	"sync/atomic"
)

//go:linkname goargs runtime.VirelaiArgs
func goargs() []string

var counter uint64

func main() {
	args := goargs()
	_ = args
	const n = 8
	done := make(chan int, n)
	for i := 0; i < n; i++ {
		go func(i int) {
			atomic.AddUint64(&counter, 1)
			done <- i
		}(i)
	}
	for k := 0; k < n; k++ {
		<-done
	}
	println("go-goroutines procs=" + itoa(runtime.GOMAXPROCS(0)))
	println("go-goroutines done n=" + itoa(n) + " counter=" + itoa(int(counter)))
}

// itoa: the fixture's only dependency-free positive-int formatter (one
// string keeps the serial assertion exact).
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
