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
// cols = clamp(w/cellW, 8, 80) (terminal.zig syncWindowCols -> setCols:975)
// and rows = (h-16)/cellH (driving_award.zig rows_visible:439, title_bar_h=16).
// M73l (#1661): cellW=8, cellH=16 — FiraCode's advance at pixel size 13.
// The card's prose said `rows=h/cellH`; the painted viewport does NOT include
// the 16 px title band, so h/8 would hand a TUI two rows the grid never
// renders — the measured kernel number is the one pinned here.
// M80i (#1725): the pin runs at EVERY rung of the zoom ladder (7x13 / 8x16
// / 10x21 — vi.TerminalCellForSize): the cell moved, the formulas did not.
func TestSizeMsgPinsKernelCellMath(t *testing.T) {
	rects := []struct{ w, h uint32 }{
		{640, 400},  // charmhello's own rect: 640/8, (400-16)/16
		{512, 384},  // the 512px tab: 512/8, (384-16)/16
		{128, 64},   // the resize clamp floor: 128/8, (64-16)/16
		{1024, 720}, // cols clamp: 1024/8=128 -> 80 (setCols)
		{48, 40},    // cols clamp low: 48/8=6 -> 8 (setCols)
		{64, 16},    // no client area: kernel's `else 1` branch
	}
	rungs := []struct {
		name         string
		cellW, cellH uint32
		want         [][2]int // cols, rows per rect
	}{
		{"small 7x13", 7, 13, [][2]int{
			{80, 29}, {73, 28}, {18, 3}, {80, 54}, {8, 1}, {9, 1},
		}},
		{"medium 8x16 (the boot look)", 8, 16, [][2]int{
			{80, 24}, {64, 23}, {16, 3}, {80, 44}, {8, 1}, {8, 1},
		}},
		{"large 10x21", 10, 21, [][2]int{
			{64, 18}, {51, 17}, {12, 2}, {80, 33}, {8, 1}, {8, 1},
		}},
	}
	for _, r := range rungs {
		for i, rc := range rects {
			got := sizeMsg(rc.w, rc.h, r.cellW, r.cellH)
			if got.Width != r.want[i][0] || got.Height != r.want[i][1] {
				t.Errorf("sizeMsg(%d,%d,%d,%d) = %dx%d, want %dx%d (kernel formulas, %s)",
					rc.w, rc.h, r.cellW, r.cellH, got.Width, got.Height, r.want[i][0], r.want[i][1], r.name)
			}
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
		sizeMsg(640, 400, 8, 16),
		sizeMsg(704, 448, 8, 16),
		sizeMsg(768, 496, 8, 16),
	} {
		next, _ := m.Update(ws)
		m = next.(model)
	}
	// M80i (#1725): the 96x60 pin was pre-M73l arithmetic ((496-16)/8 —
	// the 8x8 cell era); the M73l cell is 16 tall, so the latest rect
	// converges to 96x30 (the same /16 the live gates pin at 64x23).
	if m.cols != 96 || m.rows != 30 {
		t.Fatalf("converged size = %dx%d, want 96x30 (the latest)", m.cols, m.rows)
	}
}
