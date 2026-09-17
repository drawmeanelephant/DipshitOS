// Package internal is the rasterizer core: Image, camera/projection math,
// and the barycentric triangle fill with depth test and perspective-correct
// Gouraud shading. Package name tracks the directory (internal); the
// semantic name lives in this comment.
package internal

// PixelFormat is the framebuffer pixel encoding the rasterizer writes.
type PixelFormat int

const (
	// PixBGRA is the scanout format: byte 0 blue, 1 green, 2 red, 3 unused.
	PixBGRA PixelFormat = iota
	// PixRGBA is a plain red, green, blue, unused layout.
	PixRGBA
)

// Image is a small software framebuffer: a BGRA byte buffer plus its stride.
// Both the host tests and the guest present path go through this same type,
// so a frame proven on the host is the frame the guest paints.
type Image struct {
	W, H   int
	Stride int
	Pix    []byte
	Format PixelFormat
}

// NewImage allocates a zeroed (black, A=0) image.
func NewImage(w, h int, f PixelFormat) *Image {
	if w < 1 || h < 1 {
		return &Image{Format: f}
	}
	return &Image{
		W:      w,
		H:      h,
		Stride: w * 4,
		Pix:    make([]byte, w*h*4),
		Format: f,
	}
}

// setPx writes one clamped pixel as B,G,R,unused.
func (im *Image) setPx(x, y int, r, g, b uint8) {
	if x < 0 || y < 0 || x >= im.W || y >= im.H {
		return
	}
	k := y*im.Stride + x*4
	im.Pix[k+0] = b
	im.Pix[k+1] = g
	im.Pix[k+2] = r
	im.Pix[k+3] = 0
}

// GetPx reads one pixel back as R,G,B (0,0,0 outside).
func (im *Image) GetPx(x, y int) (uint8, uint8, uint8) {
	if x < 0 || y < 0 || x >= im.W || y >= im.H {
		return 0, 0, 0
	}
	k := y*im.Stride + x*4
	return im.Pix[k+2], im.Pix[k+1], im.Pix[k+0]
}

// Vec3 is a position or direction in view space.
type Vec3 struct{ X, Y, Z float32 }

// Tri is one triangle: three positions and three vertex colors.
type Tri struct {
	V0, V1, V2 Vec3
	C0, C1, C2 RGB
}

// RGB is a straight (non-premultiplied) 8-bit color.
type RGB struct{ R, G, B uint8 }

// Cam is a simple look-at camera: position, target, up, vertical fov in
// degrees, and aspect (width/height).
type Cam struct {
	Pos    Vec3
	Target Vec3
	Up     Vec3
	FovDeg float32
	Aspect float32
	Near   float32
	Far    float32
}

// Rasterizer holds the target image, depth buffer, camera, and clear color,
// and draws triangles through Draw.
type Rasterizer struct {
	Img   *Image
	Depth []float32
	Cam   Cam
	Clear RGB
}

// Reset clears the image to the clear color and the depth buffer to the far
// plane (1.0). Call once per frame before drawing.
func (r *Rasterizer) Reset() {
	w, h := r.Img.W, r.Img.H
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			r.Img.setPx(x, y, r.Clear.R, r.Clear.G, r.Clear.B)
		}
	}
	for i := range r.Depth {
		r.Depth[i] = 1
	}
}

// NewRasterizer builds one over im with the given camera and clear color.
func NewRasterizer(im *Image, cam Cam, clear RGB) *Rasterizer {
	r := &Rasterizer{Img: im, Cam: cam, Clear: clear}
	r.Depth = make([]float32, im.W*im.H)
	return r
}

func sub(a, b Vec3) Vec3    { return Vec3{a.X - b.X, a.Y - b.Y, a.Z - b.Z} }
func cross(a, b Vec3) Vec3  { return Vec3{a.Y*b.Z - a.Z*b.Y, a.Z*b.X - a.X*b.Z, a.X*b.Y - a.Y*b.X} }
func dot(a, b Vec3) float32 { return a.X*b.X + a.Y*b.Y + a.Z*b.Z }
func normalize(v Vec3) Vec3 {
	l := sqrtf(dot(v, v))
	if l == 0 {
		return v
	}
	return Vec3{v.X / l, v.Y / l, v.Z / l}
}

func sqrtf(x float32) float32 { return float32(sqrt64(float64(x))) }

