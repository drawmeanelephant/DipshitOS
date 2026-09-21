// GOOS=virelai seeded runtime stress breadth (M70a2, issues #1469/#1453).
//
// The #1227 fixture ran four fixed serial phases at exactly one shape;
// this extends it into a seeded randomized stress over the same runtime
// surfaces plus memory growth and goroutine churn: N fixed seeds × M
// iterations per seed, each iteration drawing its shape from an in-tree
// splitmix64 stream. Determinism contract (M70a D1/D2):
//   - Every decision comes from the seed — no wall-clock, no
//     runtime/cputicks, no sys_getrandom, no host entropy. A CI failure
//     and a laptop run produce the identical line sequence, and an argv
//     seed replays one seed alone: `exec GOSTRESS.ELF 0x9e3779b97f4a7c15`.
//   - Bounded guest time: 4 seeds × 8 iterations, each phase's worst case
//     is a few ms of sleeps and a few MiB of heap; no soak.
//
// Phases (one iteration line printed BEFORE the phase runs, one `… ok`
// detail line after it completes, so a red log names the failing phase):
//
//	gc     — churn of 40..80 × 64..128 KiB blocks against a retained live
//	         set, then 1..2 explicit runtime.GC() cycles (STW at
//	         cooperative safe points, sweep through the sbrk free list),
//	         then verify the retained bytes.
//	chan   — either a worker-pool fan-out (2..8 workers × 8..40 jobs,
//	         exact sum invariant) or a 2..6-stage unbuffered pipeline
//	         carrying 2..5 values (exact stage-arithmetic invariant);
//	         both exercise close-cascade drain paths.
//	timer  — 2..6 goroutines sleeping mixed 4..14 ms durations through
//	         runtime.VirelaiSleep (sysmon + timer heap); elapsed must
//	         cover the longest sleep. Invariant only — no thresholds.
//	futex  — 4..24 goroutines × 10..40 sync.Mutex increments (lock_sema
//	         → slot 74) with an exact counter invariant, optionally a
//	         park-all-then-wake round on an unbuffered channel.
//	mem    — a 2..3-step staircase whose block sizes grow base×(j+1)
//	         from a 256..512 KiB base (e.g. 384/768/1152 KiB), live
//	         across a runtime.GC(), then verified. This forces fresh
//	         sbrk break growth (mem_sbrk.go → sys_mmap slot 63) while
//	         staying inside the kernel's per-process max_mmap_regions
//	         budget (16) — heap growth is monotone on an sbrk platform,
//	         so every growth event costs one region.
//	churn  — goroutine exec/exit churn: 20..60 goroutines each run a
//	         3..49-frame recursive body (48 B frames, so the deeper ones
//	         cross the 2 KiB initial stack and go through morestack /
//	         newstack) and exit; exact counter invariant. "exec/exit" is
//	         goroutine execution/exit — the runtime exposes no
//	         fork/exec/wait seam (ADR 0027), and a process-exec seam
//	         would be a runtime change, which this card rules out.
//
// The kernel-effect counterpart is asserted by the go-stress gate spec
// from the `syscalls` report: sys_mmap (heap growth), sys_futex
// (contention) and sys_thread (M creation) call counts.
//
// Zero standard-library OS imports — runtime / sync / sync/atomic only;
// argv/clock access goes through the runtime's Virelai* seam linknames,
// as before.
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

//go:linkname goargs runtime.VirelaiArgs
func goargs() []string

// seedRoster — the fixed corpus. Explicit integers, published here and
// pinned by the gate spec; a seed that ever finds a crash is promoted to
// a pinned entry (M70a deliverable 4).
var seedRoster = []uint64{
	0x9E3779B97F4A7C15,
	0xA0761D6478BD642F,
	0xE7037ED1A0B428DB,
	0x0000000000C0FFEE,
}

const itersPerSeed = 8

func main() {
	println("go-stress procs=" + itoa(runtime.GOMAXPROCS(0)))
	args := goargs()
	seeds := seedRoster
	if len(args) > 1 {
		s, ok := parseSeed(args[1])
		if !ok {
			println("go-stress FAIL argv=" + args[1])
			return
		}
		seeds = []uint64{s}
	}
	for _, s := range seeds {
		if !runSeed(s) {
			// The FAIL line is already out; stop without the done
			// marker so the gate's script2-after anchor times out.
			return
		}
	}
	println("go-stress done")
}

