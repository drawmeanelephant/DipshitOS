// GOTABWM.ELF — M57b (issue #1317): the seat manages its OWN Go windows.
//
// M57a put the seat on slot 65 and composited a blank desktop. This card adds
// the window lifecycle the seat owns as a CLIENT of its own render server:
//
//	vi.WinOpen                (12)    -> gotabwm: win open id=<n>
//	vi.WmctlSetWindowChrome   (65/2)  -> gotabwm: win chrome
//	vi.WmctlSetWindowRect     (65/2)  -> gotabwm: win rect x=<x> y=<y> w=<w> h=<h>
//	WIN_FOCUS (kind 6, routed by the kernel on open) -> gotabwm: win focus
//	WIN_BLUR  (kind 7, routed when another window takes focus) -> win blur
//	vi.WmctlWinClose          (65/13) -> gotabwm: win close
//	vi.WinQuery fails after the close  -> gotabwm: win gone
//	a window left open at exit         -> gotabwm: win leak id=<n>
//
// Every marker is printed only after its syscall/step SUCCEEDED, so the marker
// chain is the syscall chain (the M57a discipline). The kernel proves the rest:
// it CLAMPS the WM's proposed rect (WM proposes, kernel clamps to the scanout),
// it routes focus as real WIN_FOCUS/WIN_BLUR events, and its exit seam tears
// down a window the process never closed (M52 client-death discipline — no
// zombie window, no residue). No libc, no POSIX, no cgo: only the ADR 0007
// `svc #0` seam through virelai/vi.
package main

import (
	"virelai/vi"
)

// The window-lifecycle marker lines the class-B gate greps. Exported so
// windows_test.go pins the exact shapes (a drift is a host-test failure, not a
// live run that silently asserts nothing).
const (
	MarkerWinOpen   = "gotabwm: win open id="
	MarkerWinChrome = "gotabwm: win chrome"
	MarkerWinRect   = "gotabwm: win rect "
	MarkerWinFocus  = "gotabwm: win focus"
	MarkerWinBlur   = "gotabwm: win blur"
	MarkerWinClose  = "gotabwm: win close"
	MarkerWinGone   = "gotabwm: win gone"
	MarkerWinLeak   = "gotabwm: win leak id="
)

// The Go window the seat opens, and the position it PROPOSES. The proposal is
// deliberately OFF-SCANOUT (the framebuffer is 1280x720) so the kernel's clamp
// is observable: the reported rect is the CLAMPED one, never the proposed one.
// The size is carried through unchanged, so the kernel's move-only path applies
// (driving_award.reflow) and the clamp is proved without asking the pool to
// grow the back-buffer.
const (
	winX = 24
	winY = 16
	winW = 256
	winH = 192

	propX = 4000
	propY = 3000
	propW = winW
	propH = winH
)

// The client-death probe: a second window the process deliberately NEVER
// closes. The kernel's exit seam (driving_award.close_owner, reached from
// scheduler exit) must tear it down, so the post-exit registry is back to its
// pre-program count — no zombie window.
const (
	leakX = 8
	leakY = 8
	leakW = 96
	leakH = 64
)

// scratchVA is the page the chrome descriptor lives on. uaccess.copy_in reads
// through the caller's own user page map, and a Go heap/stack buffer is not
// guaranteed mapped for EL1 (ADR 0026 D8), so the descriptor goes on an
// explicitly mapped page — the same reason gowin.go hints its back-buffer.
// 10 GiB is clear of the sbrk heap and of the randomized EL0 stack band.
const scratchVA = 0x0000_0002_8000_0000

// maxWinEvents bounds every window-phase wait so a boot can never hang.
const maxWinEvents = 200

