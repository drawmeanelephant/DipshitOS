// Package vi is the VirelaiOS guest OS layer for Go programs: the typed
// wrapper over the ADR 0007 `svc #0` syscall seam that a userland app needs
// (console, window fills, events, the file channel, TCP). It links no libc
// and no POSIX; on a host build every call degrades to -ENOSYS so the app's
// logic remains unit-testable.
package vi

import "unsafe"

// ADR 0007 slot numbers (kernel/src/syscall.zig, mirrored by
// user/src/lib/ui/abi.zig). Adding a row here must match that table.
const (
	SlotWrite        uintptr = 1
	SlotYield        uintptr = 2
	SlotExit         uintptr = 3
	SlotSleep        uintptr = 4
	SlotIPCSend      uintptr = 5
	SlotIPCRecv      uintptr = 6
	SlotProcs        uintptr = 7
	SlotWinOpen      uintptr = 12
	SlotWinFill      uintptr = 13
	SlotWinPresent   uintptr = 14
	SlotWinClose     uintptr = 15
	SlotWinQuery     uintptr = 19
	SlotPollEvent    uintptr = 21
	SlotWaitEvent    uintptr = 22
	SlotFileOpen     uintptr = 23
	SlotFileRead     uintptr = 24
	SlotFileWrite    uintptr = 25
	SlotFileClose    uintptr = 26
	SlotDirList      uintptr = 27
	SlotExec         uintptr = 28
	SlotTCPConnect   uintptr = 30
	SlotTCPSend      uintptr = 31
	SlotTCPRecv      uintptr = 32
	SlotTCPClose     uintptr = 33
	SlotFileDelete   uintptr = 34
	SlotFileTruncate uintptr = 36
	SlotAudioInfo    uintptr = 42
	SlotAudioPlay    uintptr = 43
	SlotWinFillBatch uintptr = 46
	SlotMmap         uintptr = 63
	SlotTime         uintptr = 66
)

// Kernel error codes (ADR 0007 D3): the MAGNITUDES of the kernel's
// `ErrorCode` enum (kernel/src/syscall.zig). A syscall returns the negation,
// so a full mailbox ring hands back -ErrENOSPC from slot 5. Ordering is the
// kernel's, not alphabetical; TestErrnoTable pins it.
const (
	ErrEINVAL       int64 = 1
	ErrEBADF        int64 = 2
	ErrEFAULT       int64 = 3
	ErrENOSYS       int64 = 4
	ErrENOSPC       int64 = 5
	ErrENOENT       int64 = 6
	ErrEACCES       int64 = 7
	ErrENAMETOOLONG int64 = 8
	ErrENXIO        int64 = 9
	ErrENOMEM       int64 = 10
	ErrEAGAIN       int64 = 11
	ErrETIMEDOUT    int64 = 12
)

// File channel flags (ADR 0010).
const (
	ModeRead   uint32 = 0x0001
	ModeWrite  uint32 = 0x0002
	ModeCreate uint32 = 0x0004
	ModeAppend uint32 = 0x0008
	ModeDir    uint32 = 0x0010
)

// Event kinds (ADR 0009).
const (
	EvKeyDown   uint16 = 1
	EvKeyUp     uint16 = 2
	EvMouseDown uint16 = 3
	EvMouseUp   uint16 = 4
	EvMouseMove uint16 = 5
	EvWinFocus  uint16 = 6
	EvWinBlur   uint16 = 7
	EvWinClose  uint16 = 8
	EvTimer     uint16 = 9
	EvWinResize uint16 = 10
)

// Event modifier and button bits.
const (
	ModShift  uint16 = 0x0001
	ModCtrl   uint16 = 0x0002
	ModAlt    uint16 = 0x0004
	ModCmd    uint16 = 0x0008
	BtnLeft   uint16 = 0x0100
	BtnRight  uint16 = 0x0200
	BtnMiddle uint16 = 0x0400
)

// writeChunk keeps every console write inside the kernel's 256-byte cap.
const writeChunk = 200

// Event is the 16-byte application event wire format (ADR 0009). The field
// order and widths are the kernel's: u16 kind, u16 flags, u32 seq, u32 arg0,
// u32 arg1.
type Event struct {
	Kind  uint16
	Flags uint16
	Seq   uint32
	Arg0  uint32
	Arg1  uint32
}

// Rect is one fill rectangle for the batcher (24 bytes on the wire).
type Rect struct {
	X, Y, W, H uint32
	RGB        uint32
}

