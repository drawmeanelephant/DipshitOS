package vsys

import "testing"

// fakeKernel swaps the package's SVC gateway for the duration of one test, so
// the marshalling contract can be asserted off the guest. Every test restores
// the real one.
func fakeKernel(t *testing.T, fn func(num uintptr, a0, a1, a2, a3 uintptr) int64) {
	t.Helper()
	prev := syscallFn
	syscallFn = fn
	t.Cleanup(func() { syscallFn = prev })
}

// ClipboardMax is the console staging buffer's size, NOT the kernel's 512-byte
// buffer bound. Both halves of that matter: the wrappers stage through memory
// the kernel's uaccess check accepts, and they add no data-segment bytes of
// their own — see clipboard.go for why bytes there are a correctness budget for
// a GOOS=virelai image rather than a style preference.
func TestClipboardMaxIsTheStagingBound(t *testing.T) {
	if ClipboardMax != len(virConsoleStaging) {
		t.Fatalf("ClipboardMax = %d want the staging buffer's %d", ClipboardMax, len(virConsoleStaging))
	}
	if ClipboardMax <= 0 {
		t.Fatal("ClipboardMax must be positive")
	}
}

// ClipboardSet stages the body and passes slot 38 the STAGED length: an
// over-long body is truncated at the bound rather than handed to the kernel as a
// longer length, and the rc it returns is the kernel's, not a fabricated
// success.
func TestClipboardSetStagesAndTruncates(t *testing.T) {
	var gotSlot, gotLen uintptr
	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotSlot, gotLen = num, a1
		return 11
	})

	body := []byte("hello world")
	n, rc := ClipboardSet(body)
	if gotSlot != SlotClipboardSet {
		t.Fatalf("ClipboardSet called slot %d want %d", gotSlot, SlotClipboardSet)
	}
	if gotLen != 11 {
		t.Fatalf("ClipboardSet passed len %d want 11", gotLen)
	}
	// The bytes must be in the staging buffer: a stack slice lives in the sbrk
	// heap, which the kernel's uaccess check would refuse.
	if string(virConsoleStaging[:11]) != "hello world" {
		t.Fatalf("staging = %q want %q", virConsoleStaging[:11], "hello world")
	}
	if n != 11 || rc != 11 {
		t.Fatalf("ClipboardSet = (%d,%d) want (11,11)", n, rc)
	}

	long := make([]byte, ClipboardMax+64)
	for i := range long {
		long[i] = 'x'
	}
	ClipboardSet(long)
	if gotLen != uintptr(ClipboardMax) {
		t.Fatalf("over-long set passed len %d want the bound %d", gotLen, ClipboardMax)
	}

	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -ErrEINVAL })
	if n, rc := ClipboardSet(body); n != 0 || rc != -ErrEINVAL {
		t.Fatalf("refused ClipboardSet = (%d,%d) want (0,%d)", n, rc, -ErrEINVAL)
	}
}

// ClipboardGet reads slot 39 into the staging buffer and copies out a body the
// caller owns; an empty clipboard is (nil, 0), and max above the bound clamps.
func TestClipboardGetCopiesOut(t *testing.T) {
	var gotSlot, gotLen uintptr
	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotSlot, gotLen = num, a1
		copy(virConsoleStaging[:11], "hello world")
		return 11
	})

	body, rc := ClipboardGet(ClipboardMax)
	if gotSlot != SlotClipboardGet {
		t.Fatalf("ClipboardGet called slot %d want %d", gotSlot, SlotClipboardGet)
	}
	if gotLen != uintptr(ClipboardMax) {
		t.Fatalf("ClipboardGet passed max %d want %d", gotLen, ClipboardMax)
	}
	if string(body) != "hello world" || rc != 11 {
		t.Fatalf("ClipboardGet = (%q,%d) want (%q,11)", body, rc, "hello world")
	}

	// max is clamped to the bound the staging buffer actually has.
	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { gotLen = a1; return 0 })
	if body, rc := ClipboardGet(ClipboardMax * 4); body != nil || rc != 0 {
		t.Fatalf("empty ClipboardGet = (%q,%d) want (nil,0)", body, rc)
	}
	if gotLen != uintptr(ClipboardMax) {
		t.Fatalf("over-max get passed %d want the clamp %d", gotLen, ClipboardMax)
	}

	// A refusal is the kernel's rc with no body, never a silent empty one.
	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -ErrEINVAL })
	if body, rc := ClipboardGet(8); body != nil || rc != -ErrEINVAL {
		t.Fatalf("refused ClipboardGet = (%q,%d) want (nil,%d)", body, rc, -ErrEINVAL)
	}
}
