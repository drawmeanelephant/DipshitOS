package tabapp

import (
	"testing"

	"virelai/vi"
)

// On the host every vi call degrades, so Init reports the honest failure
// rather than fabricating a window.
func TestInitHostFails(t *testing.T) {
	if ta := Init(Config{Name: "T.ELF", Title: "T", W: 100, H: 100}); ta != nil {
		t.Fatalf("host Init = %+v want nil", ta)
	}
}

func TestDispatchTracksCanvas(t *testing.T) {
	ta := &TabApp{Win: 4, W: 512, H: 340}
	if a := ta.Dispatch(vi.Event{Kind: vi.EvMouseDown}); a != ActionNone {
		t.Fatalf("mouse action = %v", a)
	}
	if a := ta.Dispatch(vi.Event{Kind: vi.EvWinResize, Arg0: 1100, Arg1: 720}); a != ActionResized {
		t.Fatalf("resize action = %v", a)
	}
	if ta.W != 1100 || ta.H != 720 {
		t.Fatalf("canvas not tracked: %d x %d", ta.W, ta.H)
	}
	if a := ta.Dispatch(vi.Event{Kind: vi.EvWinClose}); a != ActionClosed {
		t.Fatalf("close action = %v", a)
	}
}

// Scale is the identity at the native canvas — the zero-regression fixed point.
func TestScaleIdentity(t *testing.T) {
	r := Rect{8, 104, 56, 20}
	if got := Scale(r, 512, 340, 512, 340); got != r {
		t.Fatalf("identity scale changed %+v -> %+v", r, got)
	}
}

func TestScaleMapsProportionally(t *testing.T) {
	r := Rect{8, 104, 56, 20}
	got := Scale(r, 512, 340, 1100, 720)
	if got.X != 8*1100/512 || got.Y != 104*720/340 || got.W != 56*1100/512 || got.H != 20*720/340 {
		t.Fatalf("scale = %+v", got)
	}
	if got.X+got.W > 1100 || got.Y+got.H > 720 {
		t.Fatalf("content spills the canvas: %+v", got)
	}
	// Never zero-size.
	tiny := Scale(Rect{0, 0, 1, 1}, 512, 340, 1100, 720)
	if tiny.W < 1 || tiny.H < 1 {
		t.Fatalf("zero-size scaled rect: %+v", tiny)
	}
}

func TestLayoutTracksCanvas(t *testing.T) {
	ta := &TabApp{W: 1100, H: 720}
	got := ta.Layout(Rect{8, 104, 56, 20}, 512, 340)
	if got.X+got.W > 1100 || got.Y+got.H > 720 {
		t.Fatalf("layout spills: %+v", got)
	}
}
