package webrender

import "virelai/ttf"

// The renderer's text seam.
//
// Layout measures text and Paint draws it. If those two used different metrics
// the page would wrap to one width and paint at another, so they share ONE
// engine: Layout carries the engine it was laid out with, and Paint uses that.
//
// Two engines exist. Fonts wraps real TrueType faces (proportional advances,
// coverage anti-aliasing); Bitmap is the built-in 8x8 face scaled by integer
// factors. Bitmap is not a test double — it is the documented fallback: a
// missing, unreadable, or rejected font must cost typography, never the page.
// ADR 0028's consequence note says exactly this: "a silent fallback to the 8x8
// bitmap would change metrics", which is why the fallback is visible, logged by
// the app, and asserted by a gate rather than assumed.

// TextEngine measures and paints text for one renderer.
type TextEngine interface {
	// Measure is the pixel width of a run at the style's face and size.
	Measure(text string, st Style) int
	// Advance is the per-character cell width for the style (monospace layout
	// and tab stops).
	Advance(st Style) int
	// LineHeight is the height of one line box at the style's size.
	LineHeight(st Style) int
	// Paint draws text with the line box's TOP at (x, top) and returns the
	// advance consumed.
	Paint(s Surface, x, top int, text string, st Style, rgb uint32, c Clip) int
	// Proportional reports whether the engine has real per-glyph advances.
	Proportional() bool
	// Name describes the engine, for the app's serial markers.
	Name() string
}

// MaskSink is implemented by surfaces that can blend an 8-bit coverage mask —
// that is, surfaces that can show real anti-aliasing. A Surface that does not
// implement it still gets the text: the engine falls back to thresholded
// one-pixel-high spans, which is legible without being smooth.
type MaskSink interface {
	// BlitMask composites a glyph mask with its top-left corner at (x, y).
	// Implementations clip to their own bounds.
	BlitMask(x, y int, m *ttf.Mask, rgb uint32)
}

// TrueType pixel sizes per logical size unit. The bitmap face is 8px per unit;
// the TrueType faces are given a larger size for the same unit so body text
// matches the physical scale the Zig desktop's own TrueType rendering uses
// (Inter 14px, Fira Code 13px).
const (
	ttfBodyPx = 13
	ttfMonoPx = 12
	bitmapPx  = 8
)

// Fonts is the TrueType-backed engine. The zero value has no faces and behaves
// exactly like Bitmap, so a renderer that failed to load anything still paints.
type Fonts struct {
	UI   *ttf.Face // Inter (proportional)
	Mono *ttf.Face // Fira Code (monospace)
}

// NewFonts parses the two optional faces. A face that fails to parse is simply
// absent — the caller reports it, the renderer falls back, and nothing panics.
func NewFonts(ui, mono []byte) Fonts {
	var f Fonts
	if len(ui) > 0 {
		if face, err := ttf.Parse(ui); err == nil {
			f.UI = face
		}
	}
	if len(mono) > 0 {
		if face, err := ttf.Parse(mono); err == nil {
			f.Mono = face
		}
	}
	return f
}

// Loaded reports whether any TrueType face is available.
func (f Fonts) Loaded() bool { return f.UI != nil || f.Mono != nil }

// Proportional reports whether the engine has real per-glyph advances.
func (f Fonts) Proportional() bool { return f.UI != nil }

// Name describes the engine for the app's serial markers.
func (f Fonts) Name() string {
	switch {
	case f.UI != nil && f.Mono != nil:
		return "truetype(inter+firacode)"
	case f.UI != nil:
		return "truetype(inter)"
	case f.Mono != nil:
		return "truetype(firacode)"
	}
	return "bitmap8x8"
}

// face is the face a style renders with: the monospace face for a mono style
// that has one, otherwise the UI face. nil means "no TrueType face for this
// style" and the caller falls back to the bitmap.
func (f Fonts) face(st Style) *ttf.Face {
	if st.Mono && f.Mono != nil {
		return f.Mono
	}
	return f.UI
}

// px is the pixel size for a style. Style.Size is a logical scale (1 = body).
func (f Fonts) px(st Style) int {
	n := st.Size
	if n < 1 {
		n = 1
	}
	if st.Mono && f.Mono != nil {
		return ttfMonoPx * n
	}
	return ttfBodyPx * n
}

// Measure implements TextEngine.
func (f Fonts) Measure(text string, st Style) int {
	face := f.face(st)
	if face == nil {
		return Bitmap{}.Measure(text, st)
	}
	return face.Measure(text, f.px(st))
}

// Advance implements TextEngine. The cell is the advance of a wide reference
// rune, so a monospace style keeps its columns lined up.
func (f Fonts) Advance(st Style) int {
	face := f.face(st)
	if face == nil {
		return Bitmap{}.Advance(st)
	}
	return face.AdvancePx('M', f.px(st))
}

// LineHeight implements TextEngine: the face's own ascent+descent+gap, plus a
// pixel of leading so adjacent lines do not touch.
func (f Fonts) LineHeight(st Style) int {
	face := f.face(st)
	if face == nil {
		return Bitmap{}.LineHeight(st)
	}
	asc, desc, gap := face.LineMetrics(f.px(st))
	return asc + desc + gap + 2
}

