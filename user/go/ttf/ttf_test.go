package ttf

import (
	"go/parser"
	"go/token"
	"os"
	"strconv"
	"strings"
	"testing"
)

// The two faces the desktop actually loads. Both are committed fixtures; a
// missing one is a test failure, never a silent skip — a font test that skips
// itself proves nothing.
const (
	interPath = "../../../image/fonts/Inter-Regular.ttf"
	firaPath  = "../../../image/fonts/FiraCode-Regular.ttf"
)

func loadFace(t *testing.T, path string) *Face {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("font fixture %s is required by this package's tests: %v", path, err)
	}
	f, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse(%s): %v", path, err)
	}
	return f
}

// TestInterTableFacts pins the values this package reads out of Inter's own
// tables. Every number below was read from image/fonts/Inter-Regular.ttf
// directly (not from a spec or a guess).
func TestInterTableFacts(t *testing.T) {
	f := loadFace(t, interPath)
	if got := f.UnitsPerEm(); got != 2048 {
		t.Errorf("Inter UnitsPerEm = %d, want 2048", got)
	}
	if got := f.NumGlyphs(); got != 2937 {
		t.Errorf("Inter NumGlyphs = %d, want 2937", got)
	}
	if got := f.NumHMetrics(); got != 2937 {
		t.Errorf("Inter NumHMetrics = %d, want 2937", got)
	}
	if got := f.IndexToLocFormat(); got != 1 {
		t.Errorf("Inter IndexToLocFormat = %d, want 1 (long loca)", got)
	}
	cases := []struct {
		r    rune
		gid  uint16
		adv  int
		lsb  int
		note string
	}{
		{'i', 689, 496, 0, "lowercase i"},
		{'m', 766, 1794, 0, "lowercase m"},
		{'W', 459, 2018, 0, "uppercase W"},
		{' ', 1777, 576, 0, "space"},
	}
	for _, c := range cases {
		gid := f.GlyphIndex(c.r)
		if gid != c.gid {
			t.Errorf("Inter GlyphIndex(%q) = %d, want %d (%s)", c.r, gid, c.gid, c.note)
		}
		if got := f.GlyphAdvanceUPEM(gid); got != c.adv {
			t.Errorf("Inter advance(%q) = %d UPEM, want %d", c.r, got, c.adv)
		}
	}
	// The metric table can also be checked through the bitmap data itself: H is
	// a one-contour simple glyph, space has no outline at all, and e-acute is a
	// composite.
	if _, err := f.GlyphData(f.GlyphIndex(' ')); err != nil {
		t.Errorf("GlyphData(space): %v", err)
	}
	space, err := f.GlyphData(f.GlyphIndex(' '))
	if err != nil {
		t.Fatalf("GlyphData(space): %v", err)
	}
	if len(space) != 0 {
		t.Errorf("Inter space glyph has %d bytes of outline, want 0", len(space))
	}
}

// TestFiraTableFacts is the same check for the monospace face.
func TestFiraTableFacts(t *testing.T) {
	f := loadFace(t, firaPath)
	if got := f.UnitsPerEm(); got != 1950 {
		t.Errorf("Fira UnitsPerEm = %d, want 1950", got)
	}
	if got := f.NumGlyphs(); got != 2030 {
		t.Errorf("Fira NumGlyphs = %d, want 2030", got)
	}
	if got := f.NumHMetrics(); got != 1963 {
		t.Errorf("Fira NumHMetrics = %d, want 1963", got)
	}
	if got := f.IndexToLocFormat(); got != 1 {
		t.Errorf("Fira IndexToLocFormat = %d, want 1 (long loca)", got)
	}
	cases := []struct {
		r   rune
		gid uint16
		adv int
	}{
		{'i', 180, 1200},
		{'m', 204, 1200},
		{'W', 114, 1200},
		{' ', 1103, 1200},
	}
	for _, c := range cases {
		if gid := f.GlyphIndex(c.r); gid != c.gid {
			t.Errorf("Fira GlyphIndex(%q) = %d, want %d", c.r, gid, c.gid)
		}
		if got := f.GlyphAdvanceUPEM(f.GlyphIndex(c.r)); got != c.adv {
			t.Errorf("Fira advance(%q) = %d UPEM, want %d", c.r, got, c.adv)
		}
	}
}

