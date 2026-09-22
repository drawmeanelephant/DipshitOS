package vi

import "testing"

// TestPingSendMarshalsIP pins the slot-59 argument word: the kernel takes the
// dotted quad big-endian in the low 32 bits (10.0.0.2 == 0x0a000002), exactly
// what the Zig ui.ping_send sends.
func TestPingSendMarshalsIP(t *testing.T) {
	var slot uintptr
	var arg uintptr
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		slot, arg = num, a0
		return 0
	})
	if err := PingSend([4]byte{10, 0, 0, 2}); err != nil {
		t.Fatalf("PingSend = %v", err)
	}
	if slot != SlotPingSend {
		t.Fatalf("slot = %d, want %d", slot, SlotPingSend)
	}
	if arg != 0x0a000002 {
		t.Fatalf("ip word = %#x, want 0x0a000002", arg)
	}
}

// TestPingSendRefusalIsError: the kernel's EINVAL (no own IP / ARP miss /
// not ready) must surface as an error, not a silent success.
func TestPingSendRefusalIsError(t *testing.T) {
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -ErrEINVAL })
	if err := PingSend([4]byte{10, 0, 0, 2}); err == nil {
		t.Fatal("EINVAL must surface as an error")
	}
}

// TestPingPollReturnsSequence pins slot 60: the reply's sequence number, with
// 0 meaning "nothing yet" (and an errno equally meaning nothing yet, never a
// fabricated reply).
func TestPingPollReturnsSequence(t *testing.T) {
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotPingPoll {
			t.Fatalf("slot = %d, want %d", num, SlotPingPoll)
		}
		return 7
	})
	if got := PingPoll(); got != 7 {
		t.Fatalf("PingPoll = %d, want 7", got)
	}
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 0 })
	if got := PingPoll(); got != 0 {
		t.Fatalf("no-reply PingPoll = %d, want 0", got)
	}
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -ErrENOSYS })
	if got := PingPoll(); got != 0 {
		t.Fatalf("refused PingPoll = %d, want 0", got)
	}
}
