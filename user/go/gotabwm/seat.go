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
//	paint the clock/status chrome   -> gotabwm: clock-source / gotabwm: clock
//	WM_POINTER (kind 19)            -> gotabwm: ptr
//	WM_KEY (kind 21)                -> gotabwm: key
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

	"virelai/theme"
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
	MarkerPtr        = "gotabwm: ptr"
	MarkerKey        = "gotabwm: key"
	MarkerPresent    = "gotabwm: present"
	MarkerClose      = "gotabwm: close"
	MarkerOK         = "gotabwm OK"
	// M69a (issue #1528): the dogfood beat's own two markers, owned by
	// go-dogfood.spec. MarkerDogfoodSeat is the DEFAULT seat announcing it owns
	// the desktop (printed once the registration AND the one-seat probe both
	// returned). MarkerDogfoodOK closes the boot's hosted phase: it is printed
	// at host-done only when this boot actually hosted a tab (dogfoodHosted),
	// so a bare seat boot can never claim the beat.
	MarkerDogfoodSeat = "dogfood: seat"
	MarkerDogfoodOK   = "dogfood: ok"
)

// blankRGB is the blank desktop's colour, packed 0x00RRGGBB as the fill seam
// takes it (the scanout stores it B,G,R,X).
func blankRGB() uint32 { return theme.Current.Bg }

// maxTicks bounds the composite loop so a boot can never hang (~1 tick/s).
// Three Go runtimes (this seat + two clients) fit max_tasks=16 (M65d /
// #1442: 3 kernel + 3×4 Ms + 1 spare). GOMAXPROCS=1 still fits (3 kernel
// tasks each: primary + sysmon + helper). A
// `--pointer-virtio` click is 3 messages × 2.5 s; pointerClickHold is that
// budget in ticks. maxTicks must cover hostTicks + hidChordHold + the
// two-tab choreography (9) so M63 HID (click, type-in, drag, chords)
// lands before auto pin/close. Type-in and drag are separate boots.
const maxTicks = 48

// pointerClickHold is how many composite ticks one `--pointer-virtio` click
// needs at the 1 Hz kind-18 heartbeat (3 messages × 2.5 s, rounded up).
const pointerClickHold = 8