// runWindowPhase drives the seat's own window lifecycle end to end. It returns
// whether every step succeeded; main turns a false into a distinct exit code,
// so a failed gate points at one step rather than a mystery.
func runWindowPhase() bool {
	// The chrome descriptor's backing page (see scratchVA).
	scratch, err := vi.MmapHint(scratchVA, vi.PageSize, vi.ProtRead|vi.ProtWrite, vi.MapAnonymous)
	if err != nil {
		vi.ConsoleLine("gotabwm: win scratch failed " + err.Error())
		return false
	}
	desc := scratch[:vi.ChromeDescBytes]
	fillBorderChrome(desc)

	// 1. Open the seat's own Go window.
	id, r := vi.WinOpen(winX, winY, winW, winH)
	if r < 0 {
		vi.ConsoleLine("gotabwm: win open failed " + vi.Itoa64(r))
		return false
	}
	vi.ConsoleLine(MarkerWinOpen + vi.Itoa64(int64(id)))

	// 2. Submit a chrome descriptor through the WM seam.
	if c := vi.WmctlSetWindowChrome(uint32(id), desc); c != 0 {
		vi.ConsoleLine("gotabwm: win chrome failed " + vi.Itoa64(c))
		return false
	}
	vi.ConsoleLine(MarkerWinChrome)

	// 3. Propose an oversized rect; read back what the KERNEL decided.
	if c := vi.WmctlSetWindowRect(uint32(id), propX, propY, propW, propH); c != 0 {
		vi.ConsoleLine("gotabwm: win rect failed " + vi.Itoa64(c))
		return false
	}
	st, q := vi.WinQuery(id)
	if q < 0 {
		vi.ConsoleLine("gotabwm: win query failed " + vi.Itoa64(q))
		return false
	}
	vi.ConsoleLine(MarkerWinRect +
		"x=" + vi.Itoa64(int64(st[0])) +
		" y=" + vi.Itoa64(int64(st[1])) +
		" w=" + vi.Itoa64(int64(st[2])) +
		" h=" + vi.Itoa64(int64(st[3])))

	// 4. Focus gain: the kernel routed WIN_FOCUS when the window opened.
	if !waitKind(vi.EvWinFocus) {
		vi.ConsoleLine("gotabwm: win focus timeout")
		return false
	}
	vi.ConsoleLine(MarkerWinFocus)

	// 5. Focus loss: the harness focuses another window; the kernel routes
	//    WIN_BLUR to the seat.
	if !waitKind(vi.EvWinBlur) {
		vi.ConsoleLine("gotabwm: win blur timeout")
		return false
	}
	vi.ConsoleLine(MarkerWinBlur)

	// 6. Close THROUGH the WM seam: the kernel runs its own release, so the
	//    owner (this process) receives the real WIN_CLOSE.
	if c := vi.WmctlWinClose(uint32(id)); c != 0 {
		vi.ConsoleLine("gotabwm: win close failed " + vi.Itoa64(c))
		return false
	}
	if !waitKind(vi.EvWinClose) {
		vi.ConsoleLine("gotabwm: win close timeout")
		return false
	}
	vi.ConsoleLine(MarkerWinClose)

	// 7. No residue: the released window is gone from the registry.
	if _, q := vi.WinQuery(id); q >= 0 {
		vi.ConsoleLine("gotabwm: win gone FAILED")
		return false
	}
	vi.ConsoleLine(MarkerWinGone)

	// 8. Client-death probe (M52): open a window and NEVER close it. The
	//    kernel's exit seam must tear it down when this process exits.
	lid, lr := vi.WinOpen(leakX, leakY, leakW, leakH)
	if lr < 0 {
		vi.ConsoleLine("gotabwm: win leak open failed " + vi.Itoa64(lr))
		return false
	}
	vi.ConsoleLine(MarkerWinLeak + vi.Itoa64(int64(lid)))
	return true
}

// waitKind drains the caller's event queue until an event of `kind` arrives,
// bounded so a boot can never hang. Non-matching events (the kind-18
// COMPOSITE_TICK stream, WIN_RESIZE from the clamp) are consumed and dropped.
func waitKind(kind uint16) bool {
	for i := 0; i < maxWinEvents; i++ {
		ev, ok := vi.PollEvent()
		if ok {
			if ev.Kind == kind {
				return true
			}
			continue
		}
		vi.Sleep(1)
	}
	return false
}

// fillBorderChrome writes the frozen 40-byte v1 chrome descriptor: kind =
// chrome_border (0x01), flags = 0, then the eight colour words. It is built
// with explicit little-endian stores so the wire layout does not depend on the
// compiler's struct padding.
func fillBorderChrome(desc []byte) {
	for i := range desc {
		desc[i] = 0
	}
	putU32LE(desc[0:], 0x01)      // kind: chrome_border (zero is refused)
	putU32LE(desc[4:], 0x00)      // flags: no reserved bits set
	putU32LE(desc[8:], 0x3a7bd5)  // border_rgb
	putU32LE(desc[12:], 0x6b7280) // border_unfocus_rgb
	putU32LE(desc[16:], 0x1a1e2e) // title_bg_rgb
	putU32LE(desc[20:], 0xf0f0f0) // title_fg_rgb
	putU32LE(desc[24:], 0x3a7bd5) // ring_rgb
	putU32LE(desc[28:], 0xe05a5a) // close_rgb
	putU32LE(desc[32:], 0x9aa0a6) // min_rgb
	putU32LE(desc[36:], 0x9aa0a6) // pin_rgb
}

// putU32LE stores v little-endian at b (b must have at least 4 bytes).
func putU32LE(b []byte, v uint32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}
