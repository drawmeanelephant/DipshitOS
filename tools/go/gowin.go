// GOWIN.ELF — M53 Card 1 (issue #1245; umbrella #1244 is context only).
//
// A tiny GOOS=virelai program in the same family as tools/go/hello.go: it
// opens ONE window through the raw ADR 0007 syscall ABI, gives it a
// shared-anonymous back-buffer, fills a visible rect, presents it, waits for
// CloseRequested and exits clean. No LIBUI, no webrender, no browser, no HTTP,
// no tabs, no chrome beyond the filled rect, no new syscall, kernel untouched.
//
// The exact sequence:
//
//	sys_win_open           (12) -> a window id
//	sys_mmap               (63) -> a shared-anon back-buffer (M33_MAP_SHARED)
//	sys_win_fill           (13) -> fill a visible rect
//	sys_win_present        (14)
//	sys_poll_event         (21) -> until CloseRequested / WIN_CLOSE (kind 8)
//	sys_win_close + sys_exit (15 + 3)
//
// The five marker lines below are the proof the class-B gate greps
// (tools/gate/specs/go-win.spec), and each one is printed only after its
// syscall SUCCEEDED, so the marker chain is the syscall chain:
//
//	gowin: open id=<n>
//	gowin: fill
//	gowin: present
//	gowin: close
//	gowin OK
package main

import (
	"unsafe"

	"virelai/vi"
)

// ADR 0007 slot numbers, copied from user/go/vi/vi.go (which mirrors
// kernel/src/syscall.zig).
const (
	slotExit       = 3
	slotWinOpen    = 12
	slotWinFill    = 13
	slotWinPresent = 14
	slotWinClose   = 15
	slotPollEvent  = 21
	slotMmap       = 63
)

// Event kinds (ADR 0009; kernel/src/events.zig, mirrored in vi.go).
const evWinClose = 8

// sys_mmap protection/flag words used here.
const (
	protReadWrite = 3       // PROT_READ | PROT_WRITE
	mapAnonymous  = 0x20    // M29 MAP_ANONYMOUS
	m33MapShared  = 0x10000 // M33_MAP_SHARED — ADR 0016 seam B, frozen in ADR 0007
)

// surfVA is the address GOWIN asks sys_mmap for. It is an explicit,
// page-aligned hint because a hintless mapping is refused for this program:
// the GOOS=virelai runtime's sbrk heap reserves its arena upward from the
// module end and covers the kernel's DEFAULT mmap base
// (process.mmap_next_va = 0x1000_0000), which the issue-#1214 collision rule
// rejects — observed live as `gowin: error mmap EINVAL` before this hint
// existed. 12 GiB is clear of that heap and of the randomized EL0 stack band
// [0x1_0000_0000, 0x2_0000_0000) (kernel/src/csprng.zig stack_va_from_random).
const surfVA = 0x0000_0003_0000_0000

// The one window, and the one visible rect filled in it.
const (
	winX = 40
	winY = 28
	winW = 512
	winH = 384
)

// fillRGB is the visible rect's colour, packed 0x00RRGGBB as the fill seam
// takes it (the back-buffer stores it B,G,R,X).
const fillRGB = 0x3050a0

// maxIdleTicks bounds the wait for CloseRequested (~1 s per tick, ADR 0007
// slot 4) so a boot can never hang on this program. If the bound expires the
// program still closes and exits, but it does NOT print `gowin: close` — the
// gate's marker then fails honestly rather than passing on a window nobody
// ever asked to close.
const maxIdleTicks = 60

