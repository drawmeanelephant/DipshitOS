package main

import (
	"testing"

	"virelai/vi"
)

func TestTabMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{MarkerTabOpen, "gotabwm: tab open id="},
		{MarkerTabFocus, "gotabwm: tab focus id="},
		{MarkerTabClose, "gotabwm: tab close id="},
		{MarkerRail, "gotabwm: rail "},
		{MarkerTabsEmpty, "gotabwm: tabs empty"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

func TestOpenCloseFocusMachine(t *testing.T) {
	var s TabStrip
	if s.Count() != 0 {
		t.Fatalf("zero strip count = %d", s.Count())
	}
	if _, ok := s.Focused(); ok {
		t.Fatal("zero strip must have no focus")
	}
	if s.OpenTab(0, "x") {
		t.Fatal("id 0 must be refused")
	}
	if !s.OpenTab(4, "Calc") {
		t.Fatal("first OpenTab")
	}
	if s.Count() != 1 {
		t.Fatalf("count = %d want 1", s.Count())
	}
	if id, ok := s.Focused(); !ok || id != 4 {
		t.Fatalf("first tab focus = %d ok=%v want 4", id, ok)
	}
	if s.OpenTab(4, "Calc2") {
		t.Fatal("duplicate OpenTab must not count as added")
	}
	if s.Count() != 1 || s.At(0).Title != "Calc2" {
		t.Fatalf("duplicate should update title, count=%d title=%q", s.Count(), s.At(0).Title)
	}
	if !s.OpenTab(5, "Notepad") {
		t.Fatal("second OpenTab")
	}
	if s.Count() != 2 {
		t.Fatalf("count = %d want 2", s.Count())
	}
	if id, ok := s.Focused(); !ok || id != 4 {
		t.Fatalf("second OpenTab stole focus: %d ok=%v", id, ok)
	}
	if !s.FocusTab(5) {
		t.Fatal("FocusTab 5")
	}
	if id, ok := s.Focused(); !ok || id != 5 {
		t.Fatalf("focus = %d want 5", id)
	}
	if s.FocusTab(99) {
		t.Fatal("FocusTab unknown")
	}
	// Close the focused tab: the remaining one becomes focused.
	if !s.CloseTab(5) {
		t.Fatal("CloseTab focused")
	}
	if s.Count() != 1 {
		t.Fatalf("count after close focused = %d want 1", s.Count())
	}
	if id, ok := s.Focused(); !ok || id != 4 {
		t.Fatalf("remaining focus = %d ok=%v want 4", id, ok)
	}
	if !s.CloseTab(4) {
		t.Fatal("CloseTab last")
	}
	if s.Count() != 0 {
		t.Fatalf("empty count = %d", s.Count())
	}
	if _, ok := s.Focused(); ok {
		t.Fatal("empty strip still focused")
	}
	if s.CloseTab(4) {
		t.Fatal("CloseTab missing")
	}
}

func TestCloseNonFocusedKeepsFocus(t *testing.T) {
	var s TabStrip
	s.OpenTab(1, "a")
	s.OpenTab(2, "b")
	s.FocusTab(1)
	if !s.CloseTab(2) {
		t.Fatal("close non-focused")
	}
	if id, ok := s.Focused(); !ok || id != 1 {
		t.Fatalf("focus moved off the surviving tab: %d ok=%v", id, ok)
	}
}

func TestCloseFirstOfTwoFocusesNeighbour(t *testing.T) {
	var s TabStrip
	s.OpenTab(1, "a")
	s.OpenTab(2, "b")
	s.FocusTab(1)
	if !s.CloseTab(1) {
		t.Fatal("close first")
	}
	if id, ok := s.Focused(); !ok || id != 2 {
		t.Fatalf("neighbour focus = %d ok=%v want 2", id, ok)
	}
}

func TestMaxTabsCap(t *testing.T) {
	var s TabStrip
	for i := 1; i <= MaxTabs; i++ {
		if !s.OpenTab(uint32(i), "t") {
			t.Fatalf("OpenTab %d failed under cap", i)
		}
	}
	if s.OpenTab(uint32(MaxTabs+1), "overflow") {
		t.Fatal("OpenTab past MaxTabs")
	}
	if s.Count() != MaxTabs {
		t.Fatalf("count = %d want %d", s.Count(), MaxTabs)
	}
}

func TestNextIDWraps(t *testing.T) {
	var s TabStrip
	if _, ok := s.NextID(); ok {
		t.Fatal("empty NextID")
	}
	s.OpenTab(1, "a")
	s.OpenTab(2, "b")
	s.FocusTab(1)
	if id, ok := s.NextID(); !ok || id != 2 {
		t.Fatalf("next from 1 = %d ok=%v want 2", id, ok)
	}
	s.FocusTab(2)
	if id, ok := s.NextID(); !ok || id != 1 {
		t.Fatalf("next from 2 = %d ok=%v want 1", id, ok)
	}
}

func TestMaxTabsMatchesSessionCap(t *testing.T) {
	if MaxTabs != 16 {
		t.Fatalf("MaxTabs = %d want 16 (ADR 0033 / .tabs v2)", MaxTabs)
	}
	if RailHeight != 22 {
		t.Fatalf("RailHeight = %d want 22 (kernel tab_bar_height)", RailHeight)
	}
}

func TestPaintRailFillsStripOnly(t *testing.T) {
	const w, h, strip = 256, 32, 8
	buf := make([]byte, w*h*4)
	var s TabStrip
	if n := paintRail(buf, w, h, strip, &s); n != 0 {
		t.Fatalf("empty strip wrote %d pixels", n)
	}
	s.OpenTab(1, "a")
	s.OpenTab(2, "b")
	s.FocusTab(2)
	if n := paintRail(buf, w, h, strip, &s); n == 0 {
		t.Fatal("paintRail wrote nothing")
	}
	pix := func(x, y int) uint32 {
		i := (y*w + x) * 4
		return uint32(buf[i]) | uint32(buf[i+1])<<8 | uint32(buf[i+2])<<16 | uint32(buf[i+3])<<24
	}
	// Below the strip must stay zero.
	for y := strip; y < h; y++ {
		for x := 0; x < w; x++ {
			if pix(x, y) != 0 {
				t.Fatalf("pixel %d,%d = %#x; paintRail wrote below the strip", x, y, pix(x, y))
			}
		}
	}
	// The two cells differ: left is idle, right is focused.
	left := pix(2, 1)
	right := pix(w/2+2, 1)
	if left == 0 || right == 0 {
		t.Fatalf("strip cells were not painted left=%#x right=%#x", left, right)
	}
	if left == right {
		t.Fatalf("focused and idle cells are the same colour %#x", left)
	}
	if right != railFocusRGB {
		t.Fatalf("focused cell %#x want %#x", right, railFocusRGB)
	}
	if left != railIdleRGB {
		t.Fatalf("idle cell %#x want %#x", left, railIdleRGB)
	}
}

func TestPaintRailScanoutGeometry(t *testing.T) {
	if vi.ScanoutWidth != 1280 || vi.ScanoutHeight != 720 {
		t.Fatalf("scanout %dx%d; rail layout assumes 1280x720", vi.ScanoutWidth, vi.ScanoutHeight)
	}
	if RailHeight >= vi.ScanoutHeight {
		t.Fatal("rail covers the whole scanout")
	}
}