// runSeed replays one seed: shuffle the six phases, append two rng
// extras, run them as itersPerSeed ordered iterations. All rng draws
// happen on the main goroutine — phase goroutines only see fixed
// parameters, so the printed sequence is bit-deterministic.
func runSeed(seed uint64) bool {
	r := &strng{s: seed}
	order := []string{"gc", "chan", "timer", "futex", "mem", "churn"}
	for i := len(order) - 1; i > 0; i-- {
		j := r.below(i + 1)
		order[i], order[j] = order[j], order[i]
	}
	plan := append(append([]string{}, order...), order[r.below(6)], order[r.below(6)])
	shex := "0x" + utoh(seed)
	for i, name := range plan {
		iter := itoa(i + 1)
		println("go-stress seed=" + shex + " iter=" + iter + " phase=" + name)
		var detail, fail string
		switch name {
		case "gc":
			detail, fail = phaseGC(r)
		case "chan":
			detail, fail = phaseChan(r)
		case "timer":
			detail, fail = phaseTimer(r)
		case "futex":
			detail, fail = phaseFutex(r)
		case "mem":
			detail, fail = phaseMem(r)
		case "churn":
			detail, fail = phaseChurn(r)
		}
		if fail != "" {
			println("go-stress FAIL seed=" + shex + " iter=" + iter +
				" phase=" + name + " " + fail)
			return false
		}
		println("go-stress seed=" + shex + " iter=" + iter + " phase=" + name +
			" " + detail + " ok")
	}
	println("go-stress seed=" + shex + " ok")
	return true
}

// phaseGC: allocation churn against a retained live set, explicit GC
// cycles, verify the survivors byte-for-byte.
func phaseGC(r *strng) (string, string) {
	allocs := 40 + r.below(41)
	chunk := (8 + r.below(9)) * 8 * 1024 // 64..128 KiB
	every := 10 + r.below(11)
	cycles := 1 + r.below(2)
	var live [][]byte
	var liveIdx []int
	for i := 0; i < allocs; i++ {
		b := make([]byte, chunk)
		b[0] = byte(i)
		b[len(b)-1] = byte(i >> 8)
		if i%every == 0 {
			live = append(live, b)
			liveIdx = append(liveIdx, i)
		}
	}
	for c := 0; c < cycles; c++ {
		runtime.GC()
	}
	for k, b := range live {
		i := liveIdx[k]
		if b[0] != byte(i) || b[len(b)-1] != byte(i>>8) {
			return itoa(allocs) + " blocks", "retained block " + itoa(i) + " corrupted"
		}
	}
	return "allocs=" + itoa(allocs) + " live=" + itoa(len(live)) +
		" cycles=" + itoa(cycles), ""
}

// phaseChan: worker-pool fan-out or a multi-stage unbuffered pipeline,
// both with exact arithmetic invariants over the drained results.
func phaseChan(r *strng) (string, string) {
	if r.below(2) == 0 {
		workers := 2 + r.below(7)
		jobs := 8 + r.below(33)
		work := make(chan int)
		results := make(chan int, jobs)
		var wg sync.WaitGroup
		wg.Add(workers)
		for w := 0; w < workers; w++ {
			go func() {
				defer wg.Done()
				for v := range work {
					results <- v * 2
				}
			}()
		}
		want := 0
		for i := 0; i < jobs; i++ {
			work <- i
			want += i * 2
		}
		close(work)
		wg.Wait()
		close(results)
		sum, recv := 0, 0
		for v := range results {
			sum += v
			recv++
		}
		if recv != jobs || sum != want {
			return itoa(jobs) + " jobs", "recv/sum mismatch"
		}
		return "fan workers=" + itoa(workers) + " jobs=" + itoa(jobs), ""
	}
	stages := 2 + r.below(5)
	vals := 2 + r.below(4)
	base := 1 + r.below(99)
	first := make(chan int)
	in := first
	for s := 0; s < stages; s++ {
		out := make(chan int)
		go func(cin, cout chan int) {
			for v := range cin {
				cout <- v + 1
			}
			close(cout)
		}(in, out)
		in = out
	}
	go func() {
		for j := 0; j < vals; j++ {
			first <- base + j
		}
		close(first)
	}()
	var tail []int
	for v := range in {
		tail = append(tail, v)
	}
	if len(tail) != vals {
		return itoa(stages) + " stages", "lost pipeline values"
	}
	for j, v := range tail {
		if v != base+j+stages {
			return itoa(stages) + " stages", "stage arithmetic wrong at value " + itoa(j)
		}
	}
	return "chain stages=" + itoa(stages) + " vals=" + itoa(vals), ""
}

// phaseTimer: mixed-duration sleeps through the runtime's timer seam;
// the invariant is coverage (elapsed >= longest sleep), never a timing
// threshold (invariant-only, per the parent card).
func phaseTimer(r *strng) (string, string) {
	n := 2 + r.below(5)
	done := make(chan struct{}, n)
	maxMs := int64(0)
	start := virelaiNanotime()
	for i := 0; i < n; i++ {
		ms := int64(4 + r.below(11))
		if ms > maxMs {
			maxMs = ms
		}
		go func(ms int64) {
			virelaiSleep(ms * 1000 * 1000)
			done <- struct{}{}
		}(ms)
	}
	for i := 0; i < n; i++ {
		<-done
	}
	elapsed := virelaiNanotime() - start
	if elapsed < maxMs*1000*1000 {
		return itoa(n) + " sleepers", "sleep returned early"
	}
	return "n=" + itoa(n) + " maxms=" + itoa(int(maxMs)), ""
}

