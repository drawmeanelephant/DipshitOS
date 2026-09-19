package webrender

import (
	"bytes"
	"fmt"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fb is a host-side framebuffer implementing Surface, used for golden-image
// tests. It stores 0x00RRGGBB words exactly as the guest fills them.
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

func (f *fb) Fill(x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 {
		return
	}
	for yy := y; yy < y+h; yy++ {
		if yy < 0 || yy >= f.h {
			continue
		}
		for xx := x; xx < x+w; xx++ {
			if xx < 0 || xx >= f.w {
				continue
			}
			f.px[yy*f.w+xx] = rgb
		}
	}
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

func mustReadTestdata(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return b
}

func renderFixture(t *testing.T, name string, w, h int, scroll int) (*Layout, *fb) {
	t.Helper()
	doc := ParseHTML(mustReadTestdata(t, "testdata/"+name))
	l := LayoutDocument(doc, w, nil)
	f := newFB(w, h, ColorPageBg)
	Paint(l, f, 0, 0, w, h, scroll)
	return l, f
}

// checkGolden compares against a pinned image. A diff is a review item, never
// an auto-pass: set WEBRENDER_UPDATE_GOLDEN=1 to rewrite the golden, or
// WEBRENDER_ACCEPT_DIFF=1 to record an explicitly reviewed diff.
func checkGolden(t *testing.T, name string, f *fb) {
	t.Helper()
	got := f.pngBytes(t)
	path := filepath.Join("testdata", "golden", name+".png")
	if os.Getenv("WEBRENDER_UPDATE_GOLDEN") == "1" {
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		t.Logf("golden updated: %s (%d bytes)", path, len(got))
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("missing golden %s (run with WEBRENDER_UPDATE_GOLDEN=1 to create): %v", path, err)
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
		if os.Getenv("WEBRENDER_ACCEPT_DIFF") == "1" {
			t.Log("REVIEWED DIFF ACCEPTED: " + report)
			return
		}
		t.Fatal(report)
	}
}

func TestGoldenSimplePage(t *testing.T) {
	l, f := renderFixture(t, "simple.html", 512, 384, 0)
	if l.Height < 200 {
		t.Fatalf("unexpectedly short layout: %d", l.Height)
	}
	if bg := f.count(func(v uint32) bool { return v == ColorPageBg }); bg < 1000 {
		t.Fatalf("page background missing: %d", bg)
	}
	accent := f.count(func(v uint32) bool { return v == ColorAccent })
	if accent < 8 {
		t.Fatalf("link accent/underline pixels missing: %d", accent)
	}
	surface := f.count(func(v uint32) bool { return v == ColorSurface })
	if surface < 100 {
		t.Fatalf("code/pre surface pixels missing: %d", surface)
	}
	ink := f.count(func(v uint32) bool { return v == ColorText })
	if ink < 300 {
		t.Fatalf("text ink pixels too few: %d", ink)
	}
	checkGolden(t, "simple", f)
}

func TestGoldenTablePage(t *testing.T) {
	_, f := renderFixture(t, "table.html", 512, 384, 0)
	if ink := f.count(func(v uint32) bool { return v == ColorText }); ink < 200 {
		t.Fatalf("table page ink too few: %d", ink)
	}
	if rule := f.count(func(v uint32) bool { return v == ColorRule }); rule < 10 {
		t.Fatalf("table/rule pixels too few: %d", rule)
	}
	checkGolden(t, "table", f)
}

func TestGoldenBrokenPage(t *testing.T) {
	_, f := renderFixture(t, "broken.html", 512, 384, 0)
	if ink := f.count(func(v uint32) bool { return v == ColorText }); ink < 200 {
		t.Fatalf("malformed page rendered too little text: %d", ink)
	}
	if f.count(func(v uint32) bool { return v != ColorPageBg }) < 200 {
		t.Fatal("malformed markup blanked the viewport")
	}
	checkGolden(t, "broken", f)
}

func TestPaintClipsToViewport(t *testing.T) {
	lay, _ := renderFixture(t, "simple.html", 300, 120, 0)
	f := newFB(300, 200, ColorChromeBg)
	Paint(lay, f, 0, 40, 300, 120, 0)
	for y := 0; y < 40; y++ {
		for x := 0; x < 300; x++ {
			if f.at(x, y) != ColorChromeBg {
				t.Fatalf("page paint spilled into the chrome band at %d,%d", x, y)
			}
		}
	}
	for y := 160; y < 200; y++ {
		for x := 0; x < 300; x++ {
			if f.at(x, y) != ColorChromeBg {
				t.Fatalf("page paint spilled below the viewport at %d,%d", x, y)
			}
		}
	}
}

func TestScrollShiftsContent(t *testing.T) {
	doc := ParseHTML(mustReadTestdata(t, "testdata/simple.html"))
	l := LayoutDocument(doc, 470, nil)
	top := newFB(470, 120, ColorPageBg)
	Paint(l, top, 0, 0, 470, 120, 0)
	scrolled := newFB(470, 120, ColorPageBg)
	Paint(l, scrolled, 0, 0, 470, 120, 40)
	same := 0
	for i := range top.px {
		if top.px[i] == scrolled.px[i] {
			same++
		}
	}
	if same == len(top.px) {
		t.Fatal("scrolling did not move content")
	}
}

func corpusImages() ImageResolver {
	dir := "testdata/corpus"
	return func(src string) ([]byte, bool) {
		base := filepath.Base(src)
		if q := strings.IndexByte(base, '?'); q >= 0 {
			base = base[:q]
		}
		candidates := []string{base}
		if !strings.Contains(base, ".") {
			candidates = append(candidates, base+".png")
		}
		for _, name := range candidates {
			b, err := os.ReadFile(filepath.Join(dir, name))
			if err == nil {
				return b, true
			}
		}
		return nil, false
	}
}

func renderCorpus(t *testing.T, name string, w, h int) (*Layout, *fb) {
	t.Helper()
	doc := ParseHTML(mustReadTestdata(t, "testdata/corpus/"+name))
	l := LayoutDocument(doc, w, nil, corpusImages())
	f := newFB(w, h, ColorPageBg)
	Paint(l, f, 0, 0, w, h, 0)
	return l, f
}

func layoutText(l *Layout) string {
	var b []byte
	for _, it := range l.Items {
		if it.Kind == ItemText && it.Text != "" {
			b = append(b, it.Text...)
			b = append(b, ' ')
		}
	}
	return string(b)
}

func TestGoldenCorpusPages(t *testing.T) {
	// Real pages the guest can fetch, pinned 2026-09-19. Author CSS is skipped
	// (ADR 0028 D2); goldens are the UA-table rendering, not Chrome.
	cases := []struct {
		html   string
		golden string
		want   []string
	}{
		{"example-org.html", "corpus-example-org", []string{"Example Domain", "Learn more"}},
		{"cern-home.html", "corpus-cern-home", []string{"first website", "Browse the first website"}},
		{"cern-theproject.html", "corpus-cern-theproject", []string{"World Wide Web", "What's out there?"}},
		{"httpbin-html.html", "corpus-httpbin-html", []string{"Herman Melville", "Ahab"}},
		{"httpbin-forms.html", "corpus-httpbin-forms", []string{"Customer name", "Submit order"}},
		{"rfc20.html", "corpus-rfc20", []string{"Network Working Group", "ASCII"}},
		{"iana-reserved.html", "corpus-iana-reserved", []string{"IANA-managed Reserved Domains", "example.com"}},
		{"w3-styleguide.html", "corpus-w3-styleguide", []string{"Style Guide", "webmaster"}},
		{"w3-png.html", "corpus-w3-png", []string{"Portable Network Graphics", "image/png"}},
	}
	for _, tc := range cases {
		t.Run(tc.html, func(t *testing.T) {
			l, f := renderCorpus(t, tc.html, 512, 384)
			got := layoutText(l)
			for _, want := range tc.want {
				if !strings.Contains(got, want) {
					t.Fatalf("corpus %s lost %q; laid out %q", tc.html, want, trunc(got, 400))
				}
			}
			if ink := f.count(func(v uint32) bool { return v != ColorPageBg }); ink < 80 {
				t.Fatalf("corpus %s painted too little ink: %d", tc.html, ink)
			}
			if tc.html == "w3-png.html" {
				decoded := 0
				for _, it := range l.Items {
					if it.Kind == ItemImage && it.Img != nil {
						decoded++
					}
				}
				if decoded < 3 {
					t.Fatalf("w3-png decoded %d PNG <img>s, want the three pinned files", decoded)
				}
			}
			if tc.html == "httpbin-forms.html" {
				boxes := 0
				for _, it := range l.Items {
					if it.Kind == ItemRect && it.Bg == ColorSurface {
						boxes++
					}
				}
				if boxes < 4 {
					t.Fatalf("httpbin-forms static controls = %d", boxes)
				}
			}
			checkGolden(t, tc.golden, f)
		})
	}
}

func trunc(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
