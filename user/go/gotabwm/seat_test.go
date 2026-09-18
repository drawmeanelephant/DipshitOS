package main

import (
	"testing"

	"virelai/vi"
)

// The gate greps these exact strings; a drift is a host-test failure rather
// than a live run that silently asserts nothing.
func TestMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{MarkerRegistered, "gotabwm: registered"},
		{MarkerSeatTaken, "gotabwm: seat-taken"},
		{MarkerScanout, "gotabwm: scanout"},
		{MarkerDraw, "gotabwm: draw"},
		{MarkerHolding, "gotabwm: holding seat"},
		{MarkerTick, "gotabwm: tick"},
		{MarkerPtr, "gotabwm: ptr"},
		{MarkerKey, "gotabwm: key"},
		{MarkerPresent, "gotabwm: present"},
		{MarkerClose, "gotabwm: close"},
		{MarkerOK, "gotabwm OK"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

func TestBlankColourIs24Bit(t *testing.T) {
	if blankRGB&0xFF000000 != 0 {
		t.Fatalf("blankRGB %#x sets the X byte; the scanout is B8G8R8X8", blankRGB)
	}
}

func TestLoopBounds(t *testing.T) {
	if maxTicks <= 0 {
		t.Fatalf("maxTicks = %d: an unbounded loop can hang a boot", maxTicks)
	}
	if maxEvents < maxTicks {
		t.Fatalf("maxEvents %d < maxTicks %d: the tick bound is unreachable", maxEvents, maxTicks)
	}
	if pointerClickHold < 8 {
		t.Fatalf("pointerClickHold = %d: a 3×2.5s click does not fit", pointerClickHold)
	}
	if maxTicks < pointerClickHold {
		t.Fatalf("maxTicks %d < pointerClickHold %d: a click expires mid-sequence", maxTicks, pointerClickHold)
	}
}

// paintBlank must fill EVERY pixel (a partial fill is the "frame is right on
// one half" bug), and must ignore a trailing sub-pixel remainder.
func TestPaintBlankFillsEveryPixel(t *testing.T) {
	const pix = 1024
	buf := make([]byte, pix*4)
	if got := paintBlank(buf, 0x11223344); got != pix {
		t.Fatalf("paintBlank returned %d want %d", got, pix)
	}
	for i := 0; i < pix; i++ {
		v := uint32(buf[i*4]) | uint32(buf[i*4+1])<<8 | uint32(buf[i*4+2])<<16 | uint32(buf[i*4+3])<<24
		if v != 0x11223344 {
			t.Fatalf("pixel %d = %#x want 0x11223344", i, v)
		}
	}
}

func TestPaintBlankEdgeCases(t *testing.T) {
	if got := paintBlank(nil, 1); got != 0 {
		t.Fatalf("paintBlank(nil) = %d want 0", got)
	}
	if got := paintBlank(make([]byte, 3), 1); got != 0 {
		t.Fatalf("paintBlank(3 bytes) = %d want 0 (no whole pixel)", got)
	}
	if got := paintBlank(make([]byte, 6), 1); got != 1 {
		t.Fatalf("paintBlank(6 bytes) = %d want 1", got)
	}
}

// hidMarker logs ptr/key only for real WM input-seam kinds — never for an
// empty poll (kind 0), a composite tick, a window mirror, or app-side
// MOUSE_*/KEY_* events (the ignore-non-tick regression).
func TestHidMarkerOnlyAfterRealEvent(t *testing.T) {
	if hidMarker(vi.EvWmPointer) != MarkerPtr {
		t.Fatalf("kind 19 marker = %q want %q", hidMarker(vi.EvWmPointer), MarkerPtr)
	}
	if hidMarker(vi.EvWmKey) != MarkerKey {
		t.Fatalf("kind 21 marker = %q want %q", hidMarker(vi.EvWmKey), MarkerKey)
	}
	zeros := []uint16{0, vi.EvCompositeTick, vi.EvWmWindow, vi.EvKeyDown, vi.EvMouseMove, vi.EvWinFocus}
	for _, k := range zeros {
		if m := hidMarker(k); m != "" {
			t.Fatalf("hidMarker(%d) = %q: empty polls / non-HID kinds must not log ptr/key", k, m)
		}
	}
}

func TestConsumeSeatEventIgnoreNonTick(t *testing.T) {
	if !consumeSeatEvent(vi.Event{Kind: vi.EvCompositeTick}) {
		t.Fatal("kind 18 must count as a tick")
	}
	// Pointer and key are drained (not ticks). consumeSeatEvent logs via
	// ConsoleLine; on the host that degrades to ENOSYS and does not panic.
	if consumeSeatEvent(vi.Event{Kind: vi.EvWmPointer}) {
		t.Fatal("kind 19 must not count as a tick")
	}
	if consumeSeatEvent(vi.Event{Kind: vi.EvWmKey}) {
		t.Fatal("kind 21 must not count as a tick")
	}
	if consumeSeatEvent(vi.Event{Kind: vi.EvWmWindow}) {
		t.Fatal("kind 20 must not count as a tick")
	}
	if consumeSeatEvent(vi.Event{}) {
		t.Fatal("empty event must not count as a tick")
	}
	if consumeSeatEvent(vi.Event{Kind: vi.EvWinFocus}) {
		t.Fatal("WIN_FOCUS must stay on the ignore-non-tick path")
	}
	if consumeSeatEvent(vi.Event{Kind: vi.EvMouseMove}) {
		t.Fatal("app MOUSE_MOVE must stay on the ignore-non-tick path")
	}
}
