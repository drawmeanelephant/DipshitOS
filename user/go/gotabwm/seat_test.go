package main

import "testing"

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
