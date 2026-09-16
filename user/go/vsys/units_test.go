package vsys

import (
	"math"
	"testing"
)

// The pure/host-reachable surface that had no test before phase 2.1.

func TestItoa64(t *testing.T) {
	cases := []struct {
		in   int64
		want string
	}{
		{0, "0"},
		{-1, "-1"},
		{1, "1"},
		{42, "42"},
		{-42, "-42"},
		{math.MaxInt64, "9223372036854775807"},
		// The regression: `v = -v` overflows here and printed a bare "-".
		{math.MinInt64, "-9223372036854775808"},
	}
	for _, tc := range cases {
		if got := Itoa64(tc.in); got != tc.want {
			t.Errorf("Itoa64(%d) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestIPWord(t *testing.T) {
	if got := ipWord([4]byte{10, 0, 2, 2}); got != 0x0a000202 {
		t.Fatalf("ipWord(10.0.2.2) = %#x, want 0x0a000202 (big-endian in the low 32 bits)", got)
	}
	if got := ipWord([4]byte{255, 255, 255, 255}); got != 0xffffffff {
		t.Fatalf("ipWord(255.255.255.255) = %#x, want 0xffffffff", got)
	}
}

func TestErrnoError(t *testing.T) {
	if got := Errno(0).Error(); got != "vsys: ok" {
		t.Fatalf("Errno(0).Error() = %q, want %q", got, "vsys: ok")
	}
	if got := Errno(ErrEAGAIN).Error(); got != "vsys: kernel error 11" {
		t.Fatalf("Errno(EAGAIN).Error() = %q", got)
	}
}

func TestSyscallResult(t *testing.T) {
	if v, err := syscallResult(0); v != 0 || err != nil {
		t.Fatalf("syscallResult(0) = (%d,%v), want (0,nil)", v, err)
	}
	if v, err := syscallResult(7); v != 7 || err != nil {
		t.Fatalf("syscallResult(7) = (%d,%v), want (7,nil)", v, err)
	}
	v, err := syscallResult(-ErrETIMEDOUT)
	if v != 0 {
		t.Fatalf("syscallResult(-ETIMEDOUT) value = %d, want 0", v)
	}
	if err != Errno(ErrETIMEDOUT) {
		t.Fatalf("syscallResult(-ETIMEDOUT) err = %v, want Errno(12)", err)
	}
}

func TestDialZeroPortIsEINVAL(t *testing.T) {
	resetConn(t)
	called := false
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { called = true; return 0 })
	_, err := Dial("10.0.2.2", 0)
	if err != Errno(ErrEINVAL) {
		t.Fatalf("Dial(port 0) = %v, want Errno(EINVAL)", err)
	}
	if called {
		t.Fatal("Dial(port 0) must refuse before any syscall")
	}
}

func TestProbeReadableEAGAINMeansNoSocket(t *testing.T) {
	resetConn(t)
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotSockReady {
			return -ErrEAGAIN // the kernel owns no socket for this process
		}
		return 0
	})
	c, _ := Dial("10.0.2.2", 80)
	if _, err := c.Read(make([]byte, 4)); err != ErrConnClosed {
		t.Fatalf("Read with a lost socket = %v, want ErrConnClosed (EAGAIN maps to it)", err)
	}
}

func TestFileZeroLengthIO(t *testing.T) {
	f := &File{h: 3, open: true}
	if n, err := f.Read(nil); n != 0 || err != nil {
		t.Fatalf("File.Read(nil) = (%d,%v), want (0,nil)", n, err)
	}
	if n, err := f.Write(nil); n != 0 || err != nil {
		t.Fatalf("File.Write(nil) = (%d,%v), want (0,nil)", n, err)
	}
	if _, err := f.Read(make([]byte, 4)); err == nil {
		// No fake kernel installed here: the host stub is -ENOSYS, so a
		// non-empty read must surface an error rather than silently pass.
		t.Fatal("File.Read on the -ENOSYS host stub must return an error")
	}
}

func TestFileReadClampsToMaxIO(t *testing.T) {
	var asked uintptr
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotFileRead {
			asked = a2
			return 1
		}
		return 0
	})
	f := &File{h: 3, open: true}
	n, err := f.Read(make([]byte, MaxFileIOBytes+500))
	if err != nil || n != 1 {
		t.Fatalf("File.Read = (%d,%v), want (1,nil)", n, err)
	}
	if asked != MaxFileIOBytes {
		t.Fatalf("File.Read asked the kernel for %d bytes, want %d", asked, MaxFileIOBytes)
	}
}

func TestPrintTruncatesAt256(t *testing.T) {
	var sent uintptr
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotWrite {
			sent = a2
		}
		return 0
	})
	Print(string(make([]byte, 300)))
	if sent != 256 {
		t.Fatalf("Print sent %d bytes, want 256 (the kernel's per-write cap)", sent)
	}
}
