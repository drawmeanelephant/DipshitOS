package tabapp

import "testing"

// TestCellGridPinsKernel is M73j's (#1636) deliverable-4 agreement pin:
// for the same rect, CellGrid's cells equal the kernel's painted numbers —
// cols = clamp(w/8, 8, 80) (terminal.zig syncWindowCols -> setCols) and
// rows = (h-16)/8 (driving_award.zig rows_visible, title_bar_h = 16).
// The card's prose said `rows = h/8`; the painted viewport excludes the
// 16 px title band, so h/8 would hand a TUI rows the grid never renders —
// the measured kernel formula is the one pinned here (the PR carries the
// finding).
func TestCellGridPinsKernel(t *testing.T) {
	cases := []struct {
		w, h       uint32
		cols, rows int
	}{
		{640, 400, 80, 48},  // charmhello/term classic rect
		{512, 384, 64, 46},  // the 512px tabapp default
		{128, 64, 16, 6},    // the resize clamp floor (128x64)
		{1024, 720, 80, 88}, // cols clamp high: 1024/8=128 -> 80
		{48, 40, 8, 3},      // cols clamp low: 48/8=6 -> 8
		{64, 16, 8, 1},      // no client area: kernel's `else 1`
		{611, 371, 76, 44},  // the class-B shrink target (669,429)-(640,400)
	}
	for _, c := range cases {
		cols, rows := CellGrid(c.w, c.h)
		if cols != c.cols || rows != c.rows {
			t.Errorf("CellGrid(%d,%d) = %dx%d, want %dx%d (kernel formulas)",
				c.w, c.h, cols, rows, c.cols, c.rows)
		}
	}
}

// TestCellGridMonotoneConverges: a consumer applying rects in arrival order
// (the pass-all policy M73j chose over kernel coalescing — events.zig is
// drop-oldest, so the newest resize always survives) ends at the LAST
// rect's cells.
func TestCellGridMonotoneConverges(t *testing.T) {
	seq := [][2]uint32{{640, 400}, {671, 431}, {611, 371}}
	var cols, rows int
	for _, r := range seq {
		cols, rows = CellGrid(r[0], r[1])
	}
	if cols != 76 || rows != 44 {
		t.Fatalf("converged = %dx%d, want 76x44 (the latest rect)", cols, rows)
	}
}
