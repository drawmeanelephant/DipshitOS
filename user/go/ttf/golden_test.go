package ttf

import (
	"bytes"
	"fmt"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

// Golden-image tests: render a fixed piece of text through the real rasterizer
// and compare the pixels against a pinned PNG. The convention is the one
// user/go/webrender already uses for its goldens (read golden_test.go there):
// a diff is a review item, never an auto-pass.
//
//	TTF_UPDATE_GOLDEN=1  rewrite the golden
//	TTF_ACCEPT_DIFF=1    record an explicitly reviewed diff and pass
//	                     (both are recorded at the diff site, not assumed)

// fb is a host-side 32-bpp surface with the same word layout the guest
// window's B8G8R8X8 back-buffer has: one 0xAARRGGBB word per pixel.
type fb struct {
	w, h int
	px   []uint32
}

func newFB(w, h int, bg uint32) *fb {
	f := &fb{w: w, h: h, px: make([]uint32, w*h)}
	for i := range f.px {
		f.px[i] = bg
	}
	return f
}

func (f *fb) at(x, y int) uint32 {
	if x < 0 || y < 0 || x >= f.w || y >= f.h {
		return 0
	}
	return f.px[y*f.w+x]
}

func (f *fb) count(pred func(uint32) bool) int {
	n := 0
	for _, v := range f.px {
		if pred(v) {
			n++
		}
	}
	return n
}

func (f *fb) pngBytes(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, f.w, f.h))
	for i, v := range f.px {
		img.Pix[4*i+0] = byte(v >> 16)
		img.Pix[4*i+1] = byte(v >> 8)
		img.Pix[4*i+2] = byte(v)
		img.Pix[4*i+3] = 0xFF
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("png: %v", err)
	}
	return buf.Bytes()
}

// drawText lays a string into a fresh surface at (x, baselineY), advancing by
// each glyph's own proportional advance — the host stand-in for the renderer's
// paint loop.
func drawText(t *testing.T, face *Face, text string, px, x, baselineY, w, h int, bg, fg uint32) *fb {
	t.Helper()
	f := newFB(w, h, bg)
	pen := x
	for _, r := range text {
		m, adv, err := face.Glyph(face.GlyphIndex(r), px)
		if err != nil {
			t.Fatalf("Glyph(%q): %v", r, err)
		}
		Blend(f.px, f.w, f.w, f.h, pen+m.BearingX, baselineY-m.BearingY, m, fg)
		pen += adv
	}
	return f
}

func checkGolden(t *testing.T, name string, f *fb) {
	t.Helper()
	got := f.pngBytes(t)
	path := filepath.Join("testdata", "golden", name+".png")
	if os.Getenv("TTF_UPDATE_GOLDEN") == "1" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatalf("mkdir golden dir: %v", err)
		}
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		t.Logf("golden updated: %s (%d bytes)", path, len(got))
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("missing golden %s (run with TTF_UPDATE_GOLDEN=1 to create): %v", path, err)
	}
	wantImg, err := png.Decode(bytes.NewReader(want))
	if err != nil {
		t.Fatalf("decode golden %s: %v", path, err)
	}
	gotImg, err := png.Decode(bytes.NewReader(got))
	if err != nil {
		t.Fatalf("decode rendered: %v", err)
	}
	if !wantImg.Bounds().Eq(gotImg.Bounds()) {
		t.Fatalf("golden size %v != rendered %v", wantImg.Bounds(), gotImg.Bounds())
	}
	diff := 0
	firstX, firstY := -1, -1
	b := wantImg.Bounds()
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			r1, g1, b1, _ := wantImg.At(x, y).RGBA()
			r2, g2, b2, _ := gotImg.At(x, y).RGBA()
			if r1 != r2 || g1 != g2 || b1 != b2 {
				diff++
				if firstX < 0 {
					firstX, firstY = x, y
				}
			}
		}
	}
	if diff != 0 {
		actual := filepath.Join("testdata", "golden", name+".actual.png")
		_ = os.WriteFile(actual, got, 0o644)
		report := fmt.Sprintf("golden diff %s: %d px differ (first at %d,%d); rendered written to %s for review",
			name, diff, firstX, firstY, actual)
		if os.Getenv("TTF_ACCEPT_DIFF") == "1" {
			t.Log("REVIEWED DIFF ACCEPTED: " + report)
			return
		}
		t.Fatal(report)
	}
}

const (
	goldenBG uint32 = 0x182026 // the desktop page background token
	goldenFG uint32 = 0xe6edf3 // the desktop text ink token
)

// TestGoldenGlyphH pins one large simple glyph.
func TestGoldenGlyphH(t *testing.T) {
	face := loadFace(t, interPath)
	f := drawText(t, face, "H", 32, 6, 34, 40, 44, goldenBG, goldenFG)
	if ink := f.count(func(v uint32) bool { return v != goldenBG }); ink < 150 {
		t.Fatalf("H rendered almost nothing: %d non-background px", ink)
	}
	checkGolden(t, "inter-h-32", f)
}

// TestGoldenCompositeEAcute pins a composite glyph (base + accent), which is
// the path a naive decoder gets wrong.
func TestGoldenCompositeEAacute(t *testing.T) {
	face := loadFace(t, interPath)
	f := drawText(t, face, "\u00e9", 24, 6, 30, 40, 32, goldenBG, goldenFG)
	if ink := f.count(func(v uint32) bool { return v != goldenBG }); ink < 80 {
		t.Fatalf("e-acute rendered almost nothing: %d non-background px", ink)
	}
	checkGolden(t, "inter-eacute-24", f)
}

// TestGoldenWordProportional pins a mixed-advance word: the letters must not
// be on a fixed grid, which is the whole point of the card.
func TestGoldenWordProportional(t *testing.T) {
	face := loadFace(t, interPath)
	f := drawText(t, face, "Agi", 16, 6, 24, 48, 30, goldenBG, goldenFG)
	if ink := f.count(func(v uint32) bool { return v != goldenBG }); ink < 60 {
		t.Fatalf("word rendered almost nothing: %d non-background px", ink)
	}
	checkGolden(t, "inter-agi-16", f)
}

// TestGoldenMonoFira pins the monospace face, which the terminal/editor need.
func TestGoldenMonoFira(t *testing.T) {
	face := loadFace(t, firaPath)
	f := drawText(t, face, "go", 16, 6, 24, 48, 30, goldenBG, goldenFG)
	if ink := f.count(func(v uint32) bool { return v != goldenBG }); ink < 40 {
		t.Fatalf("mono text rendered almost nothing: %d non-background px", ink)
	}
	checkGolden(t, "fira-go-16", f)
}
