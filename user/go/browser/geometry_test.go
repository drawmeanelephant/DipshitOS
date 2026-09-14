package main

import (
	"os"
	"testing"

	"virelai/webrender"
)

// The live gate injects a pointer click at a fixed scanout point. This test
// pins the whole chain on the host: the fixture's first link must contain the
// point the gate clicks, expressed in the window-local coordinates the kernel
// actually delivers (the kernel publishes window-local x/y — see
// kernel/src/driving_award.zig pointer_tick).
func TestGateClickHitsTheFixtureLink(t *testing.T) {
	src, err := os.ReadFile("testdata/gate-page.html")
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	doc := webrender.ParseHTML(src)
	lay := webrender.LayoutDocument(doc, contentW, nil)
	if len(lay.Links) == 0 {
		t.Fatal("fixture has no links")
	}
	link := lay.Links[0]
	if link.Target != "NEXT.HTML" {
		t.Fatalf("first link target = %q", link.Target)
	}
	// Gate injection (scanout 53,82) minus the window origin (40,28) = the
	// window-local point the kernel delivers. The point must land inside a
	// WORD rect, not the space between words (the first live run clicked
	// content x=22, which is the gap between "go" and "to").
	gateScanoutX, gateScanoutY := 53, 82
	localX := gateScanoutX - winX
	localY := gateScanoutY - winY
	// The chrome geometry maps a window-local point into content space.
	if localY < contentY {
		t.Fatalf("gate click y=%d lands in the chrome (content starts at %d)", localY, contentY)
	}
	contentXPoint := localX - contentX
	contentYPoint := localY - contentY
	if target := webrender.HitTest(lay, contentXPoint, contentYPoint); target != "NEXT.HTML" {
		t.Fatalf("gate click (local %d,%d -> content %d,%d) missed the link; links=%v",
			localX, localY, contentXPoint, contentYPoint, lay.Links)
	}
	// And the link must sit above the fold, so the snapshot shows the page
	// that was clicked.
	if link.Y+link.H > contentH {
		t.Fatalf("link outside the viewport: %+v (contentH=%d)", link, contentH)
	}
}

// The chrome must not overlap the kernel's own window title band: the kernel
// paints over the top 16 rows of every user window, so anything the app draws
// there is invisible (observed live).
func TestChromeStartsBelowTheKernelBand(t *testing.T) {
	if titleY < kernelBand {
		t.Fatalf("title band starts at %d, inside the kernel's %d-row band", titleY, kernelBand)
	}
	if contentY >= winH-statusH {
		t.Fatalf("content box is empty: contentY=%d winH=%d statusH=%d", contentY, winH, statusH)
	}
	if backY < titleY+titleH {
		t.Fatalf("chips at y=%d overlap the title band", backY)
	}
	// The chips and the URL field must not collide horizontally.
	if urlX < reloadX+chipW {
		t.Fatalf("URL field starts at %d, overlapping the reload chip", urlX)
	}
}
