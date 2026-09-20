// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

// The GOOS=virelai file surface (issue #1525, M70c-S1P): the calls `os` and
// `internal/poll` make, mapped onto ADR 0007's file slots.
//
// The shape of the mapping, and why it is not a POSIX emulation:
//
//   - **Handles are the kernel's** (8 per process, slots 23-26/34-36/77).
//     A handle carries a cursor; there is no pread/pwrite, so this is a
//     sequential port and Seek reports ENOSYS instead of pretending.
//   - **Directories are not handles.** sys_dir_list takes a PATH plus a row
//     buffer, so `Open` on a directory returns a synthetic fd from
//     `dirFdBase` and ReadDirent resolves it back to the path. A caller
//     therefore cannot `Write` a directory fd (EISDIR) or rely on its
//     number being small — internal/poll only ever passes it back.
//   - **A handle's size is not reportable.** The kernel knows it (the host
//     STAT fills h.size at open) but exposes no query, so Stat/Fstat answer
//     from a `sys_dir_list` row on the entry's parent, using the path the
//     port remembers for each handle. That is why Open records paths.
//   - **The listing window is 16 rows, with no offset** (handle_dir_list
//     clamps max_entries and always starts at the first entry). A directory
//     with more than 16 entries is therefore NOT enumerable at EL0 through
//     any seam that exists today; this port delivers the window and then
//     says so (ENOSPC) rather than returning a plausible partial list.
//     Closing that is a kernel change (a listing cursor on slot 27), not a
//     port change — filed against #1525.
package syscall

import "unsafe"

// dirFdBase is where synthetic directory fds start. It is above any real
// handle (the kernel's table is 8 entries) and above 0/1/2, so no caller can
// confuse the two, and `internal/poll` never interprets the value.
const dirFdBase = 1 << 20

type dirHandle struct {
	path   string // the share path this fd lists
	live   bool
	rows   int // rows already delivered
	sat    bool // the last window filled completely (there may be more)
}

var virDirs [8]dirHandle

// virFdPaths remembers what each real handle was opened with, because the
// kernel reports neither a handle's path nor its size. Index = the kernel's
// fd (its table is 8 entries per process).
var virFdPaths [8]string

// virFdFlags remembers the POSIX flag word of each handle. Nothing in the
// kernel can be asked for it: there is no fcntl slot, and os/file_unix.go's
// NewFile wants an answer to F_GETFL all the same (append mode, blocking).
// Recording it at Open is what makes that answer a derivation instead of a
// guess — see OpenFlags and internal/syscall/unix's Fcntl.
var virFdFlags [8]int

func rememberFd(fd int, path string, flags int) {
	if fd >= 0 && fd < len(virFdPaths) {
		virFdPaths[fd] = path
		virFdFlags[fd] = flags
	}
}

// OpenFlags returns the POSIX flag word a handle was opened with, or 0 for a
// handle this layer did not open (the console, a synthetic directory fd).
func OpenFlags(fd int) int {
	if fd >= 0 && fd < len(virFdFlags) {
		return virFdFlags[fd]
	}
	return 0
}

func fdPath(fd int) (string, bool) {
	if fd >= 0 && fd < len(virFdPaths) {
		if p := virFdPaths[fd]; p != "" {
			return p, true
		}
	}
	return "", false
}

// dirFdFor returns the entry for a synthetic fd, or ok=false.
func dirFdFor(fd int) (int, bool) {
	i := fd - dirFdBase
	if i < 0 || i >= len(virDirs) || !virDirs[i].live {
		return 0, false
	}
	return i, true
}

// ----- the dirent record ---------------------------------------------------

// Dirent is the kernel's own sys_dir_list row (file_table.DirEntry),
// exposed verbatim as this GOOS's directory record: name[32] NUL-padded,
// size, an is-dir byte, three reserved bytes. Reusing the row means
// ReadDirent is a copy, not a translation, and the parse side (dirent.go's
// direntReclen/direntIno/direntNamlen, below) reads the same numbers the
// kernel wrote.
type Dirent struct {
	Name     [32]byte
	Size     uint32
	IsDir    uint8
	Reserved [3]byte
}

const direntSize = int(unsafe.Sizeof(Dirent{})) // 40

func direntReclen(buf []byte) (uint64, bool) { return uint64(direntSize), len(buf) >= direntSize }

