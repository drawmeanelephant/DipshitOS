// chrome_test.go — M71c (#1562): host tests for the seat chrome's pure half.
//
// These run on the host (`go test ./gotabwm`), so they may not call any `vi`
// guest syscall: parseClockEpoch, clockHMS, formatClock, chromeRect,
// drawText8 and paintChrome all operate on plain Go values and a caller's
// scanout slice, which is the whole point of keeping them out of the seat
// loop.
package main

import (
	"testing"
	"unsafe"

	"virelai/theme"
	"virelai/webrender/font"
)

func TestParseClockEpoch(t *testing.T) {
	ok := []struct {
		in   string
		want uint32
	}{
		{"0", 0},
		{"0\n", 0},
		{"3600", 3600},
		{"86399", 86399},
		{" 12345\t", 12345},
		{"\r\n45000\n", 45000},
	}
	for _, c := range ok {
		got, have := parseClockEpoch([]byte(c.in))
		if !have || got != c.want {
			t.Errorf("parseClockEpoch(%q) = %d,%v want %d,true", c.in, got, have, c.want)
		}
	}
	bad := []string{"", " ", "\n", "abc", "12abc", "1.5", "-1", "86400", "999999", "12 34", "9999999"}
	for _, in := range bad {
		if got, have := parseClockEpoch([]byte(in)); have {
			t.Errorf("parseClockEpoch(%q) = %d,true want refusal", in, got)
		}
	}
}

// The clock contract is shared with Zig TABWM (tabwm.zig clock_hms): an epoch
// makes it time-of-day wrapping at 24h, no epoch makes it uptime past 24.
func TestClockHMS(t *testing.T) {
	cases := []struct {
		elapsed   uint64
		epoch     uint32
		haveEpoch bool
		h, m, s   int
	}{
		{0, 0, true, 0, 0, 0},
		{30, 86370, true, 0, 0, 0},   // 86370 + 30 = 86400 wraps to midnight
		{0, 86399, true, 23, 59, 59}, // last second of the day
		{3600, 0, true, 1, 0, 0},     // an hour past midnight
		{0, 0, false, 0, 0, 0},       // uptime from 00:00
		{3661, 0, false, 1, 1, 1},    // uptime advances the same way
		{90000, 0, false, 25, 0, 0},  // uptime is NOT wrapped at 24h
		{90000, 100, true, 1, 1, 40}, // epoch + elapsed still wraps
	}
	for _, c := range cases {
		h, m, s := clockHMS(c.elapsed, c.epoch, c.haveEpoch)
		if h != c.h || m != c.m || s != c.s {
			t.Errorf("clockHMS(%d,%d,%v) = %02d:%02d:%02d want %02d:%02d:%02d",
				c.elapsed, c.epoch, c.haveEpoch, h, m, s, c.h, c.m, c.s)
		}
	}
}

func TestFormatClock(t *testing.T) {
	cases := []struct {
		h, m, s int
		want    string
	}{
		{0, 0, 0, "00:00:00"},
		{9, 5, 3, "09:05:03"},
		{23, 59, 59, "23:59:59"},
		{25, 0, 0, "25:00:00"},  // uptime may name an hour past 24
		{0, 60, 60, "00:60:60"}, // formatting never invents a carry
	}
	for _, c := range cases {
		if got := formatClock(c.h, c.m, c.s); got != c.want {
			t.Errorf("formatClock(%d,%d,%d) = %q want %q", c.h, c.m, c.s, got, c.want)
		}
	}
	if n := len(formatClock(0, 0, 0)); n != 8 {
		t.Errorf("formatClock width = %d want 8", n)
	}
}