// Paint implements TextEngine. Text is anchored on the LINE BOX TOP the layout
// produced; the engine converts that to the baseline it needs.
func (f Fonts) Paint(s Surface, x, top int, text string, st Style, rgb uint32, c Clip) int {
	face := f.face(st)
	if face == nil {
		return Bitmap{}.Paint(s, x, top, text, st, rgb, c)
	}
	px := f.px(st)
	asc, _, _ := face.LineMetrics(px)
	baseline := top + asc
	pen := x
	tabStep := face.AdvancePx('M', px) * 4
	for _, r := range text {
		if r == '\t' {
			pen += tabStep
			continue
		}
		m, adv, err := face.Glyph(face.GlyphIndex(r), px)
		if err != nil {
			// A glyph the font cannot decode still occupies its width, so one
			// bad glyph does not reflow the rest of the line.
			pen += face.AdvancePx(r, px)
			continue
		}
		if !m.Empty() {
			blitMask(s, c, pen+m.BearingX, baseline-m.BearingY, m, rgb)
			if st.Bold {
				// No bold face exists; a second strike one pixel over is the
				// same synthetic bold the Zig renderer uses.
				blitMask(s, c, pen+m.BearingX+1, baseline-m.BearingY, m, rgb)
			}
		}
		pen += adv
	}
	return pen - x
}

// blitMask composites a mask, using the surface's own blender when it has one
// and thresholded spans when it does not.
func blitMask(s Surface, c Clip, x, y int, m *ttf.Mask, rgb uint32) {
	if m.Empty() {
		return
	}
	if ms, ok := s.(MaskSink); ok {
		ms.BlitMask(x, y, m, rgb)
		return
	}
	BlitMaskSpans(s, c, x, y, m, rgb)
}

// BlitMaskSpans is the no-mask-capable-surface fallback, exported so a Surface
// that DOES claim MaskSink can still delegate the plain-fill case (the guest's
// window has a direct back-buffer only when the kernel grants one).
//
// It keeps the pixels the glyph covers at least ~38% of, as one-pixel-high
// spans. That is the same threshold the Zig userland's own fallback uses
// (user/src/lib/ui/draw.zig draw_alpha_mask), and it is why text is never
// invisible on a rect-only surface.
func BlitMaskSpans(s Surface, c Clip, x, y int, m *ttf.Mask, rgb uint32) {
	if m.Empty() {
		return
	}
	const cover = 96
	for row := 0; row < m.Height; row++ {
		py := y + row
		if py < c.Y || py >= c.Y+c.H {
			continue
		}
		col := 0
		for col < m.Width {
			for col < m.Width && m.Alpha[row*m.Width+col] < cover {
				col++
			}
			start := col
			for col < m.Width && m.Alpha[row*m.Width+col] >= cover {
				col++
			}
			if col == start {
				continue
			}
			px, w := x+start, col-start
			if px < c.X {
				w -= c.X - px
				px = c.X
			}
			if px+w > c.X+c.W {
				w = c.X + c.W - px
			}
			if w > 0 {
				s.Fill(px, py, w, 1, rgb)
			}
		}
	}
}

// Bitmap is the built-in 8x8 face scaled by integer factors. It needs no file
// and is always available: this is what the renderer degrades to, and it is why
// a missing font never produces a blank page.
type Bitmap struct{}

func bitmapScale(st Style) int {
	s := st.Size
	if s < 1 {
		s = 1
	}
	return s
}

// Measure implements TextEngine.
func (Bitmap) Measure(text string, st Style) int {
	n := 0
	for range text {
		n++
	}
	return n * bitmapPx * bitmapScale(st)
}

// Advance implements TextEngine.
func (Bitmap) Advance(st Style) int { return bitmapPx * bitmapScale(st) }

// LineHeight implements TextEngine.
func (Bitmap) LineHeight(st Style) int { return bitmapPx*bitmapScale(st) + 2 }

// Paint implements TextEngine, emitting glyph rows as spans.
func (Bitmap) Paint(s Surface, x, top int, text string, st Style, rgb uint32, c Clip) int {
	size := bitmapScale(st)
	adv := bitmapPx * size
	// The bitmap face only has ASCII; anything else degrades to '?' so the
	// character stays visible instead of leaving a hole (ADR 0028 D5).
	text = UpperASCII(text)
	cx := x
	for i := 0; i < len(text); i++ {
		ch := rune(text[i])
		if ch == '\t' {
			cx += adv * 4
			continue
		}
		rows := bitmapGlyph(ch)
		bitmapGlyphRows(s, cx, top, rows, size, rgb, c)
		if st.Bold {
			bitmapGlyphRows(s, cx+1, top, rows, size, rgb, c)
		}
		cx += adv
	}
	return cx - x
}

// Proportional implements TextEngine.
func (Bitmap) Proportional() bool { return false }

// Name implements TextEngine.
func (Bitmap) Name() string { return "bitmap8x8" }
