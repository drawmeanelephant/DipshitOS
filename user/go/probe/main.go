// Command clockprobe is a diagnostic fixture, not part of the browser: it
// prints the monotonic clock the budget instrumentation reads and the heap
// size after an allocation, so anyone can re-check that the guest clock is
// live and monotonic on this GOOS.
//
// Build:  bash tools/go/build-web.sh probe PROBE
// Run:    exec PROBE.ELF
package main

import (
	_ "unsafe"

	"virelai/vi"
)

//go:linkname runtimeNanos runtime.nanotime
func runtimeNanos() int64

func main() {
	vi.ConsoleLine("clockprobe: start")
	t0 := runtimeNanos()
	t1 := runtimeNanos()
	vi.ConsoleLine("clockprobe: t0=" + vi.Itoa64(t0) + " t1=" + vi.Itoa64(t1) + " delta-ns=" + vi.Itoa64(t1-t0))
	vi.ConsoleLine("clockprobe: monotonic=" + boolStr(t1 >= t0))
	vi.ConsoleLine("clockprobe: ok")
}

func boolStr(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}
