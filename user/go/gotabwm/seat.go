// GOTABWM.ELF — M57a (issue #1313): a Go window manager registers the kernel
// render-server seat (slot 65) and composites a blank desktop.
//
// The sequence, and the marker line each step proves:
//
//	vi.WmctlRegister (65/1)         -> gotabwm: registered
//	vi.WmctlRegister again (EACCES) -> gotabwm: seat-taken
//	vi.MmapScanout (63, scan tag)   -> gotabwm: scanout
//	paint the blank desktop         -> gotabwm: draw
//	seat held, awaiting ticks       -> gotabwm: holding seat
//	COMPOSITE_TICK (kind 18)        -> gotabwm: tick
//	vi.WmctlRequestPresent (65/3)   -> gotabwm: present
//	loop bound reached              -> gotabwm: close
//	clean exit                      -> gotabwm OK
//
// Each marker is printed ONLY after its syscall/step succeeded, so the marker
// chain IS the syscall chain. The kernel's exit path unregisters the seat and
// prints `wm: unregistered, shim resumed`; the class-B gate
// (tools/gate/specs/go-wm-seat.spec) asserts every line above, plus the `wm`
// monitor report naming the live seat.
//
// This card is the SEAT only: no window management (M57b), no Zig-app hosting
// (M57c), not the boot default (M59). No libc, no POSIX, no cgo — the guest
// talks only through the ADR 0007 `svc #0` seam (virelai/vi).
package main

import (
	"unsafe"

	"virelai/vi"
)

// The marker lines the class-B gate greps. Exported constants so seat_test.go
// pins the exact shapes (the repo pins gate grep targets this way in
// user/src/wndstub.zig and user/src/tabwm.zig).
const (
	MarkerRegistered = "gotabwm: registered"
	MarkerSeatTaken  = "gotabwm: seat-taken"
	MarkerScanout    = "gotabwm: scanout"
	MarkerDraw       = "gotabwm: draw"
	MarkerHolding    = "gotabwm: holding seat"
	MarkerTick       = "gotabwm: tick"
	MarkerPresent    = "gotabwm: present"
	MarkerClose      = "gotabwm: close"
	MarkerOK         = "gotabwm OK"
)

// blankRGB is the blank desktop's colour, packed 0x00RRGGBB as the fill seam
// takes it (the scanout stores it B,G,R,X).
const blankRGB uint32 = 0x1A1E2E

// maxTicks bounds the composite loop so a boot can never hang (~1 tick/s).
const maxTicks = 12

// maxEvents bounds the wait loop regardless of which kinds arrive (the tick is
// the only expected one — no input is driven — but the bound keeps a spurious
// event stream from spinning forever).
const maxEvents = 500

func main() {
	// 1. Register the seat (slot 65 cmd 1). ENXIO here means the compositor
	//    is not armed; EACCES means a seat is already taken.
	r := vi.WmctlRegister()
	if r != 0 {
		vi.ConsoleLine("gotabwm: register failed " + vi.Itoa64(r))
		vi.Exit(2)
	}
	vi.ConsoleLine(MarkerRegistered)

	// 2. One-seat discipline: the kernel refuses a second registration with
	//    EACCES (-7). Fail the gate honestly if that is not what came back.
	if r2 := vi.WmctlRegister(); r2 != -vi.ErrEACCES {
		vi.ConsoleLine("gotabwm: seat-taken FAILED " + vi.Itoa64(r2))
		vi.Exit(3)
	}
	vi.ConsoleLine(MarkerSeatTaken)

	// 3. Map the scanout (seam B compose-N target) — full-frame, seat-only.
	scan, err := vi.MmapScanout()
	if err != nil {
		vi.ConsoleLine("gotabwm: scanout failed " + err.Error())
		vi.Exit(4)
	}
	vi.ConsoleLine(MarkerScanout)

	// 4. Composite the blank desktop.
	_ = paintBlank(scan, blankRGB)
	vi.ConsoleLine(MarkerDraw)
	vi.ConsoleLine(MarkerHolding)

	// 5. Composite/present loop paced by the kind-18 tick.
	presents, ticks := 0, 0
	for events := 0; events < maxEvents && ticks < maxTicks; events++ {
		e, r := vi.WaitEvent()
		if r <= 0 {
			vi.Yield()
			continue
		}
		if e.Kind != vi.EvCompositeTick {
			continue
		}
		ticks++
		vi.ConsoleLine(MarkerTick)
		_ = paintBlank(scan, blankRGB)
		if vi.WmctlRequestPresent() == 0 {
			presents++
			if presents == 1 {
				vi.ConsoleLine(MarkerPresent)
			}
		}
	}

	// 6. Clean exit. The kernel's exit path unregisters the seat.
	vi.ConsoleLine(MarkerClose)
	if presents == 0 {
		vi.ConsoleLine("gotabwm: no present")
		vi.Exit(5)
	}
	if ticks == 0 {
		vi.ConsoleLine("gotabwm: no tick")
		vi.Exit(6)
	}
	vi.ConsoleLine(MarkerOK)
	vi.Exit(0)
}

// paintBlank fills every pixel of the mapped scanout with rgb and returns the
// pixel count written. Split out of main so the host test can pin the fill
// without a guest (an incomplete fill is the classic "the frame looks right on
// one half" bug).
func paintBlank(scan []byte, rgb uint32) int {
	n := len(scan) / 4
	if n == 0 {
		return 0
	}
	pix := unsafe.Slice((*uint32)(unsafe.Pointer(&scan[0])), n)
	for i := range pix {
		pix[i] = rgb
	}
	return n
}