// maxEvents bounds the wait loop regardless of which kinds arrive (ticks,
// WM pointer/key, window mirrors). The bound keeps a spurious event stream
// from spinning forever.
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

	// M69a (#1528): the default seat is live and exclusive. The dogfood beat
	// gates its first exec on this line, so it must come after both the
	// registration and the one-seat probe succeeded.
	vi.ConsoleLine(MarkerDogfoodSeat)

	// 3. Map the scanout (seam B compose-N target) — full-frame, seat-only.
	scan, err := vi.MmapScanout()
	if err != nil {
		vi.ConsoleLine("gotabwm: scanout failed " + err.Error())
		vi.Exit(4)
	}
	vi.ConsoleLine(MarkerScanout)

	// 4. Composite the blank desktop.
	_ = paintBlank(scan, blankRGB())
	vi.ConsoleLine(MarkerDraw)
	vi.ConsoleLine(MarkerHolding)

	// M66b (#1444): decode /host/SETTINGS.TXT (schema v2) BEFORE any phase
	// that waits on the harness (the window choreography would otherwise
	// sit between boot and the decode). Missing is silent; corrupt fails
	// closed — one marker line, then the seat runs on its own defaults. A
	// marker only after its syscall returned.
	loadSettings()
	emitTokens()

	// 5. The seat's OWN window lifecycle (M57b, issue #1317): open a Go
	//    window, submit a chrome descriptor and a kernel-clamped rect, take
	//    focus and lose it, close through the WM seam, and leave a window
	//    open at exit so the kernel's client-death seam must reap it.
	if !runWindowPhase() {
		vi.Exit(7)
	}

	// M62e: restore `.tabs` v2 from /host/SESSION.TABS if a prior boot
	// wrote it. Missing is a no-op; corrupt fails closed (empty strip).
	loadSession()

	// 6. Composite/present loop paced by the kind-18 tick - and the WM_RPC
	//    serve loop (M57c / M62b): the seat hosts tabapp clients that declare
	//    over the mailbox, keeps them on the in-process strip, and paints a
	//    rail on the compose-N scanout. PollEvent (not WaitEvent) so a pending
	//    request is serviced between ticks.
	presents, ticks := 0, 0
	for events := 0; events < maxEvents && ticks < maxTicks; events++ {
		serviceRPC()
		e, ok := vi.PollEvent()
		if !ok {
			vi.Sleep(1)
			continue
		}
		// Drain kinds 19/21 (and 20) before Sleep: Sleep runs only on an
		// empty poll. Log ptr/key after a real event, never on empty.
		if !consumeSeatEvent(e) {
			continue
		}
		ticks++
		vi.ConsoleLine(MarkerTick)
		// Paint the blank desktop only while the strip is empty: the kernel
		// paints a hosted app's window at the tick and this compose-N target
		// sits above it, so a full-frame blank paint would overpaint the client.
		// With tabs, paint only the rail band.
		if tabs.Count() == 0 {
			_ = paintBlank(scan, blankRGB())
		} else {
			_ = paintRail(scan, vi.ScanoutWidth, vi.ScanoutHeight, RailHeight, &tabs)
			markRail()
		}
		// M71c (#1562): the seat's own clock/status panel, repainted every
		// tick AFTER whatever desktop layer this tick painted, so it sits
		// above a hosted client (a tab's window is the whole scanout). It
		// also emits the one-shot clock-source marker.
		chromeTick(scan, uint64(ticks))
		if launch.open {
			_ = paintLauncher(scan, vi.ScanoutWidth, vi.ScanoutHeight)
		}
		if vi.WmctlRequestPresent() == 0 {
			presents++
			if presents == 1 {
				vi.ConsoleLine(MarkerPresent)
			}
		}
		if stripDone {
			continue
		}
		n := tabs.Count()
		// Two-tab choreography (M62b): after the rail has been presented with
		// n>=2, close the focused tab, then the last. stripSawTwo stays set
		// after the first close (n drops to 1) so we do not fall through to
		// the single-tab countdown. The seat stays registered once empty.
		if n >= 2 || stripSawTwo {
			if !stripSawTwo {
				stripSawTwo = true
				stripStep = 0
				stripHoldLeft = hidChordHold
			}
			if stripHoldLeft > 0 {
				stripHoldLeft--
			} else {
				stripStep++
				switch stripStep {
				case 1:
					_ = applySwapUnpinned()
				case 2:
					// M62e: persist this pin-stay snapshot only. Not a
					// general save-on-exit; writeSession is once-only.
					if applyPinStay() {
						_ = writeSession()
					}
				case 3:
					_ = applySplit(SplitVert)
				case 4:
					_ = applyUnsplit()
				case 5:
					_ = applySplit(SplitHoriz)
				case 6:
					_ = applyUnsplit()
				case 7:
					closePinnedFirst()
					stripClosedOne = true
					if tabs.Count() == 0 {
						stripDone = true
					}
				default:
					closeHosted()
					stripDone = true
				}
			}
			continue
		}
		// Single-tab close (go-wm-seat / go-wm-default). Counted on ticks,
		// not empty polls, so a second declare can still land.
		if n == 1 {
			hostTicksLeft--
			if hostTicksLeft <= 0 {
				closeHosted()
				stripDone = true
			}
		}
	}
	vi.ConsoleLine(MarkerHostDone)

	// M69a (#1528): the beat's closing marker for THIS boot. Gated on the
	// latch, not on tabs.Count(): the close choreography empties the strip
	// before host-done. A boot that hosted nothing prints nothing.
	if dogfoodHosted {
		vi.ConsoleLine(MarkerDogfoodOK)
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

// consumeSeatEvent handles one non-empty poll. Pointer and key log their
// markers and return false (not a tick). Kind 19 also hit-tests the top
// rail (M63c). Window mirrors are dropped; client-area clicks are ignored.
// Any other kind is the pre-M63a ignore-non-tick path. Only
// EvCompositeTick returns true.
func consumeSeatEvent(e vi.Event) bool {
	if e.Kind == vi.EvWmPointer {
		vi.ConsoleLine(MarkerPtr)
		handleWmPointer(e)
		return false
	}
	if e.Kind == vi.EvWmKey {
		vi.ConsoleLine(MarkerKey)
		handleWmKey(e)
		// Yield only when the launcher is closed: a hosted client (GOEDIT
		// ctrl-s) needs a tick to drain KEY_DOWN before the next virtio
		// chord. While the launcher is open, Sleep would drop the next
		// type-to-filter report (observed: first `c` of `calc` vanished).
		if !launch.open {
			vi.Sleep(1)
		}
		return false
	}
	return e.Kind == vi.EvCompositeTick
}

// hidMarker is the serial line for a WM input-seam kind, or "" for ticks,
// window mirrors, empty polls, and everything else. Empty polls never call
// this — the loop Sleeps instead.
func hidMarker(kind uint16) string {
	switch kind {
	case vi.EvWmPointer:
		return MarkerPtr
	case vi.EvWmKey:
		return MarkerKey
	default:
		return ""
	}
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
	// B,G,R,X scanout: the X byte must be opaque (the kernel writes 0xff
	// there too). A 6-hex token leaves it 0x00, which the host display
	// honours as alpha — that is why a seated scanout used to show the
	// kernel's opaque layer and none of the seat's. M71c (#1562).
	for i := range pix {
		pix[i] = rgb | 0xff000000
	}
	return n
}

// lastRailN / lastRailFocus suppress repeat rail markers; the gate greps
// the transition (n=2 then n=1), not a per-tick flood.
var (
	lastRailN     int
	lastRailFocus uint32
	railMarked    bool
)

func markRail() {
	n := tabs.Count()
	if n == 0 {
		return
	}
	f, _ := tabs.Focused()
	if railMarked && n == lastRailN && f == lastRailFocus {
		return
	}
	railMarked = true
	lastRailN = n
	lastRailFocus = f
	vi.ConsoleLine(MarkerRail + "n=" + vi.Itoa64(int64(n)) + " focus=" + vi.Itoa64(int64(f)))
}