// direntIno has no kernel source: the share has no inode numbers. Reporting
// 0 (rather than a hash that looks like an identity) keeps a caller from
// caching on a value that means nothing.
func direntIno(buf []byte) (uint64, bool) { return 0, len(buf) >= direntSize }

func direntNamlen(buf []byte) (uint64, bool) {
	if len(buf) < direntSize {
		return 0, false
	}
	d := (*Dirent)(unsafe.Pointer(&buf[0]))
	for i := 0; i < len(d.Name); i++ {
		if d.Name[i] == 0 {
			return uint64(i), true
		}
	}
	return uint64(len(d.Name)), true
}

func direntType(buf []byte) (uint8, bool) {
	if len(buf) < direntSize {
		return 0, false
	}
	d := (*Dirent)(unsafe.Pointer(&buf[0]))
	if d.IsDir != 0 {
		return 4, true // DT_DIR
	}
	return 8, true // DT_REG
}

// ----- the file calls ------------------------------------------------------

// Open opens path (the kernel word is built by kernelOpenFlags above; it is
// NOT the POSIX block). A read-only open of a directory yields a
// synthetic fd that ReadDirent can list; every other open is the kernel's.
// The KERNEL's own open flag word (kernel/src/file_table.zig MODE_*). It is
// NOT the POSIX block above: MODE_READ is 0x1, there is no zero-valued
// "read" (the kernel refuses flags == 0 outright), the create/append/dir
// bits are small and packed, and any bit outside the five is refused with
// EINVAL. Getting this wrong is the one translation error the port cannot
// paper over, so the two words live apart and the names never collide.
const (
	kmodeRead   = 0x1
	kmodeWrite  = 0x2
	kmodeCreate = 0x4
	kmodeAppend = 0x8
	kmodeDir    = 0x10
)

// kernelOpenFlags translates the POSIX word Open is handed into the kernel's
// MODE_* bits, and reports the two flags the kernel's open slot cannot carry:
// truncation (its own slot) and O_EXCL (checked by the caller).
//
// Unmappable bits are dropped rather than refused: O_CLOEXEC has no meaning
// at EL0 (no exec inheritance), O_NONBLOCK is already the kernel's only read
// mode, and O_NOFOLLOW/O_DIRECTORY are unobservable because no symlinks
// exist here. O_EXCL is the one that would be dishonest to drop.
func kernelOpenFlags(mode int) (kernel uint32, trunc, excl bool) {
	switch mode & (O_WRONLY | O_RDWR) {
	case O_WRONLY:
		kernel = kmodeWrite
	case O_RDWR:
		kernel = kmodeRead | kmodeWrite
	default:
		// POSIX O_RDONLY is 0: a zero word is the read-only open, and the
		// kernel's MODE_READ is what it has to become. Passing the POSIX 0
		// through is the mistake this function exists to prevent.
		kernel = kmodeRead
	}
	if mode&O_CREAT != 0 {
		kernel |= kmodeCreate
	}
	if mode&O_APPEND != 0 {
		kernel |= kmodeAppend
	}
	if mode&O_DIRECTORY != 0 {
		kernel |= kmodeDir
	}
	return kernel, mode&O_TRUNC != 0, mode&O_EXCL != 0
}

func Open(path string, mode int, perm uint32) (fd int, err error) {
	flags, trunc, excl := kernelOpenFlags(mode)
	if excl && flags&kmodeCreate != 0 {
		// Not atomic: the open slot has no exclusive-create mode, so the
		// refusal is a probe followed by the create. Named as a gap in the
		// port's header rather than left silent.
		if virPathExists(path) {
			return -1, EEXIST
		}
	}


	// Directory probe. Read-only opens only: a write/create open of a
	// directory is the kernel's business (MODE_DIR creation). The probe
	// cannot produce a wrong answer — any failure falls through to the real
	// open — and it is one syscall, which is cheaper than the ambiguity of
	// a dir handle that reads as empty. `flags` here is already the kernel
	// word, so the comparison is against MODE_READ/MODE_DIR, not O_RDONLY.
	if flags == kmodeRead || flags == (kmodeRead|kmodeDir) {
		if isDir(path) {
			return newDirFd(path)
		}
	}

	n := stagedAbs(path)
	if n < 0 {
		if len(path) > virPathMax {
			return -1, ENAMETOOLONG
		}
		return -1, EINVAL
	}
	r := svc3(virSysFileOpen, uintptr(unsafe.Pointer(&virPathStaging[0])), uintptr(n), uintptr(flags))
	if r < 0 {
		return -1, errnoErr(errOf(r))
	}
	fd = int(r)
	rememberFd(fd, path, mode)
	// O_TRUNC needs no second call: the kernel's write-open WITHOUT
	// MODE_APPEND already has replace semantics (file_table.open: "a fresh
	// write-open truncates"), so the open itself emptied the file. Calling the
	// port's by-path Truncate here is what made every os.WriteFile fail with
	// ENOSYS — that function is an honest refusal (slot 36 is
	// handle-addressed), and this route never needed it.
	_ = trunc
	return fd, nil
}