// sqrt64 is Newton-Raphson on the plain square root (x, not 1/sqrt): exact
// enough for camera math and dependency-free by construction (freestanding Go
// has no math package; vi links no libc).
func sqrt64(x float64) float64 {
	if x <= 0 {
		return 0
	}
	guess := x
	if x < 1 {
		guess = 1
	}
	for i := 0; i < 32; i++ {
		next := 0.5 * (guess + x/guess)
		if next == guess {
			break
		}
		guess = next
	}
	return guess
}

// Mat4 is a row-major 4x4 transform.
type Mat4 [16]float32

func mul4(a, b Mat4) Mat4 {
	var c Mat4
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			c[i*4+j] = a[i*4+0]*b[0*4+j] + a[i*4+1]*b[1*4+j] + a[i*4+2]*b[2*4+j] + a[i*4+3]*b[3*4+j]
		}
	}
	return c
}

func apply4(m Mat4, v Vec3, w float32) (Vec3, float32) {
	x := m[0]*v.X + m[1]*v.Y + m[2]*v.Z + m[3]*w
	y := m[4]*v.X + m[5]*v.Y + m[6]*v.Z + m[7]*w
	z := m[8]*v.X + m[9]*v.Y + m[10]*v.Z + m[11]*w
	w2 := m[12]*v.X + m[13]*v.Y + m[14]*v.Z + m[15]*w
	return Vec3{x, y, z}, w2
}

// view builds the look-at view matrix.
func view(c Cam) Mat4 {
	fwd := normalize(sub(c.Target, c.Pos))
	right := normalize(cross(fwd, c.Up))
	up := cross(right, fwd)
	return Mat4{
		right.X, right.Y, right.Z, -dot(right, c.Pos),
		up.X, up.Y, up.Z, -dot(up, c.Pos),
		-fwd.X, -fwd.Y, -fwd.Z, dot(fwd, c.Pos),
		0, 0, 0, 1,
	}
}

// proj builds the vertical-fov perspective matrix mapping depth into [0,1].
func proj(c Cam) Mat4 {
	f := 1 / tanf(c.FovDeg*pi/360)
	n, fr := c.Near, c.Far
	return Mat4{
		f / c.Aspect, 0, 0, 0,
		0, f, 0, 0,
		0, 0, fr / (n - fr), n * fr / (n - fr),
		0, 0, -1, 0,
	}
}

const pi = 3.14159265358979

// tanf is the plain tangent (sin/cos via range-reduced Taylor series): good
// to well below a degree for fov in (0, 170), dependency-free.
func tanf(x float32) float32 {
	s, c := sincosf(x)
	if c == 0 {
		return 1e15
	}
	return s / c
}

// sincosf range-reduces into [-pi, pi] and evaluates the Taylor series
// (13 odd terms for sin, 13 even terms for cos): float32-accurate well past
// the camera's needs, dependency-free.
func sincosf(x float32) (float32, float32) {
	x = normalizeAngle(x)
	var s, c float32
	term := float32(1)
	for n := 1; n <= 13; n += 2 {
		s += term * powInt(x, n) / float32(fact(n))
		term = -term
	}
	term = 1
	for n := 0; n <= 12; n += 2 {
		c += term * powInt(x, n) / float32(fact(n))
		term = -term
	}
	return s, c
}

// normalizeAngle wraps x into [-pi, pi] for series accuracy.
func normalizeAngle(x float32) float32 {
	const twoPi = 2 * pi
	for x > pi {
		x -= twoPi
	}
	for x < -pi {
		x += twoPi
	}
	return x
}

// powInt is x**n for a small non-negative integer n.
func powInt(x float32, n int) float32 {
	p := float32(1)
	for i := 0; i < n; i++ {
		p *= x
	}
	return p
}

// fact is n! as an int (n <= 16 fits easily).
func fact(n int) int {
	f := 1
	for i := 2; i <= n; i++ {
		f *= i
	}
	return f
}

// Vert is one transformed vertex in NDC with the perspective-corrected
// reciprocal w and the interpolated color attribute (post-division).
type Vert struct {
	X, Y, Z float32 // NDC
	InvW    float32
	R, G, B float32 // /w-corrected vertex color
}

