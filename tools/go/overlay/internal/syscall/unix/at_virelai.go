// The *at() family and the constants `os` expects from internal/syscall/unix,
// for GOOS=virelai.
//
// `os` reaches this package for every path operation (os/root_openat.go,
// os/removeall_at.go, os/statat_unix.go, os/file_open_unix.go). There is no
// *at() slot in the kernel: a path is absolute on the share and resolution is
// the kernel's, so every wrapper below either forwards to the absolute
// syscall or refuses. dirfd arguments are honoured only for AT_FDCWD, which
// is the value std passes when it means "absolute path" — anything else would
// be a lie about relative resolution this kernel does not do.
package unix

import (
	"syscall"
)

const (
	// The kernel has no relative resolution, so these are structural: they
	// name the shapes callers pass, and every one of them is either ignored
	// (AT_SYMLINK_NOFOLLOW: no symlinks exist) or refused (a real dirfd).
	AT_FDCWD            = -0x64
	AT_SYMLINK_NOFOLLOW = 0x100
	AT_REMOVEDIR        = 0x200
	AT_EACCESS          = 0x200
	AT_SYMLINK_FOLLOW   = 0x400
	AT_NO_AUTOMOUNT     = 0x800
	UTIME_OMIT          = -0x2
)

// atOK reports whether a dirfd argument can be honoured: only AT_FDCWD can,
// because every path this kernel resolves is absolute on the share.
func atOK(dirfd int) bool { return dirfd == AT_FDCWD }

// faccessat backs Eaccess (eaccess.go). There is no access(2) slot: this
// kernel's permission gate is the M50 ownership check INSIDE the open path,
// so a pre-flight probe could only report what Open will already say, with a
// race in between. ENOSYS is the honest answer, and every caller of Eaccess
// is prepared for the syscall not to exist.
func faccessat(dirfd int, path string, mode uint32, flags int) error {
	return syscall.ENOSYS
}

func Openat(dirfd int, path string, flags int, perm uint32) (int, error) {
	if !atOK(dirfd) {
		return -1, syscall.ENOSYS
	}
	return syscall.Open(path, flags, perm)
}

func Fstatat(dirfd int, path string, stat *syscall.Stat_t, flags int) error {
	if !atOK(dirfd) {
		return syscall.ENOSYS
	}
	return syscall.Fstatat(dirfd, path, stat, flags)
}

func Unlinkat(dirfd int, path string, flags int) error {
	if !atOK(dirfd) {
		return syscall.ENOSYS
	}
	if flags&AT_REMOVEDIR != 0 {
		return syscall.Rmdir(path)
	}
	return syscall.Unlink(path)
}

func Mkdirat(dirfd int, path string, mode uint32) error {
	if !atOK(dirfd) {
		return syscall.ENOSYS
	}
	return syscall.Mkdir(path, mode)
}

func Renameat(olddirfd int, oldpath string, newdirfd int, newpath string) error {
	if !atOK(olddirfd) || !atOK(newdirfd) {
		return syscall.ENOSYS
	}
	return syscall.Rename(oldpath, newpath)
}

// The remaining *at() calls have no kernel slot at all. They are grouped so a
// reader can see the shape of what this GOOS does not have: no symlinks
// (Linkat, Symlinkat, Readlinkat), no ownership change (Fchownat), no mode
// change beyond what the create slot sets (Fchmodat), no timestamps
// (Utimensat).
func Fchownat(dirfd int, path string, uid, gid int, flags int) error { return syscall.ENOSYS }
func Fchmodat(dirfd int, path string, mode uint32, flags int) error  { return syscall.ENOSYS }
func Linkat(olddirfd int, oldpath string, newdirfd int, newpath string, flags int) error {
	return syscall.ENOSYS
}
func Symlinkat(oldpath string, newdirfd int, newpath string) error { return syscall.ENOSYS }

// Readlinkat reports EINVAL, the POSIX answer for "not a symlink", which is
// the truth for every path in this filesystem.
func Readlinkat(dirfd int, path string, buf []byte) (int, error) {
	return 0, syscall.EINVAL
}

func Utimensat(dirfd int, path string, times *[2]syscall.Timespec, flag int) error {
	return syscall.ENOSYS
}

// CopyFileRange/SupportCopyFileRange and KernelVersionGE are deliberately
// absent: nothing selects them for this GOOS (internal/poll's
// copy_file_range_unix.go is freebsd||linux, and kernel_version_ge.go is
// untagged and answers 0,0 from kernel_version_other.go). Defining them here
// would add surface no caller reaches.