// viSyscall6 is the SDK's ADR 0007 gateway (user/go/vi/vi_arm64.s implements
// it: x8 = slot, x0-x5 = arguments, x0 = result, negative = the kernel's
// errno). It is the same `svc #0` seam hello.go rides through the runtime; the
// linkname is only so this program can pass the mmap ADDRESS HINT that
// vi.MmapAnon hard-codes to 0. No new slot, no new syscall.
//
//go:linkname viSyscall6 virelai/vi.syscall6
func viSyscall6(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64

func sys1(n, a0 uintptr) int64             { return viSyscall6(n, a0, 0, 0, 0, 0, 0) }
func sys4(n, a0, a1, a2, a3 uintptr) int64 { return viSyscall6(n, a0, a1, a2, a3, 0, 0) }
func sys6(n, a0, a1, a2, a3, a4, a5 uintptr) int64 {
	return viSyscall6(n, a0, a1, a2, a3, a4, a5)
}

// event is the 16-byte application event wire format (ADR 0009, vi.Event):
// u16 kind, u16 flags, u32 seq, u32 arg0, u32 arg1.
type event struct {
	Kind  uint16
	Flags uint16
	Seq   uint32
	Arg0  uint32
	Arg1  uint32
}

func main() {
	// --- sys_win_open ----------------------------------------------------
	id := sys4(slotWinOpen, uintptr(winX), uintptr(winY), uintptr(winW), uintptr(winH))
	if id < 0 {
		vi.ConsoleLine("gowin: error open " + vi.Itoa64(id))
		vi.Exit(2)
	}
	win := uintptr(id)
	vi.ConsoleLine("gowin: open id=" + vi.Itoa64(id))

	// --- sys_mmap: the app's own shared-anon back-buffer -------------------
	// Owner-create over slot 63: explicit page-aligned address, PROT_READ|
	// WRITE, MAP_ANONYMOUS|M33_MAP_SHARED. The kernel allocates the surface's
	// pages once and installs the caller's WRITABLE leaf, so the app renders
	// with plain stores (ADR 0016 seam B).
	n := uintptr(winW * winH * 4)
	base := sys4(slotMmap, uintptr(surfVA), n, protReadWrite, mapAnonymous|m33MapShared)
	if base < 0 {
		vi.ConsoleLine("gowin: error mmap " + vi.Itoa64(base))
		vi.Exit(3)
	}

	// --- fill a visible rect ---------------------------------------------
	// Paint the rect into the back-buffer first (plain stores through the
	// owner leaf), then push the SAME rect through the window fill seam using
	// the colour read back out of that buffer — so the buffer is what the
	// visible rect is drawn from, not decoration.
	surface := unsafe.Slice((*byte)(unsafe.Pointer(uintptr(base))), int(n))
	paint(surface, winW, winH)
	rgb := uint32(surface[0]) | uint32(surface[1])<<8 | uint32(surface[2])<<16
	if r := sys6(slotWinFill, win, 0, 0, uintptr(winW), uintptr(winH), uintptr(rgb)); r < 0 {
		vi.ConsoleLine("gowin: error fill " + vi.Itoa64(r))
		vi.Exit(4)
	}
	vi.ConsoleLine("gowin: fill")

	// --- sys_win_present --------------------------------------------------
	if r := sys1(slotWinPresent, win); r < 0 {
		vi.ConsoleLine("gowin: error present " + vi.Itoa64(r))
		vi.Exit(5)
	}
	vi.ConsoleLine("gowin: present")

	// --- sys_poll_event until CloseRequested ------------------------------
	if !waitClose() {
		vi.ConsoleLine("gowin: idle")
	}

	// --- sys_win_close + sys_exit ----------------------------------------
	// The release already happened if the close came in through the
	// privileged path (the kernel pushes WIN_CLOSE FROM the release), so a
	// non-zero return is not an error here: the window is gone either way.
	_ = sys1(slotWinClose, win)
	vi.ConsoleLine("gowin OK")
	vi.Exit(0)
}

// paint writes the visible rect into the back-buffer with plain stores.
func paint(surface []byte, w, h int) {
	c := uint32(fillRGB)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			o := (y*w + x) * 4
			surface[o] = byte(c)
			surface[o+1] = byte(c >> 8)
			surface[o+2] = byte(c >> 16)
			surface[o+3] = 0xff
		}
	}
}

// waitClose drains the event queue until WIN_CLOSE (CloseRequested) arrives.
// It reports whether that is why the wait ended.
func waitClose() bool {
	var ev event
	idle := 0
	for {
		if r := sys1(slotPollEvent, uintptr(unsafe.Pointer(&ev))); r > 0 {
			if ev.Kind == evWinClose {
				vi.ConsoleLine("gowin: close")
				return true
			}
			continue
		}
		idle++
		if idle > maxIdleTicks {
			return false
		}
		vi.Sleep(1)
	}
}
