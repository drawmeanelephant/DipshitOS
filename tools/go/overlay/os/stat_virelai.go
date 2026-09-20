// fillFileStatFromSys: the one per-GOOS piece of os's FileInfo mapping.
//
// The work is small because the kernel already reports POSIX-shaped mode bits
// in its directory rows (file_table.zig: 040000|0755 for a directory,
// 0100000|0644 for a file), so this is a straight translation rather than the
// synthesis GOOS=wasip1 needs. Two honest notes:
//
//   - ModTime is the row's timestamp, which on this filesystem is the HOST
//     file's time (the share carries the host's stat through), not a guest
//     clock reading.
//   - A share entry that the kernel could not attribute (ModeSetBy == 0 in
//     the port's Stat_t) still has a mode word, so it is reported as-is
//     rather than dressed up as a file.
package os

import (
	"internal/filepathlite"
	"syscall"
	"time"
)

func fillFileStatFromSys(fs *fileStat, name string) {
	fs.name = filepathlite.Base(name)
	fs.size = fs.sys.Size
	fs.modTime = time.Unix(fs.sys.Mtim.Sec, fs.sys.Mtim.Nsec)
	fs.mode = FileMode(fs.sys.Mode & 0o777)
	switch fs.sys.Mode & syscall.S_IFMT {
	case syscall.S_IFBLK:
		fs.mode |= ModeDevice
	case syscall.S_IFCHR:
		fs.mode |= ModeDevice | ModeCharDevice
	case syscall.S_IFDIR:
		fs.mode |= ModeDir
	case syscall.S_IFIFO:
		fs.mode |= ModeNamedPipe
	case syscall.S_IFLNK:
		fs.mode |= ModeSymlink
	case syscall.S_IFREG:
		// nothing to add
	case syscall.S_IFSOCK:
		fs.mode |= ModeSocket
	}
	if fs.sys.Mode&syscall.S_ISGID != 0 {
		fs.mode |= ModeSetgid
	}
	if fs.sys.Mode&syscall.S_ISUID != 0 {
		fs.mode |= ModeSetuid
	}
	if fs.sys.Mode&syscall.S_ISVTX != 0 {
		fs.mode |= ModeSticky
	}
}

// atime is used by os's own tests (and by nothing in a build).
func atime(fi FileInfo) time.Time {
	return time.Unix(fi.Sys().(*syscall.Stat_t).Atim.Sec, fi.Sys().(*syscall.Stat_t).Atim.Nsec)
}
