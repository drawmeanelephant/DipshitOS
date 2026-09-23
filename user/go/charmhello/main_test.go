//go:build virelai || charmhello

package main

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestModelTogglesFromTeaKeyPress(t *testing.T) {
	next, _ := (model{}).Update(tea.KeyPressMsg(tea.Key{Text: " "}))
	got := next.(model)
	if !got.paused {
		t.Fatal("space did not toggle the Bubble Tea model")
	}
	if !strings.Contains(got.View().Content, "PAUSED") {
		t.Fatal("paused model view did not render the paused state")
	}
}

func TestModelQuitsFromTeaKeyPress(t *testing.T) {
	next, _ := (model{}).Update(tea.KeyPressMsg(tea.Key{Text: "q"}))
	if !next.(model).quit {
		t.Fatal("q did not request model shutdown")
	}
}

func TestViewCarriesBoundedAnsiSurface(t *testing.T) {
	view := (model{}).View().Content
	for _, want := range []string{"\x1b[?1049h", "\x1b[1;95m", "bound /dev/tty"} {
		if !strings.Contains(view, want) {
			t.Fatalf("view missing %q", want)
		}
	}
}

// TestSizeMsgPinsKernelCellMath is M73j's (#1636) deliverable-4 agreement
// pin: for the same rect, sizeMsg's cells equal the kernel's formulas —
// cols = clamp(w/8, 8, 80) (terminal.zig syncWindowCols -> setCols:975)
// and rows = (h-16)/8 (driving_award.zig rows_visible:439, title_bar_h=16).
// The card's prose said `rows=h/8`; the painted viewport does NOT include
// the 16 px title band, so h/8 would hand a TUI two rows the grid never
// renders — the measured kernel number is the one pinned here.
func TestSizeMsgPinsKernelCellMath(t *testing.T) {
	cases := []struct {
		w, h       uint32
		cols, rows int
	}{
		{640, 400, 80, 48},  // charmhello's own rect: 640/8, (400-16)/8
		{512, 384, 64, 46},  // the 512px tab: 512/8, (384-16)/8
		{128, 64, 16, 6},    // the resize clamp floor: 128/8, (64-16)/8
		{1024, 720, 80, 88}, // cols clamp: 1024/8=128 -> 80 (setCols)
		{48, 40, 8, 3},      // cols clamp low: 48/8=6 -> 8 (setCols)
		{64, 16, 8, 1},      // no client area: kernel's `else 1` branch
	}
	for _, c := range cases {
		got := sizeMsg(c.w, c.h)
		if got.Width != c.cols || got.Height != c.rows {
			t.Errorf("sizeMsg(%d,%d) = %dx%d, want %dx%d (kernel formulas)",
				c.w, c.h, got.Width, got.Height, c.cols, c.rows)
		}
	}
}

// TestUpdateHandlesWindowSize: the message shape Update consumes — stored
// on the model and rendered in the View, so the serial marker and the
// scanout both carry it.
func TestUpdateHandlesWindowSize(t *testing.T) {
	next, _ := (model{}).Update(tea.WindowSizeMsg{Width: 80, Height: 48})
	got := next.(model)
	if got.cols != 80 || got.rows != 48 {
		t.Fatalf("size stored = %dx%d, want 80x48", got.cols, got.rows)
	}
	if !strings.Contains(got.View().Content, "80x48") {
		t.Fatal("view does not render the size line")
	}
}

// TestResizeConvergesToLatest is the consumer half of deliverable 1's
// coalesce measure: the kernel queue is 16-slot drop-oldest (events.zig
// push), so under a rapid drag the app may see a pruned subsequence —
// pass-all application in arrival order must end at the LAST size.
func TestResizeConvergesToLatest(t *testing.T) {
	m := model{}
	for _, ws := range []tea.WindowSizeMsg{
		sizeMsg(640, 400),
		sizeMsg(704, 448),
		sizeMsg(768, 496),
	} {
		next, _ := m.Update(ws)
		m = next.(model)
	}
	if m.cols != 96 || m.rows != 60 {
		t.Fatalf("converged size = %dx%d, want 96x60 (the latest)", m.cols, m.rows)
	}
}