// Draw projects one world-space triangle with the current camera and
// rasterizes it into Img (synchronous, immediate mode).
func (r *Rasterizer) Draw(t Tri) {
	vp := mul4(proj(r.Cam), view(r.Cam))
	ax, aw := apply4(vp, t.V0, 1)
	bx, bw := apply4(vp, t.V1, 1)
	cx, cw := apply4(vp, t.V2, 1)
	poly := []clipVertex{newClip(ax, aw, t.C0), newClip(bx, bw, t.C1), newClip(cx, cw, t.C2)}
	for plane := 0; plane < 6; plane++ {
		poly = clipPlane(poly, plane)
	}
	for i := 1; i+1 < len(poly); i++ {
		if poly[0].W > 0 && poly[i].W > 0 && poly[i+1].W > 0 {
			r.drawNDC(poly[0].ndc(), poly[i].ndc(), poly[i+1].ndc())
		}
	}
}

// ndcVert finishes one clip-space vertex: divide by w, keep 1/w and the
// /w-corrected color for perspective-correct interpolation.
func ndcVert(p Vec3, w float32, col RGB) Vert {
	if w == 0 {
		w = 1e-6
	}
	iw := 1 / w
	return Vert{
		X: p.X * iw, Y: p.Y * iw, Z: p.Z * iw,
		InvW: iw,
		R:    float32(col.R) * iw,
		G:    float32(col.G) * iw,
		B:    float32(col.B) * iw,
	}
}

// drawNDC rasterizes one NDC triangle with top-left-free pixel-center
// sampling: a sample covers when its barycentric weights are all >= 0.
func (r *Rasterizer) drawNDC(a, b, c Vert) {
	w, h := r.Img.W, r.Img.H
	ax := (a.X*0.5 + 0.5) * float32(w)
	ay := (0.5 - a.Y*0.5) * float32(h)
	bx := (b.X*0.5 + 0.5) * float32(w)
	by := (0.5 - b.Y*0.5) * float32(h)
	cx := (c.X*0.5 + 0.5) * float32(w)
	cy := (0.5 - c.Y*0.5) * float32(h)

	area := (bx-ax)*(cy-ay) - (by-ay)*(cx-ax)
	if area == 0 {
		return
	}
	inv := 1 / area

	// Bounding box, clamped to the raster (the clip path).
	x0 := clampi(int(floorf(min3(ax, bx, cx))), 0, w-1)
	y0 := clampi(int(floorf(min3(ay, by, cy))), 0, h-1)
	x1 := clampi(int(ceilf(max3(ax, bx, cx))), 0, w-1)
	y1 := clampi(int(ceilf(max3(ay, by, cy))), 0, h-1)

	for py := y0; py <= y1; py++ {
		sy := float32(py) + 0.5
		for px := x0; px <= x1; px++ {
			sx := float32(px) + 0.5
			w0 := ((bx-sx)*(cy-sy) - (by-sy)*(cx-sx)) * inv
			w1 := ((cx-sx)*(ay-sy) - (cy-sy)*(ax-sx)) * inv
			w2 := 1 - w0 - w1
			if w0 < 0 || w1 < 0 || w2 < 0 {
				continue
			}
			// Perspective-correct interpolation: interpolate 1/w and
			// color/w linearly in screen space, then renormalize.
			iw := w0*a.InvW + w1*b.InvW + w2*c.InvW
			if iw <= 0 {
				continue
			}
			z := w0*a.Z + w1*b.Z + w2*c.Z
			depth := r.Depth[py*w+px]
			if z < depth {
				r.Depth[py*w+px] = z
				rw := (w0*a.R + w1*b.R + w2*c.R) / iw
				g := (w0*a.G + w1*b.G + w2*c.G) / iw
				b2 := (w0*a.B + w1*b.B + w2*c.B) / iw
				r.Img.setPx(px, py, rgb8(rw), rgb8(g), rgb8(b2))
			}
		}
	}
}

func rgb8(x float32) uint8 {
	if x <= 0 {
		return 0
	}
	if x >= 255 {
		return 255
	}
	return uint8(x)
}

func min3(a, b, c float32) float32 {
	m := a
	if b < m {
		m = b
	}
	if c < m {
		m = c
	}
	return m
}

func max3(a, b, c float32) float32 {
	m := a
	if b > m {
		m = b
	}
	if c > m {
		m = c
	}
	return m
}

func clampi(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// floorf is truncation toward negative infinity for float32.
func floorf(x float32) float32 {
	t := truncf(x)
	if x < t {
		return t - 1
	}
	return t
}

// ceilf is truncation toward positive infinity for float32.
func ceilf(x float32) float32 {
	t := truncf(x)
	if x > t {
		return t + 1
	}
	return t
}

// truncf drops the fraction (Go's float->int conversion truncates).
func truncf(x float32) float32 {
	return float32(int64(x))
}