func TestChromeRect(t *testing.T) {
	x, y, w, h := chromeRect(1280, 720)
	if w != ChromeW || h != ChromeH {
		t.Fatalf("chromeRect size = %dx%d want %dx%d", w, h, ChromeW, ChromeH)
	}
	if x != 1280-chromeInset-ChromeW || y != 720-chromeInset-ChromeH {
		t.Fatalf("chromeRect origin = %d,%d not inset from the bottom-right", x, y)
	}
	if x < 0 || y < 0 || x+w > 1280 || y+h > 720 {
		t.Fatalf("chromeRect %d,%d %dx%d escapes the scanout", x, y, w, h)
	}
	// A scanout too small for the inset shrinks the panel rather than
	// painting off-frame, and one too small even for that paints nothing.
	if _, _, w, h := chromeRect(100, 30); w != 100-2*chromeInset || h != 30-2*chromeInset {
		t.Errorf("small scanout panel = %dx%d want shrunk", w, h)
	}
	if x, y, w, h := chromeRect(10, 10); w != 0 || h != 0 || x != 0 || y != 0 {
		t.Errorf("tiny scanout chromeRect = %d,%d %dx%d want zero", x, y, w, h)
	}
}

func TestDrawText8SizesWithTheFace(t *testing.T) {
	const w, h = 1280, 720
	scan := make([]byte, w*h*4)
	pix := asUint32(scan)
	n := drawText8(pix, w, h, 4, 4, "ABC", theme.Dark.Ink)
	if n == 0 {
		t.Fatal("drawText8 painted nothing")
	}
	if got, want := font.Measure("ABC", chromeScale), 24; got != want {
		t.Fatalf("Measure(\"ABC\") = %d want %d", got, want)
	}
	// The third glyph's columns live at 16..23, so a run of 24-wide advance
	// means nothing is painted past x 4+24.
	for row := 0; row < 8; row++ {
		for col := 4 + 24; col < w; col++ {
			if pix[row*w+col] != 0 {
				t.Fatalf("drawText8 wrote past its advance at %d,%d", col, row)
			}
		}
	}
}

// paintChrome is the frame-level half: it must write a bounded panel in the
// token chrome colour, an accent rule, and ink/muted glyphs — and nothing
// outside the rect.
func TestPaintChromeStaysInsideTheRectAndUsesTokens(t *testing.T) {
	const w, h = 1280, 720
	scan := make([]byte, w*h*4)
	tok := theme.Current
	// Pre-fill with a colour the chrome never uses, so "outside" is provable.
	for i := 0; i < len(scan)/4; i++ {
		asUint32(scan)[i] = theme.Light.Success
	}
	if paintChrome(scan, w, h, "12:34:56") == 0 {
		t.Fatal("paintChrome painted nothing")
	}
	pix := asUint32(scan)
	x, y, pw, ph := chromeRect(w, h)
	var panel, accent, ink, muted int
	for row := 0; row < h; row++ {
		for col := 0; col < w; col++ {
			v := pix[row*w+col]
			inRect := col >= x && col < x+pw && row >= y && row < y+ph
			if !inRect {
				if v != theme.Light.Success {
					t.Fatalf("paintChrome wrote outside the panel at %d,%d", col, row)
				}
				continue
			}
			// fillRect forces the scanout's X byte opaque (M71c #1562), so the
			// stored word is the token with 0xff in the top byte.
			switch v & 0xffffff {
			case tok.ChromeBg:
				panel++
			case tok.Accent:
				accent++
			case tok.Ink:
				ink++
			case tok.Muted:
				muted++
			}
		}
	}
	if panel == 0 {
		t.Fatal("panel is not ChromeBg")
	}
	if accent != 2*ph {
		t.Fatalf("accent rule = %d pixels want %d (2px x panel height)", accent, 2*ph)
	}
	if ink == 0 {
		t.Fatal("clock face has no Ink pixels")
	}
	if muted == 0 {
		t.Fatal("status line has no Muted pixels")
	}
}

func TestPaintChromeRefusesDegenerateScanouts(t *testing.T) {
	if n := paintChrome(nil, 0, 0, "00:00:00"); n != 0 {
		t.Errorf("nil scanout painted %d pixels", n)
	}
	if n := paintChrome([]byte{0, 0, 0, 0}, 0, 0, "00:00:00"); n != 0 {
		t.Errorf("zero-size scanout painted %d pixels", n)
	}
}

// asUint32 views a scanout byte slice as the words fillRect writes. It must
// ALIAS the caller's buffer, not copy it: fillRect's writes have to land in
// the slice the test then reads.
func asUint32(scan []byte) []uint32 {
	return unsafe.Slice((*uint32)(unsafe.Pointer(&scan[0])), len(scan)/4)
}
