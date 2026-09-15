//go:build !virelai

package vi

import "time"

func hostNanos() int64 { return time.Now().UnixNano() }

// Host fallbacks: the app's logic stays buildable and testable off the guest.
// Every syscall reports "no such call" (-ENOSYS) and nothing touches a device.

func syscall0(num uintptr) int64                                 { return -ErrENOSYS }
func syscall1(num uintptr, a0 uintptr) int64                     { return -ErrENOSYS }
func syscall2(num uintptr, a0, a1 uintptr) int64                 { return -ErrENOSYS }
func syscall3(num uintptr, a0, a1, a2 uintptr) int64             { return -ErrENOSYS }
func syscall4(num uintptr, a0, a1, a2, a3 uintptr) int64         { return -ErrENOSYS }
func syscall6(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 { return -ErrENOSYS }

// Nanos on the host is the real monotonic clock, so budget code paths stay
// testable off the guest.
func Nanos() int64 { return hostNanos() }

// Args is empty on the host (no exec argv block).
func Args() []string { return nil }

// MmapAnon has no meaning off the guest.
func MmapAnon(size int) ([]byte, error) { return nil, errno(ErrENOSYS) }

// mmapSlice has no meaning off the guest (MmapHint/MmapAnon already return
// -ENOSYS there, so no caller reaches this with a real base).
func mmapSlice(base uintptr, n int) []byte { return nil }
