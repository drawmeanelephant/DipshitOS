// Package widgets is the M56e (issue #1319) Go widget kit: exactly three
// widgets — Text, Button, List — plus integer layout helpers. It is NOT a
// LIBUI clone; anything beyond these three is a new card with its own
// justification.
//
// The load-bearing rule (the CALC-drift lesson): a widget's Draw and its
// HitTest must read the SAME rectangle. Every widget exposes Bounds() and both
// paths go through it (or through the row rects derived from it), so geometry
// and hit-testing cannot disagree. The host tests pin that agreement, and pin
// that the integer Scale() is the identity at the native canvas — the
// zero-regression fixed point.
//
// No LIBUI, no cgo, no OS surface: a widget only needs a Canvas, which a test
// can record and the guest can back with vi.Filler.
package widgets

import "virelai/theme"

// Rect is an axis-aligned rectangle in integer canvas coordinates. Right and
// Bottom are exclusive, matching the compositor's left-inclusive convention.
type Rect struct{ X, Y, W, H int }

// Contains reports whether (x, y) is inside the rect (right/bottom exclusive).
func (r Rect) Contains(x, y int) bool {
	return x >= r.X && x < r.X+r.W && y >= r.Y && y < r.Y+r.H
}

// Right and Bottom are the exclusive edges.
func (r Rect) Right() int  { return r.X + r.W }
func (r Rect) Bottom() int { return r.Y + r.H }

// Empty reports a rect with no drawable area.
func (r Rect) Empty() bool { return r.W <= 0 || r.H <= 0 }

// Inset shrinks the rect by n on every side, never past empty.
func (r Rect) Inset(n int) Rect {
	w := r.W - 2*n
	h := r.H - 2*n
	if w < 0 {
		w = 0
	}
	if h < 0 {
		h = 0
	}
	return Rect{r.X + n, r.Y + n, w, h}
}

// Canvas is the minimal drawing surface a widget needs. Tests supply a
// recording canvas; the guest supplies one that batches into vi.Filler.
type Canvas interface {
	FillRect(r Rect, rgb uint32)
}

// Widget is the three-method shape every widget satisfies.
type Widget interface {
	Bounds() Rect
	HitTest(x, y int) bool
	Draw(c Canvas)
}

// Scale maps r from a fromW x fromH canvas into toW x toH, integer math only,
// rounding toward the top-left so grids never spill. At the identity mapping
// (to == from) every rect maps to itself exactly — the zero-regression fixed
// point, the same rule as lib/tabapp.zig's scale.
func Scale(r Rect, fromW, fromH, toW, toH int) Rect {
	if fromW <= 0 || fromH <= 0 {
		return r
	}
	if fromW == toW && fromH == toH {
		return r
	}
	sx := func(v int) int { return v * toW / fromW }
	sy := func(v int) int { return v * toH / fromH }
	out := Rect{sx(r.X), sy(r.Y), sx(r.W), sy(r.H)}
	if out.W < 1 {
		out.W = 1
	}
	if out.H < 1 {
		out.H = 1
	}
	return out
}

// --- integer layout helpers -------------------------------------------------

// Row lays out n boxes of w x h left-to-right from (x, y), separated by gap.
func Row(x, y, w, h, gap, n int) []Rect {
	if n <= 0 {
		return nil
	}
	out := make([]Rect, n)
	for i := range out {
		out[i] = Rect{x + i*(w+gap), y, w, h}
	}
	return out
}

// Column lays out n boxes of w x h top-to-bottom from (x, y), separated by gap.
func Column(x, y, w, h, gap, n int) []Rect {
	if n <= 0 {
		return nil
	}
	out := make([]Rect, n)
	for i := range out {
		out[i] = Rect{x, y + i*(h+gap), w, h}
	}
	return out
}

// --- Text -------------------------------------------------------------------

// Text is a single line of label text in a bounded plate. Draw paints the
// plate (and clipped glyph cells); HitTest tests the same plate.
type Text struct {
	R     Rect
	Label string
	Fg    uint32
	Bg    uint32
}

// Bounds is the plate — the ONE rect Draw and HitTest both read.
func (t *Text) Bounds() Rect { return t.R }

// HitTest agrees with Bounds by construction.
func (t *Text) HitTest(x, y int) bool { return t.R.Contains(x, y) }

// Draw paints the plate then a run of fixed glyph cells clipped inside it.
func (t *Text) Draw(c Canvas) {
	if t.R.Empty() {
		return
	}
	c.FillRect(t.R, t.Bg)
	drawGlyphRun(c, t.R, t.Label, t.Fg)
}

// --- Button -----------------------------------------------------------------