// TestAdvancesAreProportional is the load-bearing metric test: Inter must
// measure like a proportional face, Fira Code like a monospace one. These are
// the numbers the browser's layout depends on, and they are the difference
// between this work and the old 8x8 grid (where every advance was identical).
func TestAdvancesAreProportional(t *testing.T) {
	inter := loadFace(t, interPath)
	iAdv := inter.AdvancePx('i', 16)
	mAdv := inter.AdvancePx('m', 16)
	wAdv := inter.AdvancePx('W', 16)
	spAdv := inter.AdvancePx(' ', 16)
	t.Logf("Inter @16px: i=%d m=%d W=%d space=%d", iAdv, mAdv, wAdv, spAdv)
	if iAdv != 4 {
		t.Errorf("Inter AdvancePx('i',16) = %d, want 4", iAdv)
	}
	if mAdv != 14 {
		t.Errorf("Inter AdvancePx('m',16) = %d, want 14", mAdv)
	}
	if wAdv != 16 {
		t.Errorf("Inter AdvancePx('W',16) = %d, want 16", wAdv)
	}
	if spAdv != 5 {
		t.Errorf("Inter AdvancePx(' ',16) = %d, want 5", spAdv)
	}
	if !(iAdv < mAdv && mAdv < wAdv) {
		t.Errorf("Inter advances are not proportional: i=%d m=%d W=%d", iAdv, mAdv, wAdv)
	}
	if inter.Measure("WWW", 16) <= inter.Measure("iii", 16) {
		t.Errorf("Inter: Measure(WWW)=%d must exceed Measure(iii)=%d",
			inter.Measure("WWW", 16), inter.Measure("iii", 16))
	}

	fira := loadFace(t, firaPath)
	fi, fm, fw := fira.AdvancePx('i', 16), fira.AdvancePx('m', 16), fira.AdvancePx('W', 16)
	t.Logf("Fira Code @16px: i=%d m=%d W=%d", fi, fm, fw)
	if fi != 10 || fm != 10 || fw != 10 {
		t.Errorf("Fira Code must be monospace at 16px: i=%d m=%d W=%d, want 10/10/10", fi, fm, fw)
	}
}

// TestMeasureIsSumOfAdvances keeps Measure and AdvancePx from drifting apart.
func TestMeasureIsSumOfAdvances(t *testing.T) {
	for _, path := range []string{interPath, firaPath} {
		f := loadFace(t, path)
		for _, s := range []string{"", "hello", "The quick brown fox", "iWi", "\t   ", "oliver"} {
			want := 0
			for _, r := range s {
				want += f.AdvancePx(r, 13)
			}
			if got := f.Measure(s, 13); got != want {
				t.Errorf("%s: Measure(%q,13) = %d, want %d", path, s, got, want)
			}
		}
	}
}

// TestUnmappedRuneStillAdvances: a rune the font has no glyph for resolves to
// .notdef, and .notdef still has a width. Text made of unknown characters stays
// visible and keeps its spacing instead of collapsing to nothing.
func TestUnmappedRuneStillAdvances(t *testing.T) {
	f := loadFace(t, interPath)
	const emoji = '\U0001F600'
	if gid := f.GlyphIndex(emoji); gid != 0 {
		t.Errorf("GlyphIndex(%U) = %d, want 0 (.notdef)", emoji, gid)
	}
	if adv := f.AdvancePx(emoji, 16); adv <= 0 {
		t.Errorf("AdvancePx(%U,16) = %d, want > 0 so unknown text still occupies space", emoji, adv)
	}
	if adv := f.AdvancePx(0xE0000, 16); adv <= 0 {
		t.Errorf("AdvancePx(U+E0000,16) = %d, want > 0", adv)
	}
}

// TestLineMetrics pins the vertical rhythm so the renderer's line height is a
// font fact rather than a constant.
func TestLineMetrics(t *testing.T) {
	inter := loadFace(t, interPath)
	ia, id, ig := inter.LineMetrics(16)
	t.Logf("Inter @16px: ascent=%d descent=%d lineGap=%d", ia, id, ig)
	if ia != 16 {
		t.Errorf("Inter ascent@16 = %d, want 16", ia)
	}
	if id != 4 {
		t.Errorf("Inter descent@16 = %d, want 4", id)
	}
	fira := loadFace(t, firaPath)
	fa, fd, fg := fira.LineMetrics(16)
	t.Logf("Fira @16px: ascent=%d descent=%d lineGap=%d", fa, fd, fg)
	if fa != 15 {
		t.Errorf("Fira ascent@16 = %d, want 15", fa)
	}
	if fd != 5 {
		t.Errorf("Fira descent@16 = %d, want 5", fd)
	}
	if ia <= id || fa <= fd {
		t.Errorf("ascent must exceed descent for both faces: Inter %d/%d Fira %d/%d", ia, id, fa, fd)
	}
}

