// GOOS=virelai 0b breadth stress (issue #1227).
//
// Four serial-ordered phases, each printing one exact completion line so
// the go-stress gate can assert order without a script-echo race:
//   1. GC pressure — short-lived 64 KiB churn + a few live retainers,
//      then two explicit runtime.GC() cycles (STW at cooperative safe
//      points, mark, sweep through the sbrk free list).
//   2. Channel fan-out — 8 workers ranging a jobs channel, 32 items,
//      results drained; sum(2*i for i in 0..31) == 992.
//   3. Timer pacing — 8 goroutines VirelaiSleep(10ms); wall elapsed must
//      be >= 10ms (sysmon + the timer heap, not the busy-yield usleep).
//      Package time is not imported: it pulls syscall, unported until
//      phase 2. The fixture linknames runtime.VirelaiSleep / Nanotime.
//   4. Futex contention — 32 goroutines × 50 sync.Mutex increments
//      (lock_sema → slot 74) plus a park-all-then-wake on an unbuffered
//      channel. N=32 is past the ADR 0027 D6 N=8 baseline in goroutines.go.
//
// Zero standard-library OS imports — runtime / sync / atomic only. os
// and time are phase 2.
package main

import (
	_ "unsafe"

	"runtime"
	"sync"
	"sync/atomic"
)

//go:linkname virelaiNanotime runtime.VirelaiNanotime
func virelaiNanotime() int64

//go:linkname virelaiSleep runtime.VirelaiSleep
func virelaiSleep(ns int64)

func main() {
	println("go-stress procs=" + itoa(runtime.GOMAXPROCS(0)))
	phaseGC()
	phaseChan()
	phaseTimer()
	phaseFutex()
	println("go-stress done")
}

func phaseGC() {
	const allocs = 120
	const chunk = 64 * 1024
	var live [][]byte
	nalloc := 0
	for i := 0; i < allocs; i++ {
		b := make([]byte, chunk)
		b[0] = byte(i)
		b[len(b)-1] = byte(i >> 8)
		nalloc++
		if i%15 == 0 {
			live = append(live, b)
		}
	}
	runtime.GC()
	runtime.GC()
	spot := 0
	for _, b := range live {
		spot += int(b[0]) + int(b[len(b)-1])
	}
	_ = spot
	println("go-stress gc allocs=" + itoa(nalloc) + " live=" + itoa(len(live)))
}

func phaseChan() {
	const workers = 8
	const jobs = 32
	work := make(chan int)
	results := make(chan int, jobs)
	for w := 0; w < workers; w++ {
		go func() {
			for v := range work {
				results <- v * 2
			}
		}()
	}
	for i := 0; i < jobs; i++ {
		work <- i
	}
	close(work)
	sum := 0
	recv := 0
	for i := 0; i < jobs; i++ {
		sum += <-results
		recv++
	}
	println("go-stress chan fan=" + itoa(jobs) + " recv=" + itoa(recv) + " sum=" + itoa(sum))
}

func phaseTimer() {
	const n = 8
	const slackNs int64 = 10_000_000 // 10ms; runtime.timeSleep / sysmon
	done := make(chan struct{}, n)
	start := virelaiNanotime()
	for i := 0; i < n; i++ {
		go func() {
			virelaiSleep(slackNs)
			done <- struct{}{}
		}()
	}
	for i := 0; i < n; i++ {
		<-done
	}
	elapsed := virelaiNanotime() - start
	if elapsed < slackNs {
		println("go-stress timer FAIL")
		return
	}
	println("go-stress timer n=" + itoa(n) + " ok")
}

func phaseFutex() {
	const g = 32
	const iters = 50
	var mu sync.Mutex
	var n uint64
	done := make(chan struct{}, g)
	for i := 0; i < g; i++ {
		go func() {
			for j := 0; j < iters; j++ {
				mu.Lock()
				n++
				mu.Unlock()
			}
			done <- struct{}{}
		}()
	}
	for i := 0; i < g; i++ {
		<-done
	}

	// Park all 32 on an unbuffered channel, then wake them — forces Ms
	// through semasleep/futex rather than a lucky uncontended mutex path.
	ch := make(chan int)
	var ready uint64
	for i := 0; i < g; i++ {
		go func() {
			atomic.AddUint64(&ready, 1)
			<-ch
			done <- struct{}{}
		}()
	}
	for atomic.LoadUint64(&ready) < g {
		runtime.Gosched()
	}
	for i := 0; i < g; i++ {
		ch <- 1
	}
	for i := 0; i < g; i++ {
		<-done
	}
	println("go-stress futex n=" + itoa(g) + " counter=" + itoa(int(n)))
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
