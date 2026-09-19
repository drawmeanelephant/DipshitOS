package vi

import (
	"errors"
	"testing"
	"unsafe"
)

// TestPipeRoundTrip pins the sequential hand-off the shell's `|` performs:
// one write of the left capture, one read draining it back.
func TestPipeRoundTrip(t *testing.T) {
	var written []byte
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotPipeWrite:
			b := unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1)
			written = append(written, b...)
			return int64(len(b))
		case SlotPipeRead:
			buf := unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1)
			n := copy(buf, written)
			return int64(n)
		}
		t.Fatalf("unexpected slot %d", num)
		return 0
	})
	n, err := PipeWrite([]byte("alpha-beta"))
	if err != nil || n != 10 {
		t.Fatalf("PipeWrite = (%d, %v), want (10, nil)", n, err)
	}
	buf := make([]byte, 64)
	n, err = PipeRead(buf)
	if err != nil || string(buf[:n]) != "alpha-beta" {
		t.Fatalf("PipeRead = (%q, %v), want alpha-beta", buf[:n], err)
	}
}

// TestPipeEmptyRead pins the non-blocking empty row: read returns (0, nil).
func TestPipeEmptyRead(t *testing.T) {
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotPipeRead {
			t.Fatalf("unexpected slot %d", num)
		}
		return 0
	})
	n, err := PipeRead(make([]byte, 16))
	if err != nil || n != 0 {
		t.Fatalf("empty PipeRead = (%d, %v), want (0, nil)", n, err)
	}
}

// TestPipeRefusals pins the kernel's edge rows: oversize write is EINVAL,
// a kernel ENOSPC maps through, and a zero-length write is a local no-op.
func TestPipeRefusals(t *testing.T) {
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return -ErrENOSPC
	})
	if _, err := PipeWrite(make([]byte, PipeCapacity+1)); !errors.Is(err, errno(ErrEINVAL)) {
		t.Fatalf("oversize PipeWrite err = %v, want EINVAL", err)
	}
	if _, err := PipeWrite([]byte("x")); !errors.Is(err, errno(ErrENOSPC)) {
		t.Fatalf("PipeWrite err = %v, want ENOSPC", err)
	}
	if n, err := PipeWrite(nil); n != 0 || err != nil {
		t.Fatalf("nil PipeWrite = (%d, %v), want (0, nil)", n, err)
	}
	if n, err := PipeRead(nil); n != 0 || err != nil {
		t.Fatalf("nil PipeRead = (%d, %v), want (0, nil)", n, err)
	}
}
