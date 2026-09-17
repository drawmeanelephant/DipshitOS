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
		{MarkerSplit, "gotabwm: split "},
		{MarkerUnsplit, "gotabwm: unsplit"},
		{MarkerLayout, "gotabwm: layout "},
		{MarkerPane, "gotabwm: pane "},
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

func TestSplitHVUnsplitMachine(t *testing.T) {
	var s TabStrip
	if s.SplitH() || s.SplitV() {
		t.Fatal("split with no tabs")
	}
	s.OpenTab(4, "Calc")
	if s.SplitV() {
		t.Fatal("split with one tab")
	}
	s.OpenTab(5, "Notepad")
	if !s.SplitV() {
		t.Fatal("SplitV")
	}
	if s.Split() != SplitVert {
		t.Fatalf("kind = %s want v", s.Split())
	}
	if s.SplitH() {
		// SplitH from already-two is allowed (retarget the kind).
	}
	if !s.SplitH() {
		t.Fatal("SplitH retarget")
	}
	if s.Split() != SplitHoriz {
		t.Fatalf("kind = %s want h", s.Split())
	}
	if !s.Unsplit() {
		t.Fatal("Unsplit")
	}
	if s.Split() != SplitNone {
		t.Fatal("Unsplit left a kind")
	}
	if s.Unsplit() {
		t.Fatal("Unsplit twice")
	}
	s.SplitV()
	s.CloseTab(4)
	if s.Split() != SplitNone {
		t.Fatal("CloseTab of a pane must unsplit")
	}
}

func TestSplitRectsIntegerAndMin(t *testing.T) {
	if PaneMinW != 160 || PaneMinH != 120 {
		t.Fatalf("pane min %dx%d want 160x120 (ADR 0033)", PaneMinW, PaneMinH)
	}
	a, b, ok := SplitRects(SplitVert, 1280, 720)
	if !ok {
		t.Fatal("SplitV 1280x720")
	}
	if a != (Rect{0, 0, 640, 720}) || b != (Rect{640, 0, 640, 720}) {
		t.Fatalf("SplitV rects %+v %+v", a, b)
	}
	if a.W+b.W != 1280 || a.H != 720 || b.H != 720 {
		t.Fatal("SplitV does not cover the scanout")
	}
	a, b, ok = SplitRects(SplitHoriz, 1280, 720)
	if !ok {
		t.Fatal("SplitH 1280x720")
	}
	if a != (Rect{0, 0, 1280, 360}) || b != (Rect{0, 360, 1280, 360}) {
		t.Fatalf("SplitH rects %+v %+v", a, b)
	}
	if a.H+b.H != 720 {
		t.Fatal("SplitH does not cover the scanout")
	}
	// Remainder goes to the far pane.
	a, b, ok = SplitRects(SplitVert, 1281, 720)
	if !ok || a.W != 640 || b.W != 641 || a.W+b.W != 1281 {
		t.Fatalf("odd SplitV %+v %+v ok=%v", a, b, ok)
	}
	if _, _, ok = SplitRects(SplitVert, 200, 720); ok {
		t.Fatal("SplitV 200-wide should miss PaneMinW")
	}
	if _, _, ok = SplitRects(SplitHoriz, 1280, 200); ok {
		t.Fatal("SplitH 200-tall should miss PaneMinH")
	}
	fullA, fullB, ok := SplitRects(SplitNone, 1280, 720)
	if !ok || fullA != FullRect(1280, 720) || fullB != fullA {
		t.Fatalf("SplitNone %+v %+v ok=%v", fullA, fullB, ok)
	}
}

func TestLayoutLineAndDumpMatch(t *testing.T) {
	line := layoutLine(5, "Calc", Rect{640, 0, 640, 720}, true, SplitVert)
	want := "tab=5 bin=Calc x=640 y=0 w=640 h=720 focus=1 split=v"
	if line != want {
		t.Fatalf("layoutLine = %q want %q", line, want)
	}
	pane := paneLine(5, Rect{640, 0, 640, 720})
	if pane != "id=5 x=640 y=0 w=640 h=720" {
		t.Fatalf("paneLine = %q", pane)
	}
	if line := layoutLine(1, "", FullRect(1280, 720), false, SplitNone); line !=
		"tab=1 bin=- x=0 y=0 w=1280 h=720 focus=0 split=none" {
		t.Fatalf("empty bin / unsplit: %q", line)
	}
	a, b, _ := SplitRects(SplitVert, 1280, 720)
	if !rectsWithin(a, a, 1) || rectsWithin(a, b, 1) {
		t.Fatal("rectsWithin")
	}
	near := Rect{a.X, a.Y, a.W + 1, a.H}
	if !rectsWithin(a, near, 1) {
		t.Fatal("1px w drift must be within tol")
	}
	far := Rect{a.X, a.Y, a.W + 2, a.H}
	if rectsWithin(a, far, 1) {
		t.Fatal("2px w drift must fail tol=1")
	}
}

func TestPaneRectsNeedTwoTabs(t *testing.T) {
	var s TabStrip
	s.OpenTab(1, "a")
	if _, _, ok := s.PaneRects(1280, 720); ok {
		t.Fatal("one tab must not yield pane rects")
	}
	s.OpenTab(2, "b")
	s.SplitV()
	a, b, ok := s.PaneRects(1280, 720)
	if !ok || a.W != 640 || b.X != 640 {
		t.Fatalf("PaneRects %+v %+v ok=%v", a, b, ok)
	}
}
