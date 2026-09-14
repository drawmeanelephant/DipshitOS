package webrender

import "virelai/webrender/font"

// Paint draws a laid-out document into s. The content box starts at (ox, oy)
// and is (vw, vh) pixels; `scroll` shifts the content up by that many pixels.
// Everything is clipped to the content box so page paint can never spill into
// the browser chrome drawn in the same window.
func Paint(l *Layout, s Surface, ox, oy, vw, vh, scroll int) {
	if vw <= 0 || vh <= 0 {
		return
	}
	clip := Clip{X: ox, Y: oy, W: vw, H: vh}
	for _, it := range l.Items {
		y := oy + it.Y - scroll
		if y >= clip.Y+clip.H || y+it.H <= clip.Y {
			continue
		}
		switch it.Kind {
		case ItemRect:
			fillClipped(s, clip, ox+it.X, y, it.W, it.H, it.Bg)
		case ItemRule:
			fillClipped(s, clip, ox+it.X, y, it.W, it.H, it.Color)
		case ItemText:
			DrawText(s, ox+it.X, y, it.Text, it.Size, it.Bold, it.Color, clip)
		case ItemImage:
			drawImageBox(s, clip, ox+it.X, y, it)
		}
	}
}

// HitTest returns the link target under the content point (content
// coordinates, i.e. viewport point + scroll) — "" when none.
func HitTest(l *Layout, cx, cy int) string {
	for i := len(l.Links) - 1; i >= 0; i-- {
		k := l.Links[i]
		if cx >= k.X && cx < k.X+k.W && cy >= k.Y && cy < k.Y+k.H {
			return k.Target
		}
	}
	return ""
}

func fillClipped(s Surface, c Clip, x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 {
		return
	}
	x0, y0, x1, y1 := x, y, x+w, y+h
	if x0 < c.X {
		x0 = c.X
	}
	if y0 < c.Y {
		y0 = c.Y
	}
	if x1 > c.X+c.W {
		x1 = c.X + c.W
	}
	if y1 > c.Y+c.H {
		y1 = c.Y + c.H
	}
	if x1 <= x0 || y1 <= y0 {
		return
	}
	s.Fill(x0, y0, x1-x0, y1-y0, rgb)
}

func drawImageBox(s Surface, c Clip, x, y int, it Item) {
	fillClipped(s, c, x, y, it.W, it.H, ColorSurface)
	fillClipped(s, c, x, y, it.W, 1, ColorRule)
	fillClipped(s, c, x, y+it.H-1, it.W, 1, ColorRule)
	fillClipped(s, c, x, y, 1, it.H, ColorRule)
	fillClipped(s, c, x+it.W-1, y, 1, it.H, ColorRule)
	label := UpperASCII(it.Text)
	cols := (it.W - 8) / font.Advance(1)
	if cols < 1 {
		cols = 1
	}
	if len(label) > cols {
		label = label[:cols]
	}
	DrawText(s, x+4, y+it.H/2-4, label, 1, false, ColorMuted, c)
}

// ChromeHeight is how many pixels the browser chrome occupies above the page
// viewport (title band + URL bar). Exported so the browser and its tests
// agree on the geometry.
const ChromeHeight = 34

// StatusHeight is the status line height at the bottom of the window.
const StatusHeight = 12
