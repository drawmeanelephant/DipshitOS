// fcntl for GOOS=virelai.
//
// There is no fcntl slot at EL0, so nothing here forwards anywhere. Why this
// file is not simply "everything ENOSYS":
//
//	os/file_unix.go's newFileFromNewFile calls Fcntl(fd, F_GETFL, 0) to learn
//	whether the descriptor it was handed is append-mode and non-blocking. It
//	tolerates an error, but the answer it wants is knowable: the syscall
//	package records the flags each handle was opened with. So F_GETFL answers
//	from that record — a derivation, not a syscall — and F_SETFL is accepted
//	and ignored, because there is nothing to set (the kernel has one read
//	mode and append lives in the open flags).
//
// Everything else is ENOSYS, which is what a caller can act on.
package unix

import "syscall"

func Fcntl(fd int, cmd int, arg int) (int, error) {
	switch cmd {
	case syscall.F_GETFL:
		return syscall.OpenFlags(fd), nil
	case syscall.F_SETFL:
		return 0, nil
	}
	return -1, syscall.ENOSYS
}

// IsNonblock: F_GETFL's answer never carries O_NONBLOCK, and the kernel's
// reads are synchronous and level-triggered, so every handle is blocking.
func IsNonblock(fd int) (nonblocking bool, err error) { return false, nil }

func HasNonblockFlag(flag int) bool { return flag&syscall.O_NONBLOCK != 0 }