// TestCompositeGlyphDecodes: e-acute is stored as a composite (a base plus an
// accent) in both faces. Decoding it exercises the component transform path.
func TestCompositeGlyphDecodes(t *testing.T) {
	for _, path := range []string{interPath, firaPath} {
		f := loadFace(t, path)
		gid := f.GlyphIndex('\u00e9')
		if gid == 0 {
			t.Fatalf("%s: no glyph for e-acute", path)
		}
		data, err := f.GlyphData(gid)
		if err != nil {
			t.Fatalf("%s: GlyphData(e-acute): %v", path, err)
		}
		if len(data) < 2 {
			t.Fatalf("%s: e-acute glyph is empty", path)
		}
		if nc := int(int16(be16(data[0:2]))); nc >= 0 {
			t.Fatalf("%s: e-acute is not stored as a composite (numberOfContours=%d)", path, nc)
		}
		contours, err := f.glyphContours(gid)
		if err != nil {
			t.Fatalf("%s: glyphContours(e-acute): %v", path, err)
		}
		if len(contours) < 2 {
			t.Errorf("%s: composite e-acute resolved to %d contours, want >= 2 (base + accent)",
				path, len(contours))
		}
		pts := 0
		for _, c := range contours {
			pts += len(c)
		}
		if pts < 10 {
			t.Errorf("%s: composite e-acute resolved to %d points, want a real outline", path, pts)
		}
	}
}

// TestDeterminism: parsing and rasterizing twice must produce identical bytes.
// A renderer that phones home to floats differently between runs would make
// every golden image a coin flip.
func TestDeterminism(t *testing.T) {
	data, err := os.ReadFile(interPath)
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	a, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	b, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	for _, r := range []rune{'A', 'g', 'W', '\u00e9', '0'} {
		if a.GlyphIndex(r) != b.GlyphIndex(r) || a.AdvancePx(r, 19) != b.AdvancePx(r, 19) {
			t.Fatalf("metrics differ between parses for %q", r)
		}
	}
	for _, r := range []rune{'A', 'g', 'W', '\u00e9'} {
		ma, err := a.Rasterize(r, 19)
		if err != nil {
			t.Fatalf("Rasterize(%q): %v", r, err)
		}
		mb, err := b.Rasterize(r, 19)
		if err != nil {
			t.Fatalf("Rasterize(%q): %v", r, err)
		}
		if ma.Width != mb.Width || ma.Height != mb.Height || ma.BearingX != mb.BearingX || ma.BearingY != mb.BearingY {
			t.Fatalf("mask geometry differs for %q: %+v vs %+v", r, ma, mb)
		}
		if len(ma.Alpha) != len(mb.Alpha) {
			t.Fatalf("mask length differs for %q", r)
		}
		for i := range ma.Alpha {
			if ma.Alpha[i] != mb.Alpha[i] {
				t.Fatalf("mask byte %d differs for %q", i, r)
			}
		}
	}
}

// TestGlyphCacheIsBounded: the cache must be a fixed bound, not a growth curve.
func TestGlyphCacheIsBounded(t *testing.T) {
	f := loadFace(t, interPath)
	if n := f.CacheLen(); n != defaultCacheEntries {
		t.Fatalf("cache length = %d, want %d", n, defaultCacheEntries)
	}
	for i := 0; i < 4000; i++ {
		r := rune(0x20 + (i % 90))
		if _, _, err := f.Glyph(f.GlyphIndex(r), 8+(i%5)); err != nil {
			t.Fatalf("Glyph(%q): %v", r, err)
		}
	}
	if n := f.CacheLen(); n != defaultCacheEntries {
		t.Fatalf("cache grew to %d entries", n)
	}
}

// --- hostile input -------------------------------------------------------

