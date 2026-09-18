// GOOS=virelai multicore-M fixture (M70b #1454; sibling of goroutines.go /
// gostress.go — goroutines.go stays the N=8 / compiled-default proof and is
// not touched by this card).
//
// Phase A (placement): GOMAXPROCS(4) — the stock runtime knob, no runtime
// fork, no GOOS delta (ADR 0027 governs) — then exactly 4 workers, each
// bumping a shared started counter and then spinning Gosched-free on a
// release flag, so 4 worker Ms stay simultaneously runnable. Main holds a
// busy window of >= ~6 s (the kernel scheduler tick is ~1 Hz — timer.zig
// period_ns = 1 s) so the gate's second serial script can run the monitor
// `smp` command inside the window and catch task=GOSCALE.ELF on distinct
// cores (slot-73 tasks carry the PROCESS name).
//
// Phase B (accounted work): each worker performs exactly 25000 units; ONE
// unit = a small fixed burst of pure userspace work (a bounded arithmetic
// loop — the same tight idiom as the busy-window spin) followed by one
// atomic add to that worker's OWN counter (4 separate uint64s, so the adds
// never contend). NO syscalls anywhere in the unit: observed on the
// kernel, a slot-2 sys_yield is a full ring rotation, and with the 1 Hz
// timer tick (timer.zig period_ns = 1 s) a non-yielding ready task that
// shares the ring — the shell idle loop busy-spins — takes the quantum
// for up to a second, so yield-units measure the scheduler, not the work.
// A pure-userspace unit makes the tick delta a real parallelism
// measurement: the same 100k units at --cpus 1/2/4. After its N units a
// worker prints its accounted count; main joins the 4 workers (buffered
// channel, the goroutines.go idiom), sums the counters, and asserts the
// sum == 4*N in code — every unit accounted exactly once, no lost or
// double-counted work. A failed assert prints MISMATCH instead of the
// done line so the gate fails honestly. Around phase B main reads the
// EL0 counter (cntpct_el0 / cntfrq_el0 — the kernel opens EL0 access at
// boot, kernel/src/timer.zig allow_el0_counter; the asm idiom is the SDK's
// user/go/vsys/vsys_counter_arm64.s) and prints the tick delta as OBSERVED
// DATA — the gate records it, it is never a pass/fail threshold.
//
// Preemption caveat (ADR 0027 D5): preemptMSupported = false, so a
// Gosched-free worker wedges its P until it observes release. Main's wait
// for started==4 is therefore a BOUNDED Gosched loop: in the fair case the
// four bumps land within a handful of Goscheds; if the no-preempt
// scheduler starves a worker's first quantum, the bound lets main reach
// the release anyway, and the released stragglers drain phase B (their
// spin exits on the flag, so no worker is lost — the accounted sum still
// proves it).
package main

import (
	_ "unsafe"

	"runtime"
	"sync/atomic"

	// Blank import: it pulls the vsys package (and its counter assembly)
	// into the link for the two linknames below. The fixture calls
	// nothing in it — phase B is pure userspace.
	_ "virelai/vsys"
)

// The raw EL0 counter reads (virelai/vsys keeps them unexported; the
// linkname-to-SDK-internals shape is the gowin.go //go:linkname
// virelai/vi.syscall6 precedent). No libc, no heap, no syscall slot: MRS
// CNTPCT_EL0 / MRS CNTFRQ_EL0.
//
//go:linkname counterTicks virelai/vsys.virCounterTicks
func counterTicks() uint64

//go:linkname counterFreq virelai/vsys.virCounterFreq
func counterFreq() uint64

