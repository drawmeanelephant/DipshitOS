// GOOS=virelai first target (issue #1163, phase 0a).
//
// Exercises the whole phase-0a runtime surface: the svc-based console
// (println -> gwrite -> write1 -> sys_write chunking), the sbrk heap over
// sys_mmap (a 1 MiB allocation forces heap growth), and a full GC cycle
// (STW at cooperative safe points, mark, sweep through the sbrk free
// list). Zero standard-library OS imports — runtime only.
package main

import "runtime"

func main() {
	println("hello from virelai")
	println("GOOS=virelai GOARCH=arm64 gc runtime alive")

	// Heap growth: 1 MiB forces sbrk() past the first kernel mmap chunk.
	big := make([]byte, 1<<20)
	for i := 0; i < len(big); i += 4096 {
		big[i] = byte(i >> 12)
	}
	println("heap: wrote", len(big), "bytes, spot check", big[40960])

	// Allocation churn + explicit GC: exercises mallocgc, write barriers,
	// STW at cooperative safe points, and the sweep path.
	var keep []byte
	for i := 0; i < 50; i++ {
		keep = make([]byte, 64*1024)
		keep[0] = byte(i)
		_ = keep
	}
	runtime.GC()
	println("gc: cycle completed")

	sum := 0
	for _, v := range big {
		sum += int(v)
	}
	println("post-gc readback sum:", sum)
	println("virelai-go OK")
}