// Openat ignores dirfd: this kernel has no relative resolution (every path
// is absolute on the share), so treating a relative path as absolute would
// be a lie. Callers that pass a real dirfd get ENOSYS.
func Openat(dirfd int, path string, mode int, perm uint32) (fd int, err error) {
	if _, ok := dirFdFor(dirfd); ok {
		return -1, ENOSYS
	}
	if dirfd != AT_FDCWD {
		return -1, ENOSYS
	}
	return Open(path, mode, perm)
}

const (
	AT_FDCWD = -0x64
	AT_SYMLINK_NOFOLLOW = 0x100 // accepted and ignored: no symlinks exist
)

func newDirFd(path string) (int, error) {
	for i := range virDirs {
		if !virDirs[i].live {
			virDirs[i] = dirHandle{path: path, live: true}
			return dirFdBase + i, nil
		}
	}
	return -1, EMFILE
}

// Fchdir sets the working directory from an open handle. The kernel has no
// fchdir slot — the working directory is per-process kernel state set by
// PATH (sys_chdir) — so the port answers from the path it remembered for the
// handle at open, and, for a synthetic directory fd, from the path that fd
// was created to list. A handle this layer did not open has no path to give
// and is reported as EBADF, which is what a caller can act on.
func Fchdir(fd int) error {
	if i, ok := dirFdFor(fd); ok {
		return Chdir(virDirs[i].path)
	}
	if p, ok := fdPath(fd); ok {
		return Chdir(p)
	}
	return EBADF
}

// virPathExists reports whether a share entry with this name exists, through
// the same route Stat takes: there is no stat-by-name slot, so existence is
// learned from a directory row on the entry's parent.
func virPathExists(path string) bool {
	_, err := statPath(path)
	return err == nil
}

// isDir reports whether path is a directory by trying to list it. Any
// failure means "not a directory as far as this kernel can tell".
func isDir(path string) bool {
	n := stagedAbs(path)
	if n < 0 {
		return false
	}
	var row [direntSize]byte
	r := svc4(virSysDirList, uintptr(unsafe.Pointer(&virPathStaging[0])), uintptr(n),
		uintptr(unsafe.Pointer(&row[0])), 1)
	return r >= 0
}

// Read moves up to one kernel read into p. The kernel clamps a call to
// 2048 bytes, so a short read is normal and is not an error (only writing
// can lose data). A zero return means EOF: the kernel's read is
// level-triggered at the handle's cursor and reports 0 at the end.
func Read(fd int, p []byte) (n int, err error) {
	if _, ok := dirFdFor(fd); ok {
		return 0, EISDIR
	}
	if len(p) == 0 {
		return 0, nil
	}
	if len(p) > virIOChunkMax {
		p = p[:virIOChunkMax]
	}
	r := svc3(virSysRead, uintptr(fd), uintptr(unsafe.Pointer(&p[0])), uintptr(len(p)))
	if r < 0 {
		return 0, errnoErr(errOf(r))
	}
	return int(r), nil
}