func findTableRaw(t *testing.T, data []byte, tag string) int {
	t.Helper()
	if len(data) < 12 {
		return -1
	}
	n := int(be16(data[4:6]))
	for i := 0; i < n; i++ {
		off := 12 + i*16
		if off+16 > len(data) {
			return -1
		}
		if string(data[off:off+4]) == tag {
			return int(be32(data[off+8 : off+12]))
		}
	}
	return -1
}

func glyphSpan(t *testing.T, data []byte, gid int) (int, int) {
	t.Helper()
	loc := findTableRaw(t, data, "loca")
	head := findTableRaw(t, data, "head")
	if loc < 0 || head < 0 {
		return 0, 0
	}
	format := int(int16(be16(data[head+50 : head+52])))
	if format == 0 {
		return int(be16(data[loc+2*gid:loc+2*gid+2])) * 2, int(be16(data[loc+2*gid+2:loc+2*gid+4])) * 2
	}
	return int(be32(data[loc+4*gid : loc+4*gid+4])), int(be32(data[loc+4*gid+4 : loc+4*gid+8]))
}

// TestMalformedInputNeverPanics feeds the parser and every accessor a set of
// deliberately broken fonts. The contract is: a typed error or a safe empty
// result. A panic here would be a remote crash in the guest, since the font
// comes from the share.
func TestMalformedInputNeverPanics(t *testing.T) {
	base, err := os.ReadFile(interPath)
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	cp := func() []byte { return append([]byte(nil), base...) }

	cases := []struct {
		name string
		mut  func(d []byte) []byte
	}{
		{"nil input", func(d []byte) []byte { return nil }},
		{"truncated to 6 bytes", func(d []byte) []byte { return d[:6] }},
		{"truncated header only", func(d []byte) []byte { return d[:12] }},
		{"cff outlines (OTTO)", func(d []byte) []byte { copy(d[0:4], []byte("OTTO")); return d }},
		{"garbage sfnt version", func(d []byte) []byte { copy(d[0:4], []byte{0xde, 0xad, 0xbe, 0xef}); return d }},
		{"zero table count", func(d []byte) []byte { d[4], d[5] = 0, 0; return d }},
		{"absurd table count", func(d []byte) []byte { d[4], d[5] = 0xff, 0xff; return d }},
		{"table offset past EOF", func(d []byte) []byte { copy(d[20:24], []byte{0xff, 0xff, 0xff, 0x00}); return d }},
		{"table length past EOF", func(d []byte) []byte { copy(d[24:28], []byte{0x7f, 0xff, 0xff, 0xff}); return d }},
		{"zero unitsPerEm", func(d []byte) []byte {
			o := findTableRaw(t, d, "head")
			if o >= 0 {
				d[o+18], d[o+19] = 0, 0
			}
			return d
		}},
		{"zero numGlyphs", func(d []byte) []byte {
			o := findTableRaw(t, d, "maxp")
			if o >= 0 {
				d[o+4], d[o+5] = 0, 0
			}
			return d
		}},
		{"huge numGlyphs", func(d []byte) []byte {
			o := findTableRaw(t, d, "maxp")
			if o >= 0 {
				d[o+4], d[o+5] = 0xff, 0xff
			}
			return d
		}},
		{"bogus loca format", func(d []byte) []byte {
			o := findTableRaw(t, d, "head")
			if o >= 0 {
				d[o+50], d[o+51] = 0x00, 0x07
			}
			return d
		}},
		{"cmap subtable offset past EOF", func(d []byte) []byte {
			o := findTableRaw(t, d, "cmap")
			if o >= 0 {
				copy(d[o+8:o+12], []byte{0xff, 0xff, 0xff, 0x00})
			}
			return d
		}},
		{"cmap absurd segment count", func(d []byte) []byte {
			o := findTableRaw(t, d, "cmap")
			if o >= 0 {
				// format 4 subtable at cmap+36, segCountX2 at +6
				copy(d[o+36+6:o+36+8], []byte{0xff, 0xfe})
			}
			return d
		}},
		{"loca last entry past glyf", func(d []byte) []byte {
			o := findTableRaw(t, d, "loca")
			head := findTableRaw(t, d, "head")
			maxp := findTableRaw(t, d, "maxp")
			if o >= 0 && head >= 0 && maxp >= 0 {
				ng := int(be16(d[maxp+4 : maxp+6]))
				format := int(int16(be16(d[head+50 : head+52])))
				if format == 0 {
					copy(d[o+2*ng:o+2*ng+2], []byte{0xff, 0xfe})
				} else {
					copy(d[o+4*ng:o+4*ng+4], []byte{0x0f, 0xff, 0xff, 0xff})
				}
			}
			return d
		}},
		{"self-referential composite", func(d []byte) []byte {
			// e-acute (composite): point its first component back at itself.
			gid := 618
			loc := findTableRaw(t, d, "loca")
			glyf := findTableRaw(t, d, "glyf")
			if loc >= 0 && glyf >= 0 {
				start := int(be32(d[loc+4*gid : loc+4*gid+4]))
				// numberOfContours (2) + flags (2) => glyphIndex at +4
				off := glyf + start + 4
				if off+2 <= len(d) {
					d[off], d[off+1] = byte(gid>>8), byte(gid&0xff)
					d[off-2], d[off-1] = byte(gid>>8), byte(gid&0xff)
				}
			}
			return d
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("PANIC on malformed input: %v", r)
				}
			}()
			d := tc.mut(cp())
			f, err := Parse(d)
			if err != nil {
				return // a clean typed error is the desired outcome
			}
			// Exercise everything a renderer would touch.
			for _, r := range []rune{'A', 'i', '\u00e9', ' ', '\U0001F600'} {
				_ = f.GlyphIndex(r)
				_ = f.AdvancePx(r, 16)
				_ = f.Measure(string(r), 16)
				_, _, _ = f.Glyph(f.GlyphIndex(r), 16)
				_, _ = f.Rasterize(r, 16)
			}
			for gid := uint16(0); gid < 40; gid++ {
				_, _, _ = f.Glyph(gid, 14)
				_, _ = f.GlyphData(gid)
			}
			_, _, _ = f.Glyph(uint16(f.NumGlyphs()), 14)
			_, _, _ = f.Glyph(0xffff, 14)
			_, _, _ = f.LineMetrics(16)
		})
	}
}

