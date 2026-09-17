package internal

// countLit counts pixels that differ from the clear color.
func countLit(im *Image, clear RGB) int {
	n := 0
	for y := 0; y < im.H; y++ {
		for x := 0; x < im.W; x++ {
			r, g, b := im.GetPx(x, y)
			if r != clear.R || g != clear.G || b != clear.B {
				n++
			}
		}
	}
	return n
}

func testCam(w, h int) Cam {
	return Cam{
		Pos:    Vec3{X: 0, Y: 0, Z: 4},
		Target: Vec3{X: 0, Y: 0, Z: 0},
		Up:     Vec3{X: 0, Y: 1, Z: 0},
		FovDeg: 50,
		Aspect: float32(w) / float32(h),
		Near:   0.1,
		Far:    100,
	}
}