// Write moves up to one kernel write and reports the short write, which is
// what the raw contract (and internal/poll's completion loop) expects.
//
// fd 1 and fd 2 are the CONSOLE, not the file channel. The kernel's
// sys_write (slot 1) writes straight to the monitor console, accepts only
// fd 1, and is capped at write_cap (256). std's os.Stdout/os.Stderr live on
// exactly those numbers and there is no /dev/stdout to open instead, so a
// console write is what they have to resolve to. fd 2 is mapped onto the
// console's single stream rather than refused: a guest writing to stderr
// should be seen, and the kernel has one stream to be seen on.
//
// Every other fd is a file-channel handle (slot 25, capped at 2048).
func Write(fd int, p []byte) (n int, err error) {
	if _, ok := dirFdFor(fd); ok {
		return 0, EISDIR
	}
	if len(p) == 0 {
		return 0, nil
	}
	if fd == 1 || fd == 2 {
		if len(p) > virConsoleWriteMax {
			p = p[:virConsoleWriteMax]
		}
		r := svc3(virSysConsoleWrite, uintptr(1), uintptr(unsafe.Pointer(&p[0])), uintptr(len(p)))
		if r < 0 {
			return 0, errnoErr(errOf(r))
		}
		return int(r), nil
	}
	if len(p) > virIOChunkMax {
		p = p[:virIOChunkMax]
	}
	r := svc3(virSysWrite, uintptr(fd), uintptr(unsafe.Pointer(&p[0])), uintptr(len(p)))
	if r < 0 {
		return 0, errnoErr(errOf(r))
	}
	return int(r), nil
}

func Close(fd int) error {
	if i, ok := dirFdFor(fd); ok {
		virDirs[i] = dirHandle{}
		return nil
	}
	r := svc1(virSysClose, uintptr(fd))
	if fd >= 0 && fd < len(virFdPaths) {
		virFdPaths[fd] = ""
		virFdFlags[fd] = 0
	}
	if r < 0 {
		return errnoErr(errOf(r))
	}
	return nil
}

// Fsync pushes the handle's bytes to the host device (slot 77). A stateless
// read handle is an honest no-op in the kernel.
func Fsync(fd int) error {
	if _, ok := dirFdFor(fd); ok {
		return nil
	}
	r := svc1(virSysFileSync, uintptr(fd))
	if r < 0 {
		return errnoErr(errOf(r))
	}
	return nil
}

// Ftruncate resizes an OPEN handle (slot 36). The kernel requires a write
// handle for it.
func Ftruncate(fd int, length int64) error {
	if _, ok := dirFdFor(fd); ok {
		return EISDIR
	}
	if length < 0 || length > 0xffffffff {
		return EINVAL
	}
	r := svc2(virSysTruncate, uintptr(fd), uintptr(length))
	if r < 0 {
		return errnoErr(errOf(r))
	}
	return nil
}

// Truncate is not available by path: slot 36 is handle-addressed, so this
// opens, truncates and closes — which changes the semantics for a path
// that is not writable and is therefore reported rather than hidden.
func Truncate(path string, length int64) error {
	return ENOSYS
}

// Seek is ENOSYS. Handles carry a kernel cursor, there is no by-offset
// read or write, and a Seek that silently did nothing would hand a caller
// the wrong bytes.
func Seek(fd int, offset int64, whence int) (int64, error) { return 0, ENOSYS }

func Dup(fd int) (int, error)          { return -1, ENOSYS }
func Dup3(oldfd, newfd, flags int) error { return ENOSYS }
func Fcntl(fd int, cmd int, arg int) (int, error) { return -1, ENOSYS }
func FcntlFlock(fd uintptr, cmd int, lk *Flock_t) error { return ENOSYS }
func SetNonblock(fd int, nonblocking bool) error { return nil }

// Flock_t exists for os/exec's shape; locking is not a kernel capability.
type Flock_t struct {
	Type   int16
	Whence int16
	Start  int64
	Len    int64
	Pid    int32
	Pad    [4]byte
}

// Pipe is ENOSYS. The kernel has pipe slots (56/57) but they are a SHARED
// per-process pipe, not a pipe pair with two fds, so os.Pipe's contract
// (two independent handles, EOF on the read end when the write end closes)
// cannot be met without inventing state the kernel does not have.
func Pipe(p []int) error { return ENOSYS }

// ----- path-mutating calls -------------------------------------------------

