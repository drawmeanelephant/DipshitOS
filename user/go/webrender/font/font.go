// Package font is the browser's text face: the VirelaiOS 8x8 bitmap font,
// scaled by integer factors. It is this project's own glyph data
// (user/src/lib/font8x8.zig, public domain) extracted to Go — no font library
// is linked, and no system font is required for text to appear.
package font

// MinScale and MaxScale bound the integer scale factors the renderer uses.
const (
	MinScale = 1
	MaxScale = 2
)

// Glyph8 returns the 8 rows for a rune (bit 0 = leftmost pixel). Unsupported
// runes fall back to '?' so unknown text stays visible.
func Glyph8(ch rune) [8]byte {
	if ch < 0x20 || ch > 0x7e {
		if ch == ' ' || ch == '\t' {
			return Font8x8[0]
		}
		return Font8x8['?'-0x20]
	}
	return Font8x8[ch-0x20]
}

// Advance returns the per-character advance in pixels at the given scale.
func Advance(size int) int {
	if size < MinScale {
		size = MinScale
	}
	return 8 * size
}

// LineHeight returns the height of one text line at the given scale.
func LineHeight(size int) int {
	if size < MinScale {
		size = MinScale
	}
	return 8*size + 2
}

// Measure returns the pixel width of text at the given scale.
func Measure(text string, size int) int {
	n := 0
	for range text {
		n++
	}
	return n * Advance(size)
}

// LineHeightFor is Measure's sibling for vertical rhythm.
func LineHeightFor(size int) int { return LineHeight(size) }
