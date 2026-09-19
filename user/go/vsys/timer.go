package vsys

// Milestone 14 (claim 7323): the bounded per-process application timer. The
// slot numbers are ADR 0007's; the single source is kernel/src/syscall.zig
// (sys_timer_set = 40, sys_timer_cancel = 41).
//
// The facility exists so an app can stop spinning a sys_sleep loop: one timer
// per process, armed to post a TIMER event (kind 9, vi.EvTimer) into the
// process's own ADR 0009 queue after delay_ticks SCHEDULER ticks — the
// sys_sleep clock, 1 s on VZ.
const (
	// SlotTimerSet is sys_timer_set(delay_ticks) — arm the caller's ONE app
	// timer. delay_ticks 0 clamps to 1 (the sys_sleep minimum) and an
	// over-long delay truncates at the kernel's 3600-tick bound.
	SlotTimerSet uintptr = 40
	// SlotTimerCancel is sys_timer_cancel() — disarm it: 1 when a pending
	// timer was cancelled, 0 when none was armed.
	SlotTimerCancel uintptr = 41
)

// TimerSet arms the calling process's app timer (slot 40) and returns the raw
// kernel result: 0 armed, a negative errno otherwise (EINVAL for a non-process
// caller). Re-arming REPLACES any pending timer, so a blink that re-arms after
// every event runs with exactly one timer in flight — never an accumulating
// queue of them.
func TimerSet(delayTicks uint64) int64 {
	return syscallFn(SlotTimerSet, uintptr(delayTicks), 0, 0, 0)
}

// TimerCancel disarms the calling process's app timer (slot 41) and returns
// the raw kernel result: 1 cancelled, 0 none pending, a negative errno
// otherwise.
func TimerCancel() int64 {
	return syscallFn(SlotTimerCancel, 0, 0, 0, 0)
}