// Mkdir creates a directory: the kernel's directory creation rides the
// mutating open flags, so this is Open(MODE_WRITE|MODE_CREATE|MODE_DIR)
// plus an immediate close. The permission argument is accepted and ignored
// — there is no mode model at EL0 (ADR 0024 D1; slot 69 sets the M50
// ownership table, which is a different thing).
func Mkdir(path string, perm uint32) error {
	n := stagedAbs(path)
	if n < 0 {
		if len(path) > virPathMax {
			return ENAMETOOLONG
		}
		return EINVAL
	}
	r := svc3(virSysFileOpen, uintptr(unsafe.Pointer(&virPathStaging[0])), uintptr(n),
		uintptr(kmodeWrite|kmodeCreate|kmodeDir))
	if r < 0 {
		return errnoErr(errOf(r))
	}
	svc1(virSysClose, uintptr(int(r)))
	return nil
}

// Rmdir is not the same call as Unlink: the kernel's sys_file_delete
// removes a file, and a directory is only removable through it if the host
// allows it. The distinction is kept because callers depend on it.
func Rmdir(path string) error { return deletePath(path) }

func Unlink(path string) error { return deletePath(path) }

func deletePath(path string) error {
	n := stagedAbs(path)
	if n < 0 {
		if len(path) > virPathMax {
			return ENAMETOOLONG
		}
		return EINVAL
	}
	r := svc2(virSysDelete, uintptr(unsafe.Pointer(&virPathStaging[0])), uintptr(n))
	if r < 0 {
		return errnoErr(errOf(r))
	}
	return nil
}

// Rename publishes oldPath as newPath (slot 35). The host REFUSES a live
// target (the file-domain EEXIST), so this is not a POSIX rename-over.
func Rename(from, to string) error {
	nf := stagedAbs(from)
	if nf < 0 {
		return EINVAL
	}
	var old [virPathMax + 1]byte
	copy(old[:], virPathStaging[:nf])
	nt := stagedAbs(to)
	if nt < 0 {
		return EINVAL
	}
	r := svc4(virSysRename, uintptr(unsafe.Pointer(&old[0])), uintptr(nf),
		uintptr(unsafe.Pointer(&virPathStaging[0])), uintptr(nt))
	if r < 0 {
		return errnoErr(errOf(r))
	}
	return nil
}

func Link(oldpath, newpath string) error  { return ENOSYS }
func Symlink(oldpath, newpath string) error { return ENOSYS }
func Readlink(path string, buf []byte) (n int, err error) { return 0, EINVAL }
func Chmod(path string, mode uint32) error { return ENOSYS }
func Chown(path string, uid, gid int) error { return ENOSYS }
func Lchown(path string, uid, gid int) error { return ENOSYS }
func Fchmod(fd int, mode uint32) error     { return ENOSYS }
func Fchown(fd int, uid, gid int) error    { return ENOSYS }

// ----- stat --------------------------------------------------------------

// listRows lists dir into a local row array. max is clamped by the kernel to
// 16 (virDirRowsMax), and the listing ALWAYS starts at the first entry —
// there is no cursor in the ABI, which is what makes a >16-entry directory
// unenumerable (see ReadDirent).
// An EMPTY dir means the share root: the kernel reads path_len == 0 as
// "list the root" (handle_dir_list copies the path in only when there is
// one), which is also how the guest SDK lists it. Passed through instead of
// resolved because resolvePath("") is an error by contract — and a
// root-level entry (splitParent leaves "" for "<root>/NAME") is exactly the
// case this exists for.
func listRows(dir string, max int) ([]Dirent, error) {
	if max <= 0 || max > virDirRowsMax {
		max = virDirRowsMax
	}
	n := 0
	if dir != "" {
		n = stagedAbs(dir)
		if n < 0 {
			return nil, EINVAL
		}
	}
	rows := make([]Dirent, max)
	r := svc4(virSysDirList, uintptr(unsafe.Pointer(&virPathStaging[0])), uintptr(n),
		uintptr(unsafe.Pointer(&rows[0])), uintptr(max))
	if r < 0 {
		return nil, errnoErr(errOf(r))
	}
	if int(r) > len(rows) {
		return nil, EFAULT // the kernel wrote more rows than this buffer holds
	}
	return rows[:int(r)], nil
}

// splitParent returns the parent path and the leaf name. dir is "" when the
// path is a share-root child's parent (the share root itself).
func splitParent(path string) (dir, name string) {
	i := len(path) - 1
	for i >= 0 && path[i] != '/' {
		i--
	}
	if i < 0 {
		return "", path
	}
	return path[:i], path[i+1:]
}

func (d *Dirent) name() string {
	n := 0
	for n < len(d.Name) && d.Name[n] != 0 {
		n++
	}
	return string(d.Name[:n])
}

