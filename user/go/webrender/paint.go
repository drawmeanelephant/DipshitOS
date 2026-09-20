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
			// The engine the layout was measured with, so wrap and paint agree.
			engine := l.Text
			if engine == nil {
				engine = Bitmap{}
			}
			engine.Paint(s, ox+it.X, y, it.Text,
				Style{Size: it.Size, Mono: it.Mono, Bold: it.Bold, Italic: it.Italic}, it.Color, clip)
		case ItemImage:
			if it.Img != nil {
				drawImage(s, clip, ox+it.X, y, it)
			} else {
				drawImageBox(s, clip, ox+it.X, y, it)
			}
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

// drawImage blits a decoded raster into its box, nearest-neighbour scaled, with
// horizontally identical pixels merged into one span (the fill syscall takes a
// rect, so runs are how an image reaches the scanout at all). Anything outside
// the clip is dropped.
func drawImage(s Surface, c Clip, x, y int, it Item) {
	img := it.Img
	if img == nil || it.W <= 0 || it.H <= 0 {
		return
	}
	for row := 0; row < it.H; row++ {
		py := y + row
		if py < c.Y || py >= c.Y+c.H {
			continue
		}
		sy := row * img.Height / it.H
		if sy >= img.Height {
			sy = img.Height - 1
		}
		runStart, runLen := 0, 0
		var runColor uint32
		flush := func(end int) {
			if runLen == 0 {
				return
			}
			px, w := x+runStart, runLen
			if px < c.X {
				w -= c.X - px
				px = c.X
			}
			if px+w > c.X+c.W {
				w = c.X + c.W - px
			}
			if w > 0 {
				s.Fill(px, py, w, 1, runColor&0x00ffffff)
			}
			runLen = 0
			runStart = end
		}
		for col := 0; col < it.W; col++ {
			sx := col * img.Width / it.W
			if sx >= img.Width {
				sx = img.Width - 1
			}
			// Force the alpha byte opaque: the fill path is 24-bit RGB.
			col8 := img.Pix[sy*img.Width+sx] & 0x00ffffff
			if runLen == 0 {
				runStart, runColor, runLen = col, col8, 1
				continue
			}
			if col8 == runColor {
				runLen++
				continue
			}
			flush(col)
			runStart, runColor, runLen = col, col8, 1
		}
		flush(it.W)
	}
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