// phaseFutex: contended mutex increments with an exact counter
// invariant, optionally a park-all-then-wake round that forces Ms
// through semasleep/futex rather than a lucky uncontended path.
func phaseFutex(r *strng) (string, string) {
	g := 4 + r.below(21)
	iters := 10 + r.below(31)
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
	if n != uint64(g)*uint64(iters) {
		return itoa(g) + " workers", "counter lost updates"
	}
	park := ""
	if r.below(2) == 1 {
		ch := make(chan int)
		var ready uint64
		for i := 0; i < g; i++ {
			go func() {
				atomic.AddUint64(&ready, 1)
				<-ch
				done <- struct{}{}
			}()
		}
		for atomic.LoadUint64(&ready) < uint64(g) {
			runtime.Gosched()
		}
		for i := 0; i < g; i++ {
			ch <- 1
		}
		for i := 0; i < g; i++ {
			<-done
		}
		park = " parkwake=1"
	}
	return "g=" + itoa(g) + " iters=" + itoa(iters) + " counter=" +
		itoa(int(n)) + park, ""
}

// phaseMem: a small staircase of large blocks, live across an explicit
// GC, then verified — the fresh-break-growth proof behind the gate's
// sys_mmap assertion. Sizes stay inside the 16-region per-process
// sys_mmap budget shared with every other phase (an sbrk platform never
// returns break memory, so each growth event is permanent).
func phaseMem(r *strng) (string, string) {
	steps := 2 + r.below(2)               // 2..3
	base := (2 + r.below(3)) * 128 * 1024 // 256/384/512 KiB
	var blocks [][]byte
	for j := 0; j < steps; j++ {
		sz := base * (j + 1)
		b := make([]byte, sz)
		b[0] = byte(j + 1)
		b[len(b)-1] = byte(j + 0x40)
		blocks = append(blocks, b)
	}
	runtime.GC()
	for j, b := range blocks {
		if b[0] != byte(j+1) || b[len(b)-1] != byte(j+0x40) {
			return itoa(steps) + " steps", "growth block " + itoa(j) + " corrupted"
		}
	}
	return "steps=" + itoa(steps) + " top=" + itoa(steps*int(base)/1024) + "KiB", ""
}

// phaseChurn: goroutine exec/exit churn — create/execute/exit batches of
// goroutines whose deeper recursion crosses the initial stack (morestack
// path) and whose exits recycle through the gfree list.
func phaseChurn(r *strng) (string, string) {
	g := 20 + r.below(41)
	depth := 4 + r.below(45)
	var wg sync.WaitGroup
	var counter uint64
	wg.Add(g)
	for i := 0; i < g; i++ {
		go func(k int) {
			defer wg.Done()
			if k%5 == 0 {
				runtime.Gosched()
			}
			d := depth + (k % 3) - 1
			_ = churnFrame(d, byte(k))
			atomic.AddUint64(&counter, 1)
		}(i)
	}
	wg.Wait()
	if counter != uint64(g) {
		return itoa(g) + " goroutines", "churn counter mismatch"
	}
	return "g=" + itoa(g) + " depth=" + itoa(depth), ""
}

func churnFrame(k int, seed byte) int {
	var buf [48]byte
	buf[0] = seed
	buf[47] = seed ^ byte(k)
	if k <= 0 {
		return int(buf[0]) + int(buf[47])
	}
	return churnFrame(k-1, seed+1) + int(buf[0])
}

// strng: a splitmix64 stream — the fixture's only randomness source.
// Explicitly seeded (M70a D1), no wall-clock or host entropy anywhere.
type strng struct{ s uint64 }

const strngGolden = 0x9E3779B97F4A7C15

func (r *strng) next() uint64 {
	r.s += strngGolden
	z := r.s
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

// below returns the next draw in [0, n) for n > 0.
func (r *strng) below(n int) int {
	return int(r.next() % uint64(n))
}

// parseSeed accepts a decimal or 0x-prefixed hex integer.
func parseSeed(s string) (uint64, bool) {
	base := uint64(10)
	if len(s) > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		base = 16
		s = s[2:]
	}
	if len(s) == 0 || len(s) > 20 {
		return 0, false
	}
	var v uint64
	for i := 0; i < len(s); i++ {
		c := s[i]
		var d uint64
		switch {
		case c >= '0' && c <= '9':
			d = uint64(c - '0')
		case base == 16 && c >= 'a' && c <= 'f':
			d = uint64(c-'a') + 10
		case base == 16 && c >= 'A' && c <= 'F':
			d = uint64(c-'A') + 10
		default:
			return 0, false
		}
		if d >= base {
			return 0, false
		}
		// Overflow check strong enough for the full uint64 range: if
		// v*base+d would wrap, refuse rather than accept a wrapped seed.
		if v > (^uint64(0)-d)/base {
			return 0, false
		}
		v = v*base + d
	}
	return v, true
}

const hexDigits = "0123456789abcdef"

func utoh(v uint64) string {
	if v == 0 {
		return "0"
	}
	var buf [16]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = hexDigits[v&0xF]
		v >>= 4
	}
	return string(buf[i:])
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