func (d *Dirent) dir() bool { return d.IsDir != 0 }

// statPath answers from a sys_dir_list row on the entry's PARENT. There is
// no stat-by-path slot, and a listing row carries exactly the two facts
// this kernel can report (size, directory bit), so Stat is a parent lookup
// rather than a fabrication. The share root is the one path with no parent.
//
// The parent route has a hard limit, and the port has to name it: the
// listing has NO cursor and the kernel clamps one call to 16 rows, so a
// parent with more than 16 entries cannot describe every child — the gate
// share has ~30, which is why the first std fixture to call Stat on
// /host/GOBIG.ELF read ENOENT for a file that was right there. The fallback
// below is the ABI's other half: ask the PATH itself whether it lists (that
// is a directory), and otherwise read the file to EOF and count. The row
// route is tried first because it is one syscall; the reading route costs
// O(size) and only ever runs where the row cannot exist.
func statPath(path string) (Stat_t, error) {
	var st Stat_t
	abs, err := resolvePath(path)
	if err != nil {
		return st, err
	}
	if abs == "/" || abs == "/host" {
		st.Mode = virModeDir
		return st, nil
	}
	dir, name := splitParent(abs)
	rows, lerr := listRows(dir, virDirRowsMax)
	if lerr != nil {
		return st, lerr
	}
	for i := range rows {
		if rows[i].name() == name {
			st.Size = int64(rows[i].Size)
			if rows[i].dir() {
				st.Mode = virModeDir
			} else {
				st.Mode = virModeFile
			}
			st.ModeSetBy = 1
			return st, nil
		}
	}
	if _, derr := listRows(abs, 1); derr == nil {
		// It lists, so it is a directory; this kernel reports no size for
		// one, and inventing a number would be worse than zero.
		st.Mode = virModeDir
		st.ModeSetBy = 1
		return st, nil
	}
	return statByReading(abs)
}

