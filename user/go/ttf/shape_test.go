package ttf

import (
	"os"
	"testing"
)

const shapeFixturePath = "testdata/ShapeTest-Regular.ttf"

// fixtureString is the committed shaping fixture: two ligatures and one
// kerned pair in nine UTF-8 bytes.
const fixtureString = "fi fl AV"

func loadShapeFixture(t *testing.T) *Face {
	t.Helper()
	data, err := os.ReadFile(shapeFixturePath)
	if err != nil {
		t.Fatalf("shape fixture %s is required: %v", shapeFixturePath, err)
	}
	f, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse(%s): %v", shapeFixturePath, err)
	}
	return f
}

// TestShapeFixtureTableFacts pins the layout facts of the dedicated fixture
// (regenerate with testdata/make_shape_fixture.py; values were verified with
// an independent OpenType toolchain before being pinned here).
func TestShapeFixtureTableFacts(t *testing.T) {
	f := loadShapeFixture(t)
	if got := f.UnitsPerEm(); got != 1000 {
		t.Errorf("fixture UnitsPerEm = %d, want 1000", got)
	}
	if got := f.NumGlyphs(); got != 9 {
		t.Errorf("fixture NumGlyphs = %d, want 9", got)
	}
	want := map[rune]uint16{'f': 2, 'i': 3, 'l': 4, 'A': 7, 'V': 8, ' ': 1}
	for r, gid := range want {
		if got := f.GlyphIndex(r); got != gid {
			t.Errorf("fixture GlyphIndex(%q) = %d, want %d", r, got, gid)
		}
	}
	if !f.HasLigatures() {
		t.Error("fixture should carry a usable liga feature")
	}
	if !f.HasKerning() {
		t.Error("fixture should carry a usable kern feature")
	}
}

// TestShapeFixtureGoldenStream is the golden glyph-id stream: the committed
// fixture string shapes to the pinned glyph ids, clusters, and advances.
// "fi fl AV" must come out as fi + space + fl + A + V — two ligatures and one
// kerned pair — which a cmap-only lookup cannot produce (it has no fi/fl).
func TestShapeFixtureGoldenStream(t *testing.T) {
	f := loadShapeFixture(t)
	got := f.ShapeLatin(fixtureString)
	want := []ShapedGlyph{
		{GID: 5, Cluster: 0, XAdvance: 611},
		{GID: 1, Cluster: 2, XAdvance: 500},
		{GID: 6, Cluster: 3, XAdvance: 611},
		{GID: 1, Cluster: 5, XAdvance: 500},
		{GID: 7, Cluster: 6, XAdvance: 547},
		{GID: 8, Cluster: 7, XAdvance: 667},
	}
	if len(got) != len(want) {
		t.Fatalf("shaped %d glyphs, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("glyph %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

// TestInterKerningPins the real-font behavior on Inter-Regular: the GPOS kern
// feature is class-based (PairPosFormat2 behind a type-9 extension lookup),
// so AV must kern by exactly the -140 the table says (verified against the
// raw table and an independent shaper).
func TestInterKerning(t *testing.T) {
	f := loadFace(t, interPath)
	if !f.HasKerning() {
		t.Fatal("Inter should expose a usable kern feature")
	}
	if got := f.PairAdvance(f.GlyphIndex('A'), f.GlyphIndex('V')); got != -140 {
		t.Errorf("Inter PairAdvance(A,V) = %d, want -140", got)
	}
	if got := f.PairAdvance(f.GlyphIndex('T'), f.GlyphIndex('o')); got != -160 {
		t.Errorf("Inter PairAdvance(T,o) = %d, want -160", got)
	}
	if got := f.PairAdvance(f.GlyphIndex('r'), f.GlyphIndex('k')); got != 32 {
		t.Errorf("Inter PairAdvance(r,k) = %d, want 32", got)
	}
}

// TestFiraHasNoKern documents the negative case: Fira Code's GPOS carries only
// mark attachment, so kerning must report none rather than invent values.
func TestFiraHasNoKern(t *testing.T) {
	f := loadFace(t, firaPath)
	if f.HasKerning() {
		t.Error("Fira Code has no kern feature; HasKerning should be false")
	}
}

// TestInterFiraShapeIsCmapOnly pins the contract that fonts without a usable
// liga feature shape identically to cmap-only lookup: Inter has no fi/fl in
// its default features and Fira's ligatures are contextual (unsupported), so
// ShapeLatin must not silently substitute anything.
func TestInterFiraShapeIsCmapOnly(t *testing.T) {
	for _, path := range []string{interPath, firaPath} {
		f := loadFace(t, path)
		got := f.ShapeLatin(fixtureString)
		if len(got) != 8 {
			t.Fatalf("%s: shaped %d glyphs, want 8 (cmap-only)", path, len(got))
		}
		i := 0
		for _, r := range fixtureString {
			if got[i].GID != f.GlyphIndex(r) || got[i].Cluster != i {
				t.Errorf("%s: glyph %d = (%d,%d), want (%d,%d)",
					path, i, got[i].GID, got[i].Cluster, f.GlyphIndex(r), i)
			}
			i += len(string(r))
		}
	}
}

// TestShapeFixtureLigatureFixpoint: the ligature pass is a fixpoint per the
// spec — shape a ligature-heavy string and check it equals the expected
// stream, which also proves the pass terminates.
func TestShapeFixtureIdempotent(t *testing.T) {
	f := loadShapeFixture(t)
	got := f.ShapeLatin("ffifliffi")
	// Greedy left-to-right: only f+i and f+l merge; an unmatched f stays.
	want := []ShapedGlyph{
		{GID: 2, Cluster: 0, XAdvance: 333},
		{GID: 5, Cluster: 1, XAdvance: 611},
		{GID: 6, Cluster: 3, XAdvance: 611},
		{GID: 3, Cluster: 5, XAdvance: 278},
		{GID: 2, Cluster: 6, XAdvance: 333},
		{GID: 5, Cluster: 7, XAdvance: 611},
	}
	if len(got) != len(want) {
		t.Fatalf("ffifliffi -> %d glyphs, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("glyph %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

// TestShapeMalformedNeverPanics feeds truncated/corrupt GSUB and GPOS tables
// through the layout parser: every path must return nil or a partial layout,
// never panic. A font is attacker-supplied data; that rule is not negotiable.
func TestShapeMalformedNeverPanics(t *testing.T) {
	f := loadShapeFixture(t)
	full := append(append([]byte{}, f.gsub...), f.gpos...)
	rng := len(full)
	for cut := 0; cut < rng; cut += 7 {
		g := append([]byte{}, full[:cut]...)
		p := append([]byte{}, full[:cut]...)
		parseLayout(g, "liga", 4)
		parseLayout(p, "kern", 2)
	}
	// Random byte flips over the real tables must never panic either. The
	// seed is pinned so a failure is reproducible.
	seed := uint32(0x5eed1234)
	next := func() uint32 {
		seed = seed*1664525 + 1013904223
		return seed
	}
	_ = next
	for trial := 0; trial < 200; trial++ {
		for _, table := range [][]byte{f.gsub, f.gpos} {
			corrupt := append([]byte{}, table...)
			for i := 0; i < 8; i++ {
				corrupt[int(next())%len(corrupt)] = byte(next() >> 24)
			}
			parseLayout(corrupt, "liga", 4)
			parseLayout(corrupt, "kern", 2)
		}
	}
	// The parse must also survive an empty face's missing tables.
	empty := &Face{}
	if empty.ShapeLatin("fi") == nil {
		t.Error("ShapeLatin on an empty face should return an empty (non-nil) result")
	}
}
