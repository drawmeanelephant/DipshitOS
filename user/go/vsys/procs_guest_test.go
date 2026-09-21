//go:build virelai

package vsys

import (
	"testing"
	"unsafe"
)

func putU64le(b []byte, v uint64) {
	for i := 0; i < 8; i++ {
		b[i] = byte(v >> (8 * i))
	}
}

func swapSyscallFn(t *testing.T, fn func(num uintptr, a0, a1, a2, a3 uintptr) int64) {
	t.Helper()
	prev := syscallFn
	syscallFn = fn
	t.Cleanup(func() { syscallFn = prev })
}

// TestProcsDecodesRows pins the 40-byte wire layout against a fake kernel:
// the decoder must read pid@0, state@8, exit@16, name[16]@24 little-endian,
// mirroring vi.ProcRow field-for-field (vi's TestProcRowLayout pins the same
// layout on the host side).
func TestProcsDecodesRows(t *testing.T) {
	raw := make([]byte, 2*ProcRowSize)
	putU64le(raw[0:], 7)
	putU64le(raw[8:], ProcRunning)
	putU64le(raw[16:], 0)
	copy(raw[24:], "TABWM.BIN")
	putU64le(raw[40:], 42)
	putU64le(raw[48:], ProcExited)
	putU64le(raw[56:], 137)
	copy(raw[64:], "DEAD.BIN")

	swapSyscallFn(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotProcs {
			t.Errorf("syscall num = %d, want slot %d", num, SlotProcs)
			return -22
		}
		dst := unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1)
		copy(dst, raw)
		return 2 // sys_procs returns the ROW COUNT, not a byte count
	})

	rows := make([]ProcRow, 4)
	n, r := Procs(rows)
	if r != 2 || n != 2 {
		t.Fatalf("Procs = (%d,%d), want (2,2)", n, r)
	}
	if rows[0].PID != 7 || rows[0].State != ProcRunning || rows[0].Name() != "TABWM.BIN" {
		t.Fatalf("row 0 = %+v name %q", rows[0], rows[0].Name())
	}
	if rows[1].PID != 42 || rows[1].State != ProcExited || rows[1].ExitStatus != 137 || rows[1].Name() != "DEAD.BIN" {
		t.Fatalf("row 1 = %+v name %q", rows[1], rows[1].Name())
	}
}

func TestProcsKernelError(t *testing.T) {
	swapSyscallFn(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -22 })
	rows := make([]ProcRow, 4)
	if n, r := Procs(rows); n != 0 || r != -22 {
		t.Fatalf("Procs = (%d,%d), want (0,-22)", n, r)
	}
	if n, r := Procs(nil); n != 0 || r != 0 {
		t.Fatalf("Procs(nil) = (%d,%d), want (0,0)", n, r)
	}
}

func TestKillPassesSlot(t *testing.T) {
	var gotNum, gotPid uintptr
	swapSyscallFn(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotNum, gotPid = num, a0
		return 0
	})
	if r := Kill(99); r != 0 {
		t.Fatalf("Kill = %d, want 0", r)
	}
	if gotNum != SlotKill || gotPid != 99 {
		t.Fatalf("kill syscall = (slot %d, pid %d), want (slot %d, pid 99)", gotNum, gotPid, SlotKill)
	}
}

func TestVolumeFreePassesSlot(t *testing.T) {
	var gotNum, gotVol uintptr
	swapSyscallFn(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotNum, gotVol = num, a0
		return 1234
	})
	if r := VolumeFree(1); r != 1234 {
		t.Fatalf("VolumeFree = %d, want 1234", r)
	}
	if gotNum != SlotFileFree || gotVol != 1 {
		t.Fatalf("file_free syscall = (slot %d, vol %d), want (slot %d, vol 1)", gotNum, gotVol, SlotFileFree)
	}
}