// statByReading derives a file's size the only other way this ABI allows:
// open it read-only, read to EOF, count the bytes. Used when the parent's
// first 16 rows do not contain the entry (see statPath). The handle is the
// kernel's own open — not Open(), which would probe for a directory and
// remember a handle the caller never sees — and it is closed before
// returning, whatever happens.
func statByReading(abs string) (Stat_t, error) {
	var st Stat_t
	n := stagedPath(abs)
	if n < 0 {
		if len(abs) > virPathMax {
			return st, ENAMETOOLONG
		}
		return st, EINVAL
	}
	r := svc3(virSysFileOpen, uintptr(unsafe.Pointer(&virPathStaging[0])), uintptr(n), uintptr(kmodeRead))
	if r < 0 {
		return st, errnoErr(errOf(r))
	}
	fd := int(r)
	var buf [virIOChunkMax]byte
	var total int64
	for {
		k := svc3(virSysRead, uintptr(fd), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
		if k < 0 {
			_ = svc1(virSysClose, uintptr(fd))
			return st, errnoErr(errOf(k))
		}
		if k == 0 {
			break
		}
		total += k
	}
	_ = svc1(virSysClose, uintptr(fd))
	st.Size = total
	st.Mode = virModeFile
	st.ModeSetBy = 1
	return st, nil
}

func Stat(path string, st *Stat_t) error {
	if st == nil {
		return EFAULT
	}
	s, err := statPath(path)
	if err != nil {
		return err
	}
	*st = s
	return nil
}

// Lstat is Stat: the share has no symbolic links, so there is nothing to
// not follow.
func Lstat(path string, st *Stat_t) error { return Stat(path, st) }

// Fstat resolves a handle back to the path Open remembered for it (the
// kernel reports neither a handle's path nor its size) and stats that.
func Fstat(fd int, st *Stat_t) error {
	if st == nil {
		return EFAULT
	}
	if _, ok := dirFdFor(fd); ok {
		st.Mode = virModeDir
		st.ModeSetBy = 2
		return nil
	}
	p, ok := fdPath(fd)
	if !ok {
		return EBADF
	}
	s, err := statPath(p)
	if err != nil {
		return err
	}
	*st = s
	return nil
}

func Fstatat(dirfd int, path string, st *Stat_t, flags int) error {
	return Stat(path, st)
}

// UtimesNano is ENOSYS: no seam in this kernel takes a timestamp.
func UtimesNano(path string, ts []Timespec) error { return ENOSYS }
func Utimes(path string, tv []Timeval) error      { return ENOSYS }

// ----- directory reads -----------------------------------------------------

// ReadDirent packs up to len(buf)/40 kernel rows into buf, continuing from
// the port's own per-fd cursor. The kernel lists a path from the FIRST entry
// every time and clamps to 16 rows, so the cursor is the only thing that
// makes successive calls make progress at all.
//
// The ABI's missing offset is a real limit, not a detail: a directory with
// more than 16 entries cannot be enumerated, and the kernel gives no signal
// that it truncated. This port therefore REFUSES after a full window instead
// of returning a partial listing that looks complete — a caller that gets
// ENOSPC knows its view was incomplete, where a caller that gets EOF would
// quietly act on 16 of N entries. The cost of that choice: a directory with
// exactly 16 entries is indistinguishable from a truncated one and trips the
// same refusal. Closing that needs a listing cursor on slot 27 (a kernel
// change, filed against #1525).
func ReadDirent(fd int, buf []byte) (n int, err error) {
	i, ok := dirFdFor(fd)
	if !ok {
		return 0, EBADF
	}
	if len(buf) < direntSize {
		return 0, EINVAL
	}
	d := &virDirs[i]
	if d.sat {
		return 0, ENOSPC
	}
	rows, lerr := listRows(d.path, virDirRowsMax)
	if lerr != nil {
		return 0, lerr
	}
	if len(rows) == virDirRowsMax {
		d.sat = true // the window filled: more entries may exist, unknowably
	}
	if d.rows > len(rows) {
		d.rows = len(rows)
	}
	limit := len(buf) / direntSize
	written := 0
	for k := d.rows; k < len(rows) && written < limit; k++ {
		copy(buf[written*direntSize:], unsafe.Slice((*byte)(unsafe.Pointer(&rows[k])), direntSize))
		written++
	}
	d.rows += written
	return written * direntSize, nil
}

// ----- working directory ---------------------------------------------------
//
// There is no chdir slot: the guest's own shell keeps PWD as userland state
// and verifies each path with a directory listing (user/go/sh). This port
// does the same — a package-level cwd that every path-taking call resolves
// through — because "os.Getwd" being answerable is worth more than a
// refusal, and the resolution is the only part the kernel does not do.

// The initial cwd is the host share, which is where a guest program's files
// live (the monitor resolves a bare `exec NAME.ELF` from the same place).
var virCwd = "/host"

func Chdir(path string) error {
	abs, err := resolvePath(path)
	if err != nil {
		return err
	}
	if !isDir(abs) {
		return ENOENT
	}
	virCwd = abs
	return nil
}

func Getwd() (string, error) { return virCwd, nil }

func Getcwd(buf []byte) (n int, err error) {
	c := virCwd
	if len(buf) < len(c)+1 {
		return 0, ERANGE
	}
	copy(buf, c)
	buf[len(c)] = 0
	return len(c), nil
}

// stagedAbs resolves path against the port's cwd, stages the ABSOLUTE form
// in virPathStaging, and returns its length (or -1). Every path-taking call
// goes through this: the kernel resolves nothing, so a relative path that
// reached it would be looked up at the share root and silently succeed
// against the wrong file.
func stagedAbs(path string) int {
	abs, err := resolvePath(path)
	if err != nil {
		return -1
	}
	return stagedPath(abs)
}

// resolvePath makes path absolute against the port's cwd. ".." is resolved
// lexically, which is what the guest's own shell does and is the only thing
// available without a way to walk upward in the kernel.
func resolvePath(path string) (string, error) {
	if len(path) == 0 {
		return "", ENOENT
	}
	if path[0] != '/' {
		base := virCwd
		if base == "/" {
			path = "/" + path
		} else {
			path = base + "/" + path
		}
	}
	out := make([]byte, 0, len(path))
	for i := 0; i < len(path); i++ {
		if path[i] != '/' {
			out = append(out, path[i])
			continue
		}
		if len(out) == 0 || out[len(out)-1] != '/' {
			out = append(out, '/')
		}
	}
	if len(out) > 1 && out[len(out)-1] == '/' {
		out = out[:len(out)-1]
	}
	return string(out), nil
}
