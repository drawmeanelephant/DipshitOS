//go:build !virelai

package vsys

// Host fallbacks: every call reports "no such call" (-ENOSYS) and no device
// is touched, so the package's own logic stays testable off the guest.

func rawSyscall(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -ErrENOSYS }

func slicePtr(p []byte) uintptr { return 0 }

func strPtr(b []byte) uintptr { return 0 }
