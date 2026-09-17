package internal

import "testing"

func drawCube(t *testing.T, w, h int, angle float32) (*Rasterizer, *Image, int) {
	t.Helper()
	im := NewImage(w, h, PixBGRA)
	clear := RGB{R: 0x10, G: 0x10, B: 0x14}
	r := NewRasterizer(im, testCam(w, h), clear)
	r.Reset()
	for _, tr := range Model(Cube(1), Spin(angle)) {
		r.Draw(tr)
	}
	return r, im, countLit(im, clear)
}

// All three vertices behind the eye -> nothing drawn (the clip path). The
// camera sits at z=+4 looking down -z, so world z=+6 is behind it.
func TestClipBehindEye(t *testing.T) {
	im := NewImage(64, 64, PixBGRA)
	clear := RGB{R: 1, G: 2, B: 3}
	r := NewRasterizer(im, testCam(64, 64), clear)
	r.Reset()
	red := RGB{R: 255, G: 0, B: 0}
	tri := Tri{
		V0: Vec3{X: -1, Y: -1, Z: 6}, V1: Vec3{X: 1, Y: -1, Z: 6}, V2: Vec3{X: 0, Y: 1, Z: 6},
		C0: red, C1: red, C2: red,
	}
	r.Draw(tri)
	if n := countLit(im, clear); n != 0 {
		t.Fatalf("behind-eye triangle drew %d px", n)
	}
}

// One vertex behind the eye: the triangle is clipped at w=0 and the visible
// part still rasterizes (a naive divide would wrap it inside out).
func TestClipOneVertexBehind(t *testing.T) {
	im := NewImage(64, 64, PixBGRA)
	clear := RGB{R: 1, G: 2, B: 3}
	r := NewRasterizer(im, testCam(64, 64), clear)
	r.Reset()
	red := RGB{R: 255, G: 0, B: 0}
	// Two vertices in front of the eye (world z=-1), one behind it (world
	// z=+20, camera at z=+4 looking down -z): the clipped, visible part
	// must still rasterize.
	tri := Tri{
		V0: Vec3{X: -0.5, Y: -0.5, Z: -1}, V1: Vec3{X: 0.5, Y: -0.5, Z: -1}, V2: Vec3{X: 0, Y: 0.5, Z: 20},
		C0: red, C1: red, C2: red,
	}
	r.Draw(tri)
	lit := countLit(im, clear)
	if lit == 0 {
		t.Fatal("near-crossing triangle drew nothing")
	}
	t.Logf("clipped triangle lit %d px", lit)
}

// A degenerate (zero-area) triangle draws nothing instead of panicking.
func TestClipDegenerate(t *testing.T) {
	im := NewImage(32, 32, PixBGRA)
	clear := RGB{R: 0, G: 0, B: 0}
	r := NewRasterizer(im, testCam(32, 32), clear)
	r.Reset()
	red := RGB{R: 255, G: 0, B: 0}
	tri := Tri{
		V0: Vec3{X: 0, Y: 0, Z: -2}, V1: Vec3{X: 0, Y: 0, Z: -2}, V2: Vec3{X: 0, Y: 0, Z: -2},
		C0: red, C1: red, C2: red,
	}
	r.Draw(tri)
	if n := countLit(im, clear); n != 0 {
		t.Fatalf("degenerate triangle drew %d px", n)
	}
}

// A triangle partially off the left/top edges covers only the in-raster
// samples (the near-plane + screen-edges clip path).
func TestClipScreenEdges(t *testing.T) {
	im := NewImage(32, 32, PixBGRA)
	clear := RGB{R: 1, G: 2, B: 3}
	r := NewRasterizer(im, testCam(32, 32), clear)
	r.Reset()
	red := RGB{R: 255, G: 0, B: 0}
	// A huge quad centered on the origin: it spills past every screen edge.
	for _, tri := range []Tri{
		{V0: Vec3{X: -8, Y: -8, Z: -2}, V1: Vec3{X: 8, Y: -8, Z: -2}, V2: Vec3{X: 8, Y: 8, Z: -2}, C0: red, C1: red, C2: red},
		{V0: Vec3{X: -8, Y: -8, Z: -2}, V1: Vec3{X: 8, Y: 8, Z: -2}, V2: Vec3{X: -8, Y: 8, Z: -2}, C0: red, C1: red, C2: red},
	} {
		r.Draw(tri)
	}
	if n := countLit(im, clear); n != 32*32 {
		t.Fatalf("edge-crossing quad covered %d/%d px", n, 32*32)
	}
}

// Depth test: a nearer triangle wins where they overlap.
func TestDepthNearerWins(t *testing.T) {
	im := NewImage(64, 64, PixBGRA)
	clear := RGB{R: 1, G: 2, B: 3}
	r := NewRasterizer(im, testCam(64, 64), clear)
	r.Reset()
	red := RGB{R: 255, G: 0, B: 0}
	blue := RGB{R: 0, G: 0, B: 255}
	far := Tri{V0: Vec3{X: -1, Y: -1, Z: -4}, V1: Vec3{X: 1, Y: -1, Z: -4}, V2: Vec3{X: 0, Y: 1, Z: -4}, C0: red, C1: red, C2: red}
	near := Tri{V0: Vec3{X: -0.5, Y: -0.5, Z: -2}, V1: Vec3{X: 0.5, Y: -0.5, Z: -2}, V2: Vec3{X: 0, Y: 0.5, Z: -2}, C0: blue, C1: blue, C2: blue}
	r.Draw(far)
	r.Draw(near)
	rr, gg, bb := im.GetPx(32, 32)
	if rr != 0 || gg != 0 || bb != 255 {
		t.Fatalf("center px = (%d,%d,%d), want the nearer blue", rr, gg, bb)
	}
	// Reverse the draw order: the depth test must still pick blue.
	r.Reset()
	r.Draw(near)
	r.Draw(far)
	rr, gg, bb = im.GetPx(32, 32)
	if rr != 0 || gg != 0 || bb != 255 {
		t.Fatalf("reversed order center px = (%d,%d,%d), want blue", rr, gg, bb)
	}
}