// Button is a labelled, framed control. Its Bounds is the OUTER framing rect —
// the same rect HitTest tests, so the border is grabbable.
//
// Face/Border/LabelRGB of 0 mean "use the theme table". Hover/press/focus
// colours always come from the table (M69c #1530). Apps that already have
// pointer events set Hovered/Pressed; this package does not add an event ABI.
type Button struct {
	R        Rect
	Label    string
	Face     uint32
	Border   uint32
	LabelRGB uint32
	Hovered  bool
	Pressed  bool
	Focused  bool
}

// Bounds is the outer frame.
func (b *Button) Bounds() Rect { return b.R }

// HitTest agrees with Bounds by construction.
func (b *Button) HitTest(x, y int) bool { return b.R.Contains(x, y) }

// Draw paints the border, the inset face, then the centred label run.
func (b *Button) Draw(c Canvas) {
	if b.R.Empty() {
		return
	}
	face, border, label := b.colors()
	c.FillRect(b.R, border)
	inner := b.R.Inset(theme.Current.BorderW)
	if !inner.Empty() {
		c.FillRect(inner, face)
		drawGlyphRun(c, inner, b.Label, label)
	}
}

// colors resolves idle/hover/press/focus from the token table. A non-zero
// Face/Border/LabelRGB is an idle override (existing callers keep their hex
// until they migrate); hover/press/focus still take contrast from the table.
func (b *Button) colors() (face, border, label uint32) {
	t := theme.Current
	face, border, label = t.BtnIdle, t.Border, t.Text
	if b.Face != 0 {
		face = b.Face
	}
	if b.Border != 0 {
		border = b.Border
	}
	if b.LabelRGB != 0 {
		label = b.LabelRGB
	}
	switch {
	case b.Pressed:
		face = t.BtnPressed
		border = t.Accent
	case b.Hovered:
		face = t.BtnHover
		border = t.Accent
	case b.Focused:
		border = t.Accent
	}
	return face, border, label
}

// --- List -------------------------------------------------------------------

// List is a fixed-row-height list of items with an optional selection. Row i
// occupies RowRect(i); Draw and ItemAt derive from the SAME RowRect.
type List struct {
	R     Rect
	Items []string
	RowH  int
	Sel   int
	Fg    uint32
	Bg    uint32
	SelBg uint32
}

// Bounds is the list's full rect.
func (l *List) Bounds() Rect { return l.R }

// HitTest agrees with Bounds by construction.
func (l *List) HitTest(x, y int) bool { return l.R.Contains(x, y) }

// RowRect is row i's rect — the single geometry source for Draw and ItemAt.
func (l *List) RowRect(i int) Rect {
	h := l.RowH
	if h <= 0 {
		h = 1
	}
	return Rect{l.R.X, l.R.Y + i*h, l.R.W, h}
}

// VisibleRows is how many rows fit between the top and the bottom edge.
func (l *List) VisibleRows() int {
	h := l.RowH
	if h <= 0 {
		h = 1
	}
	if l.R.H <= 0 {
		return 0
	}
	return l.R.H / h
}

// ItemAt returns the row index a point hits, or -1. It uses the same
// arithmetic as RowRect, so a point inside RowRect(i) always maps to i.
func (l *List) ItemAt(x, y int) int {
	if !l.R.Contains(x, y) {
		return -1
	}
	h := l.RowH
	if h <= 0 {
		h = 1
	}
	i := (y - l.R.Y) / h
	if i < 0 || i >= len(l.Items) {
		return -1
	}
	return i
}

// Draw paints the list background, the selected row, then each row's label.
func (l *List) Draw(c Canvas) {
	if l.R.Empty() {
		return
	}
	c.FillRect(l.R, l.Bg)
	for i := range l.Items {
		rr := l.RowRect(i)
		if rr.Y >= l.R.Bottom() {
			break
		}
		clip := rr
		if clip.Bottom() > l.R.Bottom() {
			clip.H = l.R.Bottom() - clip.Y
		}
		if i == l.Sel {
			c.FillRect(clip, l.SelBg)
		}
		drawGlyphRun(c, clip, l.Items[i], l.Fg)
	}
}

// drawGlyphRun paints one fixed-cell "glyph" per rune, clipped to the plate.
// It is deliberately crude (6x8 cells) — a placeholder ink run, not a font,
// so the widget's geometry stays the thing under test.
func drawGlyphRun(c Canvas, plate Rect, s string, rgb uint32) {
	const cellW, cellH = 6, 8
	inner := plate.Inset(2)
	if inner.Empty() {
		return
	}
	y := inner.Y + (inner.H-cellH)/2
	if y < inner.Y {
		y = inner.Y
	}
	i := 0
	for range s {
		x := inner.X + i*cellW
		if x+cellW > inner.Right() {
			break
		}
		c.FillRect(Rect{x, y, cellW - 2, cellH}, rgb)
		i++
	}
}
