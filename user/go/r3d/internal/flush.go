package internal

// FillSink receives one horizontal fill run (the ADR 0007 fill batcher
// speaks rectangles, so a frame is decomposed into row runs).
type Sink interface {
	Rect(x, y, w, h int, r, g, b uint8)
}

// FlushRuns walks the image top to bottom and coalesces every maximal
// horizontal run of equal color into one Rect. It is the only path the
// rasterized frame takes to the window, so the guest paints exactly the
// pixels the host tests verified.
func FlushRuns(im *Image, s Sink) {
	if im == nil || im.Pix == nil {
		return
	}
	for y := 0; y < im.H; y++ {
		x := 0
		for x < im.W {
			r0, g0, b0 := im.GetPx(x, y)
			w := 1
			for x+w < im.W {
				r1, g1, b1 := im.GetPx(x+w, y)
				if r1 != r0 || g1 != g0 || b1 != b0 {
					break
				}
				w++
			}
			s.Rect(x, y, w, 1, r0, g0, b0)
			x += w
		}
	}
}
