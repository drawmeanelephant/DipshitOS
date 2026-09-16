//go:build virelai

package vsys

import "unsafe"

// The SVC gateway (vsys_arm64.s): one svc #0, slot in x8 (ADR 0007).
func syscall4(num uintptr, a0, a1, a2, a3 uintptr) int64

func rawSyscall(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	return syscall4(num, a0, a1, a2, a3)
}

// slicePtr returns the data pointer of p. This is guest-only code (the file
// is build-tagged virelai), which is the only place an unsafe pointer cast
// belongs: the host build never sees it, so host `go vet` stays honest, and
// the guest avoids hand-marshalling a slice header in assembly (the shape
// user/go/vi/vi_guest.go uses for the same reason).
func slicePtr(p []byte) uintptr {
	if len(p) == 0 {
		return 0
	}
	return uintptr(unsafe.Pointer(&p[0]))
}

func strPtr(b []byte) uintptr { return slicePtr(b) }
