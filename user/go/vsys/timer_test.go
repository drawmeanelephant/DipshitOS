package vsys

import "testing"

// The timer seam is the half of the M14 S3 composition (user/go/compose) that
// had no host test: the composition gate proves the kernel's behaviour live,
// but the argument the wrapper passes and the rc shape it returns are a
// contract between an app and ADR 0007, and those are checkable off the guest.
// fakeKernel lives in clipboard_test.go and swaps the package's SVC gateway.

// TimerSet arms slot 40 with the caller's delay as arg0. The wrapper forwards
// the delay VERBATIM - the kernel owns the clamps (0 -> 1 tick, over-long ->
// 3600) - so a wrapper that "helpfully" adjusted it would be untestable against
// the kernel's own rules.
func TestTimerSetForwardsDelayToSlot40(t *testing.T) {
	var gotSlot, gotA0 uintptr
	calls := 0
	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotSlot, gotA0, calls = num, a0, calls+1
		return 0
	})

	if rc := TimerSet(2); rc != 0 {
		t.Fatalf("TimerSet(2) = %d want 0", rc)
	}
	if gotSlot != SlotTimerSet {
		t.Fatalf("TimerSet called slot %d want %d", gotSlot, SlotTimerSet)
	}
	if gotA0 != 2 {
		t.Fatalf("TimerSet passed delay %d want 2", gotA0)
	}

	// Re-arming is the blink's steady state: one timer in flight, replaced by
	// the next arm, never a queue. Both arms must reach the same slot.
	if rc := TimerSet(2); rc != 0 || calls != 2 {
		t.Fatalf("re-arm = (rc %d, calls %d) want (0, 2)", rc, calls)
	}

	// The zero delay is forwarded as zero; the clamp is the kernel's.
	TimerSet(0)
	if gotA0 != 0 {
		t.Fatalf("TimerSet(0) passed delay %d want 0 (the kernel clamps)", gotA0)
	}

	// A refusal is the kernel's rc, untouched.
	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -ErrEINVAL })
	if rc := TimerSet(1); rc != -ErrEINVAL {
		t.Fatalf("refused TimerSet = %d want %d", rc, -ErrEINVAL)
	}
}

// TimerCancel disarms slot 41 and returns what the kernel says: 1 when a
// pending timer was cancelled, 0 when none was armed, negative on refusal. The
// three are distinct states for the composition, so the wrapper must not
// collapse them into a bool.
func TestTimerCancelReportsTheThreeStates(t *testing.T) {
	var gotSlot uintptr
	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotSlot = num
		return 1
	})
	if rc := TimerCancel(); rc != 1 {
		t.Fatalf("TimerCancel with a pending timer = %d want 1", rc)
	}
	if gotSlot != SlotTimerCancel {
		t.Fatalf("TimerCancel called slot %d want %d", gotSlot, SlotTimerCancel)
	}

	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 0 })
	if rc := TimerCancel(); rc != 0 {
		t.Fatalf("TimerCancel with none pending = %d want 0", rc)
	}

	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -ErrEINVAL })
	if rc := TimerCancel(); rc != -ErrEINVAL {
		t.Fatalf("refused TimerCancel = %d want %d", rc, -ErrEINVAL)
	}
}

// The slot numbers are ADR 0007's frozen pair, and they are the one thing a
// drift would break silently in both apps.
func TestTimerSlotsAreTheFrozenADR0007Pair(t *testing.T) {
	if SlotTimerSet != 40 || SlotTimerCancel != 41 {
		t.Fatalf("timer slots = (%d,%d) want (40,41)", SlotTimerSet, SlotTimerCancel)
	}
}
