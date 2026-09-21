package vi

import "testing"

// TestKillDispatchesSlot29AndTarget pins the wire: Kill is slot 29 with the
// target pid as the single argument, and the kernel's return value is handed
// back unmangled (0 = armed, negative = the raw ADR 0007 error).
func TestKillDispatchesSlot29AndTarget(t *testing.T) {
	var gotSlot uintptr
	var gotPID uintptr
	calls := 0
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		calls++
		gotSlot, gotPID = num, a0
		if a1 != 0 || a2 != 0 || a3 != 0 {
			t.Fatalf("kill passed extra args: %d %d %d", a1, a2, a3)
		}
		return 0
	})
	if rc := Kill(7); rc != 0 {
		t.Fatalf("Kill(7) = %d, want 0 (armed)", rc)
	}
	if calls != 1 || gotSlot != SlotKill || gotPID != 7 {
		t.Fatalf("slot=%d pid=%d calls=%d, want slot=%d pid=7 calls=1", gotSlot, gotPID, calls, SlotKill)
	}
}

// TestKillSurfacesDenial pins the cross-principal path live-trust-caps
// asserts on the guest: the kernel's -EACCES (-7) is returned as-is, so the
// caller can print `err=-7` rather than inventing a reason.
func TestKillSurfacesDenial(t *testing.T) {
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -ErrEACCES })
	if rc := Kill(1); rc != -ErrEACCES {
		t.Fatalf("Kill = %d, want %d", rc, -ErrEACCES)
	}
}

// TestKillOffGuestIsENOSYS pins the host degradation every vi call shares.
func TestKillOffGuestIsENOSYS(t *testing.T) {
	if rc := Kill(1); rc != -ErrENOSYS {
		t.Fatalf("Kill off-guest = %d, want %d", rc, -ErrENOSYS)
	}
}
