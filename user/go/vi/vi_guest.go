//go:build virelai

package vi

import "unsafe"

// The assembly gateway (vi_arm64.s).
func syscall0(num uintptr) int64
func syscall1(num uintptr, a0 uintptr) int64
func syscall2(num uintptr, a0, a1 uintptr) int64
func syscall3(num uintptr, a0, a1, a2 uintptr) int64
func syscall4(num uintptr, a0, a1, a2, a3 uintptr) int64
func syscall6(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64

// The runtime exports the exec argv/envp it received (the same accessor
// os.Args will use once the phase-2 os port lands).
//
//go:linkname runtimeArgs runtime.VirelaiArgs
func runtimeArgs() []string

// MmapAnon reserves size bytes of anonymous read/write memory (sys_mmap
// slot 63). The handle address is the kernel's own mapping base.
func MmapAnon(size int) ([]byte, error) {
	if size <= 0 {
		return nil, errno(ErrEINVAL)
	}
	n := (size + PageSize - 1) &^ (PageSize - 1)
	r := syscall4(SlotMmap, 0, uintptr(n), uintptr(ProtRead|ProtWrite),
		uintptr(MapAnonymous|MapPrivate|MapPopulate))
	if r < 0 {
		return nil, errno(-r)
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(uintptr(r))), n), nil
}

//go:linkname runtimeNanos runtime.nanotime
func runtimeNanos() int64

// Nanos is the guest monotonic clock in nanoseconds (the runtime's CNTPCT_EL0
// read: no syscall, no allocation, safe on any path).
func Nanos() int64 { return runtimeNanos() }

// Args returns the program's arguments (argv[0] is the program name).
func Args() []string {
	if runtimeArgs == nil {
		return nil
	}
	return runtimeArgs()
}

// mmapSlice turns a kernel sys_mmap result (the mapping base address) into a
// byte slice of n bytes. Guest-only: the address came from the syscall, and
// this is the one place the uintptr->slice cast lives, behind the virelai
// build tag so host `go vet` never sees unsafe.Pointer(uintptr(...)).
func mmapSlice(base uintptr, n int) []byte {
	return unsafe.Slice((*byte)(unsafe.Pointer(base)), n)
}
