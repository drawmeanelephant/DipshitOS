// The dirent parse helpers for GOOS=virelai.
//
// A row here is the kernel's own sys_dir_list record — syscall.Dirent, 40
// bytes: a 32-byte name, a 32-bit size and an is-dir bit. There is no d_type
// field and no inode number, which is why:
//
//   - direntType answers from the IsDir bit, the only file kind this
//     filesystem has (no symlinks, devices or sockets at EL0). That bit is
//     the kernel's own classification, not a guess from the name.
//   - direntIno answers 0. The port does not invent inode numbers; instead
//     os/dir_unix.go's zero-inode skip is extended to virelai (apply.sh, the
//     same way it is written for wasip1), because the row genuinely has no
//     inode to report.
package os

import (
	"syscall"
	"unsafe"
)

// rowSize is syscall.Dirent's own size (40), which the kernel's table fixes.
const rowSize = int(unsafe.Sizeof(syscall.Dirent{}))

func direntIno(buf []byte) (uint64, bool) {
	// No inode number exists in this filesystem. See the file header.
	return 0, len(buf) >= rowSize
}

func direntReclen(buf []byte) (uint64, bool) {
	// A fixed-width row, so the record length is the row length.
	return uint64(rowSize), len(buf) >= rowSize
}

func direntNamlen(buf []byte) (uint64, bool) {
	if len(buf) < rowSize {
		return 0, false
	}
	name := unsafe.Slice((*byte)(unsafe.Pointer(&buf[0])), int(unsafe.Sizeof(syscall.Dirent{}.Name)))
	for i, c := range name {
		if c == 0 {
			return uint64(i), true
		}
	}
	return uint64(len(name)), true
}

func direntType(buf []byte) FileMode {
	off := unsafe.Offsetof(syscall.Dirent{}.IsDir)
	if off >= uintptr(len(buf)) {
		return ^FileMode(0) // unknown: let the caller stat it
	}
	if buf[off] != 0 {
		return ModeDir
	}
	return 0 // a regular file, which is the only other kind here
}
