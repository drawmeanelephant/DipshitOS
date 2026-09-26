package tabapp

import (
	"os"
	"regexp"
	"strconv"
	"testing"

	"virelai/vi"
)

// TestCellGridPinsKernel is M73j's (#1636) deliverable-4 agreement pin:
// for the same rect, CellGrid's cells equal the kernel's painted numbers —
// cols = clamp(w/cellW, 8, 80) (terminal.zig syncWindowCols -> setCols) and
// rows = (h-16)/cellH (driving_award.zig rows_visible, title_bar_h = 16).
// M73l (#1661): cellW=8, cellH=16 — FiraCode's advance at pixel size 13.
// The card's prose said `rows = h/cellH`; the painted viewport excludes the
// 16 px title band, so h/8 would hand a TUI rows the grid never renders —
// the measured kernel formula is the one pinned here (the PR carries the
// finding).
// M80i (#1725): the pin runs at EVERY rung of the zoom ladder (7x13 / 8x16
// / 10x21 — vi.TerminalCellForSize): the cell moved, the formulas did not.
func TestCellGridPinsKernel(t *testing.T) {
	rects := []struct{ w, h uint32 }{
		{640, 400},  // charmhello/term classic rect: (400-16)/16
		{512, 384},  // the 512px tabapp default: (384-16)/16
		{128, 64},   // the resize clamp floor (128x64): (64-16)/16
		{1024, 720}, // cols clamp high: 1024/8=128 -> 80
		{48, 40},    // cols clamp low: 48/8=6 -> 8
		{64, 16},    // no client area: kernel's `else 1`
		{611, 371},  // the class-B shrink target (669,429)-(640,400)
	}
	rungs := []struct {
		name         string
		cellW, cellH uint32
		want         [][2]int // cols, rows per rect
	}{
		{"small 7x13", 7, 13, [][2]int{
			{80, 29}, {73, 28}, {18, 3}, {80, 54}, {8, 1}, {9, 1}, {80, 27},
		}},
		{"medium 8x16 (the boot look)", 8, 16, [][2]int{
			{80, 24}, {64, 23}, {16, 3}, {80, 44}, {8, 1}, {8, 1}, {76, 22},
		}},
		{"large 10x21", 10, 21, [][2]int{
			{64, 18}, {51, 17}, {12, 2}, {80, 33}, {8, 1}, {8, 1}, {61, 16},
		}},
	}
	for _, r := range rungs {
		for i, rc := range rects {
			cols, rows := CellGrid(rc.w, rc.h, r.cellW, r.cellH)
			if cols != r.want[i][0] || rows != r.want[i][1] {
				t.Errorf("CellGrid(%d,%d,%d,%d) = %dx%d, want %dx%d (kernel formulas, %s)",
					rc.w, rc.h, r.cellW, r.cellH, cols, rows, r.want[i][0], r.want[i][1], r.name)
			}
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
		cols, rows = CellGrid(r[0], r[1], 8, 16)
	}
	if cols != 76 || rows != 22 {
		t.Fatalf("converged = %dx%d, want 76x22 (the latest rect)", cols, rows)
	}
}

// TestTerminalCellForSizePinsKernelAtlas (M80i #1725): the rung table Go
// apps size their grids with IS the kernel's own rasterized cell — parse
// kernel/src/font_atlas_data.zig's three generated size blocks and require
// vi.TerminalCellForSize to agree cell for cell. The fixture is generated
// (zig run user/src/lib/font_atlas_gen.zig) and pinned byte-for-byte by
// the generator's own tripwire, so this is the same ground truth the
// kernel paints with.
func TestTerminalCellForSizePinsKernelAtlas(t *testing.T) {
	src, err := os.ReadFile("../../../kernel/src/font_atlas_data.zig")
	if err != nil {
		t.Fatalf("read kernel/src/font_atlas_data.zig: %v (this test only runs in-tree)", err)
	}
	re := regexp.MustCompile(`pub const (small|medium|large) = struct \{[\s\S]*?pub const cell_w: u32 = (\d+);[\s\S]*?pub const cell_h: u32 = (\d+);`)
	ms := re.FindAllStringSubmatch(string(src), -1)
	if len(ms) != 3 {
		t.Fatalf("font_atlas_data.zig: parsed %d size blocks, want 3", len(ms))
	}
	for _, m := range ms {
		name := m[1]
		cw, err1 := strconv.Atoi(m[2])
		ch, err2 := strconv.Atoi(m[3])
		if err1 != nil || err2 != nil {
			t.Fatalf("font_atlas_data.zig %s: bad cell numbers %q x %q", name, m[2], m[3])
		}
		gotW, gotH := vi.TerminalCellForSize(name)
		if int(gotW) != cw || int(gotH) != ch {
			t.Errorf("TerminalCellForSize(%q) = %dx%d, kernel atlas %dx%d", name, gotW, gotH, cw, ch)
		}
	}
}

// TestTerminalCellForSettingsMapsTheStore (M80i #1725): the value-level
// mirror — the kernel's apply_font_size vocabulary (the names and their
// M20 aliases) onto the same three cells; a later row wins (kernel
// set_internal semantics); an absent or unrecognized value applies
// NOTHING (settings.zig), so the mirror keeps the rung in force (the boot
// look, MEDIUM 8x16, before the first valid row). Every case runs after
// the same MEDIUM setup so the mirror's per-process state cannot order
// the table.
func TestTerminalCellForSettingsMapsTheStore(t *testing.T) {
	cases := []struct {
		body string
		w, h uint32
	}{
		{"#v2\n", 8, 16},                  // absent: the boot look
		{"#v2\nfont_size=small\n", 7, 13}, // the rung names
		{"#v2\nfont_size=medium\n", 8, 16},
		{"#v2\nfont_size=large\n", 10, 21},
		{"#v2\nfont_size=small\nfont_size=large\n", 10, 21}, // a later row wins
		{"#v2\nfont_size=0\n", 7, 13},                       // the M20 aliases
		{"#v2\nfont_size=8x8\n", 7, 13},
		{"#v2\nfont_size=1\n", 8, 16},
		{"#v2\nfont_size=16x16\n", 8, 16},
		{"#v2\nfont_size=2\n", 10, 21},
		{"#v2\nfont_size=24x24\n", 10, 21},
		{"#v2\nfont_size=bogus\n", 8, 16},              // the kernel ignores it
		{"#v2\n font_size = large \n", 10, 21},         // parse_line trims
		{"#v2\n#comment=1\nfont_size=large\n", 10, 21}, // other rows skipped
	}
	for _, c := range cases {
		vi.TerminalCellForSettings([]byte("font_size=medium\n")) // establish the rung in force
		gotW, gotH := vi.TerminalCellForSettings([]byte(c.body))
		if gotW != c.w || gotH != c.h {
			t.Errorf("TerminalCellForSettings(%q) = %dx%d, want %dx%d", c.body, gotW, gotH, c.w, c.h)
		}
	}
}

// TestTerminalCellForSettingsAppliesNothing (M80i #1791 review footnote
// 1): the kernel's apply_font_size maps an absent or unrecognized value
// to NOTHING applied — both ladders keep what they had (settings.zig) —
// and the mirror must follow. Before this pinned, a stored garbage row
// fell back to 8x16 while the kernel grid kept, say, 10x21: the app then
// derived a medium grid against a large one on the next plain WIN_RESIZE.
func TestTerminalCellForSettingsAppliesNothing(t *testing.T) {
	vi.TerminalCellForSettings([]byte("font_size=large\n"))
	for _, body := range []string{
		"#v2\nfont_size=bogus\n", // garbage: applies nothing
		"#v2\n",                  // absent: applies nothing
		"#v2\nfont_size=\n",      // empty value: applies nothing
	} {
		gotW, gotH := vi.TerminalCellForSettings([]byte(body))
		if gotW != 10 || gotH != 21 {
			t.Errorf("TerminalCellForSettings(%q) after large = %dx%d, want 10x21 (applies nothing)", body, gotW, gotH)
		}
	}
	vi.TerminalCellForSettings([]byte("font_size=small\n"))
	gotW, gotH := vi.TerminalCellForSettings([]byte("#v2\nfont_size=bogus\n"))
	if gotW != 7 || gotH != 13 {
		t.Errorf("after small, garbage = %dx%d, want 7x13 (applies nothing)", gotW, gotH)
	}
}