// Console writes s to the kernel console (bounded chunks, never panics).
func Console(s string) {
	for len(s) > 0 {
		n := len(s)
		if n > writeChunk {
			n = writeChunk
		}
		if len(s) > 0 {
			_ = syscall3(SlotWrite, 1, strPtr(s[:n]), uintptr(n))
		}
		s = s[n:]
	}
}

// ConsoleLine writes s followed by a newline.
func ConsoleLine(s string) {
	Console(s)
	Console("\n")
}

// Yield is a cooperative scheduler point.
func Yield() { _ = syscall0(SlotYield) }

// Sleep blocks the calling task for ticks scheduler ticks.
func Sleep(ticks uint64) { _ = syscall1(SlotSleep, uintptr(ticks)) }

// Exit terminates the process with the given status.
func Exit(status int) {
	_ = syscall1(SlotExit, uintptr(status))
	// The kernel never returns here; keep looping so a stray return cannot
	// fall through into other code.
	for {
		Yield()
	}
}

// Time returns wall-clock unix seconds (negative when the firmware gave no
// boot epoch).
func Time() int64 { return syscall0(SlotTime) }

// WinOpen opens a user window and returns (id, rawResult).
func WinOpen(x, y, w, h uint32) (int, int64) {
	r := syscall4(SlotWinOpen, uintptr(x), uintptr(y), uintptr(w), uintptr(h))
	if r < 0 {
		return -1, r
	}
	return int(r), r
}

// WinFill is a single (unbatched) fill — prefer Filler.
func WinFill(id int, x, y, w, h uint32, rgb uint32) int64 {
	return syscall6(SlotWinFill, uintptr(id), uintptr(x), uintptr(y), uintptr(w), uintptr(h), uintptr(rgb))
}

// WinPresent flushes the window's pending fills to the compositor.
func WinPresent(id int) int64 { return syscall1(SlotWinPresent, uintptr(id)) }

// WinClose closes the caller's window.
func WinClose(id int) int64 { return syscall1(SlotWinClose, uintptr(id)) }

// WinQuery reads the full window state (x, y, w, h, z, focused, visible,
// dirty) — 32 bytes out through uaccess.
func WinQuery(id int) ([8]uint32, int64) {
	var out [8]uint32
	r := syscall2(SlotWinQuery, uintptr(id), uintptr(unsafe.Pointer(&out[0])))
	return out, r
}

// PollEvent returns the next queued event and true, or false when the queue
// is empty.
func PollEvent() (Event, bool) {
	var ev Event
	r := syscall1(SlotPollEvent, uintptr(unsafe.Pointer(&ev)))
	if r <= 0 {
		return Event{}, false
	}
	return ev, true
}

// PollEventRaw returns the raw syscall result alongside the decoded event, so
// a caller can distinguish an empty queue (0) from a kernel refusal (< 0).
func PollEventRaw() (Event, int64, bool) {
	var ev Event
	r := syscall1(SlotPollEvent, uintptr(unsafe.Pointer(&ev)))
	if r <= 0 {
		return Event{}, r, false
	}
	return ev, r, true
}

// WaitEvent blocks until an event arrives. Prefer PollEvent + Sleep in the
// browser's loop: sleeping keeps the cooperative scheduler honest.
func WaitEvent() (Event, int64) {
	var ev Event
	r := syscall1(SlotWaitEvent, uintptr(unsafe.Pointer(&ev)))
	return ev, r
}

// Filler batches fill rectangles and flushes them through slot 46 (one SVC
// per up-to-32 rects, 24 bytes each). Ordering is preserved across window id
// changes because the batch is keyed by id.
type Filler struct {
	buf   [FillBatchMax * FillRectSize]byte
	len   int
	curID int
}

// FillRectSize and FillBatchMax mirror the kernel's handler
// (kernel/src/syscall.zig handle_win_fill_batch).
const (
	FillRectSize = 24
	FillBatchMax = 32
)

// Rect queues one fill rectangle for window id.
func (f *Filler) Rect(id int, x, y, w, h uint32, rgb uint32) {
	if w == 0 || h == 0 {
		return
	}
	if f.len > 0 && f.curID != id {
		f.Flush()
	}
	if f.len+FillRectSize > len(f.buf) {
		f.Flush()
	}
	f.curID = id
	off := f.len
	f.buf[off] = byte(id & 0xff)
	f.buf[off+1] = 0
	f.buf[off+2] = 0
	f.buf[off+3] = 0
	putU32(f.buf[off+4:], x)
	putU32(f.buf[off+8:], y)
	putU32(f.buf[off+12:], w)
	putU32(f.buf[off+16:], h)
	putU32(f.buf[off+20:], rgb)
	f.len += FillRectSize
}