const (
	// Exactly 4 workers — the multicore-M placement proof spins exactly
	// this many Ms (marker contract: "busy m=4", w0..w3).
	workers = 4

	// Phase-B accounting: exactly this many units per worker, one unit =
	// one unitBurst of pure userspace arithmetic + one atomic add to the
	// worker's own counter (see the header for why the unit is NOT a
	// sys_yield).
	unitsPerWorker = 25000

	// The burst body: bounded arithmetic iterations per unit, sized so
	// the 100k-unit phase costs seconds at --cpus 1 (a measurable,
	// comparable tick delta at 1/2/4 cores) while staying far inside
	// the gate's 240 s timeout. The per-iteration store into burn[i] is
	// what the compiler cannot eliminate.
	unitBurst = 10000

	// Phase-A busy window, in seconds of EL0 counter time: the ~1 Hz
	// scheduler tick plus the second serial script's `smp` round trip
	// must fit INSIDE the window, so the contract's >= ~6 s becomes 7 s.
	// Bounded by the counter, not a sleep: no timer machinery, no slot-4
	// sleep, no channels — main's M just spins.
	holdSeconds = 7

	// Bound on main's Gosched wait for started==workers (see the header
	// caveat). Fair case: a handful of Goscheds. Starved case: main
	// ping-pongs the global queue ~microseconds per Gosched, so even the
	// full bound is well under the busy window before main gives up
	// waiting and releases anyway.
	waitBound = 1_000_000
)

var (
	started uint64 // workers that bumped their first quantum
	release uint64 // phase-A spin flag: 1 = leave the spin, do phase B
	// Per-worker counters — indexed, NOT one shared atomic: the phase-B
	// adds never contend and the gate's every-unit-accounted-once check
	// is per worker.
	counters [workers]uint64
	// Per-worker burst accumulators (indexed the same way — workers
	// never share a word, so plain non-atomic stores are race-free).
	// Package-level so the unit burst's stores cannot be dead-code
	// eliminated; the values are never read.
	burn [workers]uint64
)

// itoa: the fixture's only dependency-free non-negative-int formatter
// (one string keeps the serial assertion exact); mirrors goroutines.go.
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

func main() {
	// The card's knob: 4 Ps so the 4 workers can hold 4 Ms on 4 cores.
	// Stock runtime surface only — goroutines.go relies on the compiled
	// numCPUStartup=2 default (its gate asserts procs=2); this fixture
	// needs the multicore placement, so it pins 4 here.
	runtime.GOMAXPROCS(4)

	done := make(chan int, workers)
	for i := 0; i < workers; i++ {
		go func(i int) {
			atomic.AddUint64(&started, 1)
			// Gosched-free busy spin: holds this worker's M runnable
			// on its core for the placement proof. Exits only on the
			// release flag, so a worker stranded behind the no-preempt
			// scheduler drains as soon as main releases.
			for atomic.LoadUint64(&release) == 0 {
			}
			// Phase B: exactly unitsPerWorker units; one unit = one
			// unitBurst of pure userspace arithmetic (no syscalls —
			// see the header) plus one add to this worker's own
			// counter.
			for u := 0; u < unitsPerWorker; u++ {
				for j := 0; j < unitBurst; j++ {
					burn[i] += uint64(j) ^ 0x9e3779b97f4a7c15
				}
				atomic.AddUint64(&counters[i], 1)
			}
			units := atomic.LoadUint64(&counters[i])
			println("goscale: w" + itoa(i) + " units=" + itoa(int(units)))
			done <- i
		}(i)
	}

	// Bounded Gosched wait until all 4 workers bumped started (header
	// caveat explains the bound).
	for k := 0; k < waitBound && atomic.LoadUint64(&started) < workers; k++ {
		runtime.Gosched()
	}
	println("goscale: busy m=4")

	// Hold the busy window: ~holdSeconds of EL0 counter time while the
	// worker Ms spin — the window the gate's second serial script uses
	// to run `smp`. Ticks are 64-bit and the boot age is tiny, so this
	// addition cannot wrap.
	freq := counterFreq()
	holdEnd := counterTicks() + holdSeconds*freq
	for counterTicks() < holdEnd {
	}

	// Around phase B: raw CNTPCT_EL0 before the release and after the
	// join — observed data, never a threshold.
	t0 := counterTicks()
	atomic.StoreUint64(&release, 1)
	println("goscale: released m=4")
	for k := 0; k < workers; k++ {
		<-done
	}
	t1 := counterTicks()

	// The done value is the ACTUAL atomic sum, asserted in code against
	// 4*N: every unit accounted exactly once.
	total := uint64(0)
	for i := 0; i < workers; i++ {
		total += atomic.LoadUint64(&counters[i])
	}
	if total == workers*unitsPerWorker {
		println("goscale: done units=" + itoa(int(total)))
	} else {
		println("goscale: MISMATCH units=" + itoa(int(total)))
	}
	println("goscale: ticks=" + itoa(int(t1-t0)) + " freq=" + itoa(int(freq)))
}
