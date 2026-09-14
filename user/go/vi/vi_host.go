//go:build !virelai

package vi

// Host fallbacks: the app's logic stays buildable and testable off the guest.
// Every syscall reports "no such call" (-ENOSYS) and nothing touches a device.

func syscall0(num uintptr) int64                                 { return -ErrENOSYS }
func syscall1(num uintptr, a0 uintptr) int64                     { return -ErrENOSYS }
func syscall2(num uintptr, a0, a1 uintptr) int64                 { return -ErrENOSYS }
func syscall3(num uintptr, a0, a1, a2 uintptr) int64             { return -ErrENOSYS }
func syscall4(num uintptr, a0, a1, a2, a3 uintptr) int64         { return -ErrENOSYS }
func syscall6(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 { return -ErrENOSYS }

// Args is empty on the host (no exec argv block).
func Args() []string { return nil }

// MmapAnon has no meaning off the guest.
func MmapAnon(size int) ([]byte, error) { return nil, errno(ErrENOSYS) }