// Fill is Rect's argument order for a whole Rect value.
func (f *Filler) Fill(id int, r Rect) { f.Rect(id, r.X, r.Y, r.W, r.H, r.RGB) }

// Flush sends the pending rects and resets the batch. Returns the number of
// rects the kernel reported processing.
func (f *Filler) Flush() int {
	if f.len == 0 {
		return 0
	}
	n := f.len / FillRectSize
	f.curID = 0
	r := syscall2(SlotWinFillBatch, uintptr(unsafe.Pointer(&f.buf[0])), uintptr(f.len))
	f.len = 0
	if r < 0 {
		return 0
	}
	if int(r) < n {
		return int(r)
	}
	return n
}

// Reset drops any pending fills without sending them.
func (f *Filler) Reset() { f.len = 0; f.curID = 0 }

// Pending reports how many rects are queued.
func (f *Filler) Pending() int { return f.len / FillRectSize }

// FileOpen opens path with the given mode flags. Returns (handle, result).
func FileOpen(path string, flags uint32) (int64, int64) {
	if path == "" {
		return -1, -ErrEINVAL
	}
	r := syscall3(SlotFileOpen, strPtr(path), uintptr(len(path)), uintptr(flags))
	return r, r
}

// FileRead reads into buf, returning (n, result).
func FileRead(h uint32, buf []byte) (int, int64) {
	if len(buf) == 0 {
		return 0, 0
	}
	r := syscall3(SlotFileRead, uintptr(h), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// FileWrite writes buf, returning (n, result).
func FileWrite(h uint32, b []byte) (int, int64) {
	if len(b) == 0 {
		return 0, 0
	}
	r := syscall3(SlotFileWrite, uintptr(h), uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)))
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// FileClose closes a handle.
func FileClose(h uint32) { _ = syscall1(SlotFileClose, uintptr(h)) }

// MaxFileBytes caps any file the browser will load (a page, not a download).
const MaxFileBytes = 256 * 1024

// ReadFileAll reads a whole file up to max bytes. A file longer than max is
// truncated (and the caller is told by the returned length). Errors are
// returned as a negative int64; the slice is nil on failure.
func ReadFileAll(path string, max int) ([]byte, int64) {
	if max <= 0 || max > MaxFileBytes {
		max = MaxFileBytes
	}
	h, r := FileOpen(path, ModeRead)
	if r < 0 {
		return nil, r
	}
	defer FileClose(uint32(h))
	out := make([]byte, 0, 8192)
	buf := make([]byte, 4096)
	for len(out) < max {
		n, rr := FileRead(uint32(h), buf)
		if rr < 0 {
			return out, rr
		}
		if n == 0 {
			break
		}
		take := n
		if len(out)+take > max {
			take = max - len(out)
		}
		out = append(out, buf[:take]...)
		if take < n {
			break
		}
	}
	return out, int64(len(out))
}

// FileExists reports whether a path can be opened for reading.
func FileExists(path string) bool {
	h, r := FileOpen(path, ModeRead)
	if r < 0 {
		return false
	}
	FileClose(uint32(h))
	return true
}

// FileAppend creates-or-appends and writes b. Returns false on any error.
func FileAppend(path string, b []byte) bool {
	h, r := FileOpen(path, ModeWrite|ModeCreate|ModeAppend)
	if r < 0 {
		return false
	}
	defer FileClose(uint32(h))
	n, wr := FileWrite(uint32(h), b)
	return wr >= 0 && n == len(b)
}

// FileTruncate resizes an open handle to size bytes (slot 36) — the
// compaction half of the ledger rewrite path.
func FileTruncate(h uint32, size uint32) int64 {
	return syscall2(SlotFileTruncate, uintptr(h), uintptr(size))
}

// FileDelete removes a file by path (slot 34).
func FileDelete(path string) int64 {
	if path == "" {
		return -ErrEINVAL
	}
	return syscall2(SlotFileDelete, strPtr(path), uintptr(len(path)))
}

// Exec loads name from the host share into a fresh process and returns its
// pid (ADR 0007 slot 28). args is the card-3e argv list (at most 8 strings,
// each truncated to 31 bytes + NUL); a missing list is argc=0.
func Exec(name string, args ...string) (int64, error) {
	if name == "" {
		return 0, errno(ErrEINVAL)
	}
	if len(args) > 8 {
		return 0, errno(ErrEINVAL)
	}
	var block [256]byte
	for i, a := range args {
		n := len(a)
		if n > 31 {
			n = 31
		}
		copy(block[i*32:], a[:n])
	}
	var argvPtr uintptr
	if len(args) > 0 {
		argvPtr = uintptr(unsafe.Pointer(&block[0]))
	}
	r := syscall4(SlotExec, strPtr(name), uintptr(len(name)), argvPtr, uintptr(len(args)))
	if r < 0 {
		return 0, errno(-r)
	}
	return r, nil
}

// MaxDirEntries is the kernel's sys_dir_list window (handle_dir_list clamps
// max_entries to 16). A longer caller buffer is truncated to this.
const MaxDirEntries = 16

// DirEntry is the 40-byte sys_dir_list row (file_table.DirEntry): name[32]
// NUL-padded, size u32, is_dir u8, reserved[3].
type DirEntry struct {
	Name     [32]byte
	Size     uint32
	IsDir    uint8
	Reserved [3]byte
}

// NameString returns the NUL-trimmed directory entry name.
func (e DirEntry) NameString() string {
	n := 0
	for n < len(e.Name) && e.Name[n] != 0 {
		n++
	}
	return string(e.Name[:n])
}

// Dir reports whether the entry is a directory.
func (e DirEntry) Dir() bool { return e.IsDir != 0 }

// DirList enumerates path into buf (slot 27). Returns (count, result).
// An empty path lists the host-share root. count is 0 when the call fails.
func DirList(path string, buf []DirEntry) (int, int64) {
	if len(buf) == 0 {
		return 0, 0
	}
	if len(buf) > MaxDirEntries {
		buf = buf[:MaxDirEntries]
	}
	r := syscall4(SlotDirList, strPtr(path), uintptr(len(path)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// TCPConnect opens the single TCP socket (VirelaiOS has one per process).
func TCPConnect(ip [4]byte, port uint16) int64 {
	word := uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3])
	return syscall2(SlotTCPConnect, uintptr(word), uintptr(port))
}

// TCPSend writes b to the socket.
func TCPSend(b []byte) (int, int64) {
	if len(b) == 0 {
		return 0, 0
	}
	r := syscall2(SlotTCPSend, uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)))
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// TCPRecv reads into buf. Returns (0, 0) when nothing is available yet.
func TCPRecv(buf []byte) (int, int64) {
	if len(buf) == 0 {
		return 0, 0
	}
	r := syscall2(SlotTCPRecv, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// TCPClose closes the socket.
func TCPClose() int64 { return syscall0(SlotTCPClose) }

// Map flags / protections accepted by sys_mmap (slot 63).
const (
	ProtRead     uint64 = 1
	ProtWrite    uint64 = 2
	MapPrivate   uint64 = 0x02
	MapAnonymous uint64 = 0x20
	MapPopulate  uint64 = 0x8000
	PageSize            = 4096
)

// errno is a tiny error type so callers can branch on the kernel's own codes
// without an errno translation layer (which this OS deliberately has none of).
type errno int64

func (e errno) Error() string {
	switch int64(e) {
	case ErrEINVAL:
		return "EINVAL"
	case ErrEBADF:
		return "EBADF"
	case ErrEFAULT:
		return "EFAULT"
	case ErrENOSYS:
		return "ENOSYS"
	case ErrENOSPC:
		return "ENOSPC"
	case ErrENOENT:
		return "ENOENT"
	case ErrEACCES:
		return "EACCES"
	case ErrENAMETOOLONG:
		return "ENAMETOOLONG"
	case ErrENXIO:
		return "ENXIO"
	case ErrENOMEM:
		return "ENOMEM"
	case ErrEAGAIN:
		return "EAGAIN"
	case ErrETIMEDOUT:
		return "ETIMEDOUT"
	}
	return "EIO"
}

func strPtr(s string) uintptr {
	if len(s) == 0 {
		return 0
	}
	return uintptr(unsafe.Pointer(unsafe.StringData(s)))
}

func putU32(b []byte, v uint32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}

// Itoa64 is the shared decimal formatter for the guest side (the stdlib
// strconv is not ported to this GOOS).
func Itoa64(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var buf [24]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
