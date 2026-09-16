//go:build virelai

package vsys

// The EL0 counter read itself (vsys_counter_arm64.s). No syscall: the
// kernel grants EL0 access to CNTPCT_EL0/CNTFRQ_EL0 at timer init.

//go:noescape
func virCounterTicks() uint64

//go:noescape
func virCounterFreq() uint64

func platformNano() int64 {
	return ticksToNanos(virCounterTicks(), virCounterFreq())
}