// Barycentric interpolation: a tri with black at two corners and full red at
// the third shades linearly. For this triangle the red vertex's barycentric
// weight at a sample is exactly w2 = (33 - sy)/33, so every covered pixel
// must carry R = floor(255*w2) — checked per pixel, not by tolerance.
func TestBarycentricShading(t *testing.T) {
	im := NewImage(33, 33, PixBGRA)
	clear := RGB{R: 9, G: 9, B: 9}
	r := NewRasterizer(im, testCam(33, 33), clear)
	r.Reset()
	r.drawNDC(
		Vert{X: -1, Y: -1, Z: 0.5, InvW: 1, R: 0, G: 0, B: 0},
		Vert{X: 1, Y: -1, Z: 0.5, InvW: 1, R: 0, G: 0, B: 0},
		Vert{X: 0, Y: 1, Z: 0.5, InvW: 1, R: 255, G: 0, B: 0},
	)
	covered := 0
	for y := 0; y < 33; y++ {
		sy := float32(y) + 0.5
		want := int((255 * (33 - sy)) / 33)
		for x := 0; x < 33; x++ {
			rr, gg, bb := im.GetPx(x, y)
			if rr == 9 && gg == 9 && bb == 9 {
				continue
			}
			covered++
			if gg != 0 || bb != 0 {
				t.Fatalf("non-red channel lit at (%d,%d): (%d,%d,%d)", x, y, rr, gg, bb)
			}
			if int(rr) != want {
				t.Fatalf("sample at (%d,%d) R=%d, want %d (w=%.3f)", x, y, rr, want, (33-sy)/33)
			}
		}
	}
	if covered == 0 {
		t.Fatal("triangle covered nothing")
	}
}

// Perspective correctness: two same-color tris at different depths must land
// on the same depth-tested pixel value (color is not depth-warped).
func TestPerspectiveColorStable(t *testing.T) {
	im := NewImage(64, 64, PixBGRA)
	clear := RGB{R: 1, G: 2, B: 3}
	r := NewRasterizer(im, testCam(64, 64), clear)
	r.Reset()
	red := RGB{R: 200, G: 40, B: 40}
	close := Tri{V0: Vec3{X: -0.4, Y: -0.4, Z: -1}, V1: Vec3{X: 0.4, Y: -0.4, Z: -1}, V2: Vec3{X: 0, Y: 0.4, Z: -1}, C0: red, C1: red, C2: red}
	r.Draw(close)
	rr, gg, bb := im.GetPx(32, 36)
	r.Reset()
	farTri := Tri{V0: Vec3{X: -0.8, Y: -0.8, Z: -4}, V1: Vec3{X: 0.8, Y: -0.8, Z: -4}, V2: Vec3{X: 0, Y: 0.8, Z: -4}, C0: red, C1: red, C2: red}
	r.Draw(farTri)
	rr2, gg2, bb2 := im.GetPx(32, 36)
	if rr != rr2 || gg != gg2 || bb != bb2 {
		t.Fatalf("close face (%d,%d,%d) != far face (%d,%d,%d) at center", rr, gg, bb, rr2, gg2, bb2)
	}
}

// Small mesh: two triangles sharing an edge form a quad; the seam must not
// double-paint and both faces must carry their own flat colors.
func TestSmallMeshQuad(t *testing.T) {
	im := NewImage(32, 32, PixBGRA)
	clear := RGB{R: 9, G: 9, B: 9}
	r := NewRasterizer(im, testCam(32, 32), clear)
	r.Reset()
	red := RGB{R: 255, G: 0, B: 0}
	blue := RGB{R: 0, G: 0, B: 255}
	// Two tris splitting the NDC square along the main diagonal.
	mesh := []Tri{
		{V0: Vec3{X: -1, Y: -1, Z: -2}, V1: Vec3{X: 1, Y: 1, Z: -2}, V2: Vec3{X: -1, Y: 1, Z: -2}, C0: red, C1: red, C2: red},
		{V0: Vec3{X: -1, Y: -1, Z: -2}, V1: Vec3{X: 1, Y: -1, Z: -2}, V2: Vec3{X: 1, Y: 1, Z: -2}, C0: blue, C1: blue, C2: blue},
	}
	for _, tri := range mesh {
		r.Draw(tri)
	}
	// The quad's corners project to NDC ±0.357 (f/dist = 2.1445/6), so the
	// covered center region is NDC |x|,|y| < 0.357: screen 32*(0.5±0.179).
	// Probe (14,14) upper-left half, (18,18) lower-right half.
	rr, gg, bb := im.GetPx(14, 14)
	if rr != 255 || gg != 0 || bb != 0 {
		t.Fatalf("upper-left px = (%d,%d,%d), want red", rr, gg, bb)
	}
	rr, gg, bb = im.GetPx(18, 18)
	if rr != 0 || gg != 0 || bb != 255 {
		t.Fatalf("lower-right px = (%d,%d,%d), want blue", rr, gg, bb)
	}
}