// TestGlyphOutOfRange: an absurd glyph id is an error, not a read.
func TestGlyphOutOfRange(t *testing.T) {
	f := loadFace(t, interPath)
	if _, _, err := f.Glyph(uint16(f.NumGlyphs()), 16); err == nil {
		t.Error("Glyph(numGlyphs) returned no error")
	}
	if _, _, err := f.Glyph(0xffff, 16); err == nil {
		t.Error("Glyph(0xffff) returned no error")
	}
	if _, err := f.GlyphData(0xffff); err == nil {
		t.Error("GlyphData(0xffff) returned no error")
	}
}

// TestNoForbiddenImports is the dependency guard: this package must stay
// stdlib-only so it compiles for the guest, and must never grow a
// golang.org/x/image or cgo dependency.
func TestNoForbiddenImports(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	fset := token.NewFileSet()
	scanned := 0
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := parser.ParseFile(fset, name, nil, parser.ImportsOnly)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		scanned++
		for _, imp := range src.Imports {
			p, err := strconv.Unquote(imp.Path.Value)
			if err != nil {
				t.Fatalf("%s: unquote %s: %v", name, imp.Path.Value, err)
			}
			if strings.HasPrefix(p, "golang.org/x/") {
				t.Errorf("%s imports %s: this package must have no external dependencies", name, p)
			}
			switch p {
			case "os", "time", "unsafe", "C":
				t.Errorf("%s imports %q: non-test sources must stay host-and-guest portable", name, p)
			}
			if p == "image" || strings.HasPrefix(p, "image/") {
				t.Errorf("%s imports %q: no image decoding in the font package", name, p)
			}
		}
	}
	if scanned == 0 {
		t.Fatal("scanned no source files — the import guard is not actually running")
	}
	t.Logf("import guard scanned %d non-test sources", scanned)

	mod, err := os.ReadFile("../go.mod")
	if err != nil {
		t.Fatalf("read ../go.mod: %v", err)
	}
	if strings.Contains(string(mod), "golang.org/x/") {
		t.Errorf("user/go/go.mod references golang.org/x:\n%s", mod)
	}
	if strings.Contains(string(mod), "require") {
		t.Errorf("user/go/go.mod grew a dependency block:\n%s", mod)
	}
}
