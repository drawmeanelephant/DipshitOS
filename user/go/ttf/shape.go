package ttf

// Opt-in Latin shaping on top of the parsed cmap view of the font: GSUB
// ligature substitution (lookup type 4) and GPOS pair kerning (lookup type 2).
// A font without the tables, scripts, or features shapes as a no-op, so every
// existing cmap-only caller keeps its behavior unless it calls ShapeLatin.

// ShapedGlyph is one slot of the shaped output. GID is the substituted glyph
// id and Cluster is the UTF-8 byte offset in the input string where the
// cluster that produced this glyph begins. XAdvance/XOffset/YOffset are in
// font design units (UPEM), the same space as GlyphAdvanceUPEM.
type ShapedGlyph struct {
	GID      uint16
	Cluster  int
	XAdvance int
	XOffset  int
	YOffset  int
}

// scriptTag builds a big-endian four-byte OpenType tag like 'latn'.
func scriptTag(a, b, c, d byte) uint32 {
	return uint32(a)<<24 | uint32(b)<<16 | uint32(c)<<8 | uint32(d)
}

// Script tags this package resolves, as big-endian words.
const (
	scriptLatn = 0x6c61746e // 'latn'
	scriptDFLT = 0x44464c54 // 'DFLT'
)

// layout is the parsed subset of GSUB/GPOS this package understands: one
// feature per table (liga / kern), resolved through the default LangSys of
// the latn or DFLT script. Everything else in the tables is ignored; anything
// malformed leaves the feature unset and shaping falls back to cmap-only.
type layout struct {
	// ligatures maps first glyph id -> its ligature sets in feature order.
	ligatures map[uint16][]ligatureSet
	// pairs maps first glyph id -> second glyph id -> x advance adjustment.
	pairs map[uint16]map[uint16]int
	// classPairs holds deferred PairPosFormat2 subtables, each with the
	// subtable base offset it was parsed from.
	classPairs []classPairTable
}

// ligatureSet is one first-glyph's list of (components, ligature glyph),
// longest component list first so greedy matching is correct.
type ligatureSet struct {
	comps []uint16
	lig   uint16
}

// parseLayout walks one layout table (GSUB or GPOS). It returns a nil layout
// (no error) when the table is absent, truncated, or carries nothing this
// package implements: shaping must degrade to cmap-only, never fail hard on
// a feature it does not need.
func parseLayout(data []byte, wantFeature string, wantLookupType int) *layout {
	if len(data) < 10 {
		return nil
	}
	scriptList := int(be16(data[4:6]))
	featureList := int(be16(data[6:8]))
	lookupList := int(be16(data[8:10]))

	// ScriptList -> the latn (then DFLT) script's default LangSys -> the
	// feature index whose tag matches -> that feature's lookups.
	scriptBase := -1
	for _, wantScript := range []uint32{scriptLatn, scriptDFLT} {
		scriptBase = findScript(data, scriptList, wantScript)
		if scriptBase >= 0 {
			break
		}
	}
	if scriptBase < 0 {
		return nil
	}
	lookupIdxs := featureLookups(data, scriptBase, featureList, wantFeature)
	if len(lookupIdxs) == 0 {
		return nil
	}

	lay := &layout{}
	for _, li := range lookupIdxs {
		parseLookup(data, lookupList, li, wantLookupType, lay)
	}
	if len(lay.ligatures) == 0 && len(lay.pairs) == 0 && len(lay.classPairs) == 0 {
		return nil
	}
	return lay
}

// findScript returns the byte offset of the named script's Script table, or
// -1 when the script list does not carry it.
func findScript(data []byte, scriptList int, want uint32) int {
	if scriptList <= 0 || scriptList+2 > len(data) {
		return -1
	}
	n := int(be16(data[scriptList : scriptList+2]))
	for i := 0; i < n; i++ {
		p := scriptList + 2 + i*6
		if p+6 > len(data) {
			return -1
		}
		if be32(data[p:p+4]) == want {
			off := int(be16(data[p+4 : p+6]))
			base := scriptList + off
			if base < 0 || base >= len(data) {
				return -1
			}
			return base
		}
	}
	return -1
}

// featureLookups resolves the script's default LangSys to the lookup indexes
// of the first feature whose tag matches want.
func featureLookups(data []byte, scriptBase, featureList int, want string) []int {
	if scriptBase+4 > len(data) {
		return nil
	}
	// Script table: offset16 defaultLangSys, uint16 langSysCount, records.
	// defaultLangSys == 0 means the script has no default LangSys.
	defOff := int(be16(data[scriptBase : scriptBase+2]))
	if defOff == 0 {
		return nil
	}
	langSys := scriptBase + defOff
	if langSys+6 > len(data) {
		return nil
	}
	// LangSys table: offset16 lookupOrder, uint16 reqFeatureIndex,
	// uint16 featureIndexCount, uint16 featureIndices[].
	n := int(be16(data[langSys+4 : langSys+6]))
	for i := 0; i < n; i++ {
		p := langSys + 6 + i*2
		if p+2 > len(data) {
			return nil
		}
		idx := int(be16(data[p : p+2]))
		fp := featureList + 2 + idx*6
		if fp+6 > len(data) {
			continue
		}
		if string(data[fp:fp+4]) != want {
			continue
		}
		// Feature table: offset16 featureParams, uint16 lookupCount,
		// uint16 lookupListIndices[]. The record's offset is relative to
		// the FeatureList, not the record.
		fo := featureList + int(be16(data[fp+4:fp+6]))
		if fo+4 > len(data) {
			return nil
		}
		cnt := int(be16(data[fo+2 : fo+4]))
		if fo+4+cnt*2 > len(data) {
			return nil
		}
		out := make([]int, 0, cnt)
		for j := 0; j < cnt; j++ {
			out = append(out, int(be16(data[fo+4+j*2:fo+6+j*2])))
		}
		return out
	}
	return nil
}

// Lookup extension wrappers re-wrap a lookup's subtables once. GSUB type 7
// and GPOS type 9: uint16 format (=1), uint16 extensionLookupType, uint32
// extensionOffset (relative to the ExtensionFormat1 structure). Inter's kern
// feature is entirely behind a GPOS extension, so without this the real
// font's kerning would be invisible.
const (
	extSubst = 7
	extPos   = 9
)

// parseLookup appends one lookup's contribution to lay, when its type is the
// wanted one and its subtables parse.
//
// LookupList: uint16 lookupCount, offset16 lookups[]. Lookup: uint16 type,
// uint16 flag, uint16 subTableCount, offset16 subtableOffsets[] (all relative
// to the Lookup table itself).
func parseLookup(data []byte, lookupList, idx, wantType int, lay *layout) {
	base := lookupList + 2 + idx*2
	if base < 0 || base+2 > len(data) {
		return
	}
	lookup := lookupList + int(be16(data[base:base+2]))
	if lookup+6 > len(data) {
		return
	}
	lookupType := int(be16(data[lookup : lookup+2]))
	if lookupType == extSubst || lookupType == extPos {
		// Type 7 unwraps GSUB lookups, type 9 unwraps GPOS lookups.
		// A wrapper from the other table is ignored, not reinterpreted.
		if (lookupType == extSubst && wantType != 4) || (lookupType == extPos && wantType != 2) {
			return
		}
		n := int(be16(data[lookup+4 : lookup+6]))
		for i := 0; i < n; i++ {
			p := lookup + 6 + i*2
			if p+2 > len(data) {
				return
			}
			ext := lookup + int(be16(data[p:p+2]))
			if ext+8 > len(data) || int(be16(data[ext:ext+2])) != 1 {
				continue
			}
			if int(be16(data[ext+2:ext+4])) != wantType {
				continue
			}
			// uint32 offset; fonts under 4 GiB only use the low bits, but a
			// negative wrap must be rejected before it is used as an index.
			extOff := int(int64(be32(data[ext+4 : ext+8])))
			sub := ext + extOff
			if sub < 0 || sub >= len(data) {
				continue
			}
			switch wantType {
			case 4:
				parseLigatureSubtable(data, sub, lay)
			case 2:
				parsePairSubtable(data, sub, lay)
			}
		}
		return
	}
	if lookupType != wantType {
		return
	}
	n := int(be16(data[lookup+4 : lookup+6]))
	for i := 0; i < n; i++ {
		p := lookup + 6 + i*2
		if p+2 > len(data) {
			return
		}
		off := int(be16(data[p : p+2]))
		sub := lookup + off
		if sub < 0 || sub >= len(data) {
			continue
		}
		switch wantType {
		case 4:
			parseLigatureSubtable(data, sub, lay)
		case 2:
			parsePairSubtable(data, sub, lay)
		}
	}
}

// parseLigatureSubtable decodes a GSUB lookup type 4 (ligature substitution),
// format 1: coverage of first glyphs, then per-glyph ligature sets.
//
// LigatureSubstFormat1:
//
//	uint16 substFormat (=1)
//	offset16 coverage
//	uint16 ligSetCount
//	offset16 ligSet[ligSetCount]
//
// LigatureSet:
//
//	uint16 ligatureCount
//	offset16 ligatureOffsets[ligatureCount]
//
// Ligature:
//
//	uint16 ligatureGlyph
//	uint16 componentCount
//	uint16 componentGlyphIDs[componentCount-1]
func parseLigatureSubtable(data []byte, sub int, lay *layout) {
	if sub+6 > len(data) || int(be16(data[sub:sub+2])) != 1 {
		return
	}
	cov := parseCoverage(data, offsetTable(sub, be16(data[sub+2:sub+4])))
	if cov == nil {
		return
	}
	setCount := int(be16(data[sub+4 : sub+6]))
	if setCount != len(cov) {
		return
	}
	if lay.ligatures == nil {
		lay.ligatures = make(map[uint16][]ligatureSet)
	}
	for i, first := range cov {
		p := sub + 6 + i*2
		if p+2 > len(data) {
			return
		}
		set := sub + int(be16(data[p:p+2]))
		if set+2 > len(data) {
			continue
		}
		ligCount := int(be16(data[set : set+2]))
		for j := 0; j < ligCount; j++ {
			lp := set + 2 + j*2
			if lp+2 > len(data) {
				break
			}
			lo := set + int(be16(data[lp:lp+2]))
			if lo+4 > len(data) {
				continue
			}
			lig := uint16(be16(data[lo : lo+2]))
			compCount := int(be16(data[lo+2 : lo+4]))
			if compCount < 2 || compCount > 64 {
				continue
			}
			if lo+4+(compCount-1)*2 > len(data) {
				continue
			}
			comps := make([]uint16, compCount)
			comps[0] = first
			for k := 1; k < compCount; k++ {
				comps[k] = be16(data[lo+2+k*2 : lo+4+k*2])
			}
			set2 := ligatureSet{comps: comps, lig: lig}
			lay.ligatures[first] = append(lay.ligatures[first], set2)
		}
	}
	for first, sets := range lay.ligatures {
		sortLigatureSets(sets)
		lay.ligatures[first] = sets
	}
}

// sortLigatureSets orders longest-first so greedy matching takes the most
// specific ligature. Insertion sort: the lists are tiny.
func sortLigatureSets(sets []ligatureSet) {
	for i := 1; i < len(sets); i++ {
		for j := i; j > 0 && len(sets[j].comps) > len(sets[j-1].comps); j-- {
			sets[j], sets[j-1] = sets[j-1], sets[j]
		}
	}
}

// parsePairSubtable decodes a GPOS lookup type 2 (pair positioning). Format 1
// is the per-pair form, format 2 the class-matrix form; both are reduced to
// first-glyph -> second-glyph -> XAdvance. Only the XAdvance field of
// ValueRecord is consumed; everything else in the value records is ignored.
func parsePairSubtable(data []byte, sub int, lay *layout) {
	if sub+2 > len(data) {
		return
	}
	switch int(be16(data[sub : sub+2])) {
	case 1:
		parsePairFormat1(data, sub, lay)
	case 2:
		parsePairFormat2(data, sub, lay)
	}
}

// offsetTable resolves an OpenType offset16 relative to base. Offset 0 is
// NULL (the table is absent), not "the table starts at base".
func offsetTable(base int, offset uint16) int {
	if offset == 0 {
		return -1
	}
	return base + int(offset)
}

// maxRangeGlyphs caps Format-2 Coverage / ClassDef range expansion. A font
// is attacker-supplied data; a handful of 0..65535 ranges must not
// materialize unbounded slices or burn CPU.
const maxRangeGlyphs = 65536

// parseCoverage decodes a coverage table (either format) into its ordered
// glyph list. Returns nil for anything malformed.
func parseCoverage(data []byte, cov int) []uint16 {
	if cov < 0 || cov+4 > len(data) {
		return nil
	}
	switch int(be16(data[cov : cov+2])) {
	case 1:
		n := int(be16(data[cov+2 : cov+4]))
		if cov+4+n*2 > len(data) {
			return nil
		}
		out := make([]uint16, n)
		for i := 0; i < n; i++ {
			out[i] = be16(data[cov+4+i*2 : cov+6+i*2])
		}
		return out
	case 2:
		// CoverageFormat2: uint16 format, uint16 rangeCount, then
		// RangeRecords (start, end, startCoverageIndex) of 6 bytes.
		// A single range is 4+6 = 10 bytes; do not demand a 12-byte
		// header. The glyph list is the glyph ids (start..end), not
		// the startCoverageIndex column.
		n := int(be16(data[cov+2 : cov+4]))
		out := make([]uint16, 0, n)
		for i := 0; i < n; i++ {
			p := cov + 4 + i*6
			if p+6 > len(data) {
				return nil
			}
			start := be16(data[p : p+2])
			end := be16(data[p+2 : p+4])
			if end < start {
				continue
			}
			for g := start; ; g++ {
				if len(out) >= maxRangeGlyphs {
					return nil
				}
				out = append(out, g)
				if g == end {
					break
				}
			}
		}
		return out
	}
	return nil
}

// xAdvanceShift is the bit position of XAdvance in a GPOS ValueFormat mask.
// Order per spec: XPlacement, YPlacement, XAdvance, YAdvance, XPlaDevice,
// YPlaDevice, XAdvDevice, YAdvDevice (bits 0..7).
const xAdvanceShift = 2

// readXAdvance reads the XAdvance field of a value record with the given
// format at off. Bounds-checked; ok is false past the end of data.
func readXAdvance(data []byte, off int, format int) (int, bool) {
	if format&(1<<xAdvanceShift) == 0 {
		return 0, true
	}
	// ValueRecord field order: XPlacement, YPlacement, XAdvance, …
	skip := 0
	if format&0x01 != 0 {
		skip += 2
	}
	if format&0x02 != 0 {
		skip += 2
	}
	p := off + skip
	if p < 0 || p+2 > len(data) {
		return 0, false
	}
	return int(int16(be16(data[p : p+2]))), true
}

// parseValueRecord reads a GPOS value record per the given format at off and
// returns its XAdvance (the only field this package consumes) plus the offset
// past the record. Returns (0, off, false) when the record runs past the end.
func parseValueRecord(data []byte, off int, format int) (int, int, bool) {
	x, ok := readXAdvance(data, off, format)
	if !ok {
		return 0, off, false
	}
	next := off + valueLen(format)
	if next > len(data) {
		return 0, off, false
	}
	return x, next, true
}

// parsePairFormat1 decodes PairPosFormat1: one coverage of first glyphs and a
// PairSet per covered glyph, each PairSet a list of (secondGlyph, value1,
// value2) records.
//
// PairPosFormat1: uint16 posFormat, offset16 coverage, uint16 valueFormat1,
// uint16 valueFormat2, uint16 pairSetCount, offset16 pairSetOffsets[].
func parsePairFormat1(data []byte, sub int, lay *layout) {
	if sub+10 > len(data) || int(be16(data[sub:sub+2])) != 1 {
		return
	}
	cov := parseCoverage(data, offsetTable(sub, be16(data[sub+2:sub+4])))
	if cov == nil {
		return
	}
	valueFormat1 := int(be16(data[sub+4 : sub+6]))
	valueFormat2 := int(be16(data[sub+6 : sub+8]))
	pairSetCount := int(be16(data[sub+8 : sub+10]))
	if pairSetCount != len(cov) {
		return
	}
	if lay.pairs == nil {
		lay.pairs = make(map[uint16]map[uint16]int)
	}
	for i, first := range cov {
		p := sub + 10 + i*2
		if p+2 > len(data) {
			return
		}
		ps := sub + int(be16(data[p:p+2]))
		if ps+2 > len(data) {
			continue
		}
		n := int(be16(data[ps : ps+2]))
		for j := 0; j < n; j++ {
			q := ps + 2 + j*recordLen(valueFormat1, valueFormat2)
			if q+2 > len(data) {
				break
			}
			second := be16(data[q : q+2])
			x1, _, ok := parseValueRecord(data, q+2, valueFormat1)
			if !ok {
				break
			}
			if x1 == 0 {
				continue
			}
			m := lay.pairs[first]
			if m == nil {
				m = make(map[uint16]int)
				lay.pairs[first] = m
			}
			m[second] += x1
		}
	}
}

// recordLen is the byte size of one PairValueRecord for the two formats:
// uint16 secondGlyph plus both value records.
func recordLen(format1, format2 int) int {
	return 2 + valueLen(format1) + valueLen(format2)
}

// parsePairFormat2 decodes PairPosFormat2: class-based pair kerning through
// two class definition tables over one coverage of first glyphs. The class
// matrix is only consulted for (first, second) pairs the shaper actually
// asks about, so nothing is materialized up front; lookups happen in
// PairAdvance at shape time.
func parsePairFormat2(data []byte, sub int, lay *layout) {
	if sub+16 > len(data) {
		return
	}
	// PairPosFormat2 header: fmt, coverage, valueFormat1, valueFormat2,
	// classDef1, classDef2, class1Count, class2Count — value formats
	// come before the class-def offsets.
	cov := parseCoverage(data, offsetTable(sub, be16(data[sub+2:sub+4])))
	cd1 := parseClassDef(data, offsetTable(sub, be16(data[sub+8:sub+10])))
	cd2 := parseClassDef(data, offsetTable(sub, be16(data[sub+10:sub+12])))
	if cov == nil || cd1 == nil || cd2 == nil {
		return
	}
	if lay.classPairs == nil {
		lay.classPairs = make([]classPairTable, 0, 1)
	}
	lay.classPairs = append(lay.classPairs, classPairTable{
		sub:          sub,
		cov:          cov,
		cd1:          cd1,
		cd2:          cd2,
		valueFormat1: int(be16(data[sub+4 : sub+6])),
		valueFormat2: int(be16(data[sub+6 : sub+8])),
		class1Count:  int(be16(data[sub+12 : sub+14])),
		class2Count:  int(be16(data[sub+14 : sub+16])),
	})
}

// classPairTable is one deferred PairPosFormat2 subtable: resolved at shape
// time per (first, second) glyph pair instead of materialized up front — the
// class matrix of a real font can be tens of thousands of entries, and a
// screen of text asks about a few hundred pairs.
type classPairTable struct {
	sub          int
	cov          []uint16
	cd1, cd2     map[uint16]int
	valueFormat1 int
	valueFormat2 int
	class1Count  int
	class2Count  int
}

// inCoverage reports whether gid is in the table's coverage (class 0 is the
// implicit class for everything, so the coverage gate is what matters).
func (t *classPairTable) inCoverage(gid uint16) bool {
	for _, g := range t.cov {
		if g == gid {
			return true
		}
	}
	return false
}

// pairAdjust returns the XAdvance for (first, second) from this table, or
// false when the pair has no entry.
func (t *classPairTable) pairAdjust(data []byte, first, second uint16) (int, bool) {
	if !t.inCoverage(first) {
		return 0, false
	}
	c1, ok := t.cd1[first]
	if !ok {
		c1 = 0
	}
	c2, ok := t.cd2[second]
	if !ok {
		c2 = 0
	}
	if c1 >= t.class1Count || c2 >= t.class2Count {
		return 0, false
	}
	vl1, vl2 := valueLen(t.valueFormat1), valueLen(t.valueFormat2)
	off := t.sub + 16 + (int(c1)*t.class2Count+int(c2))*(vl1+vl2)
	return readXAdvance(data, off, t.valueFormat1)
}

// valueLen is the byte length of a GPOS ValueRecord for the given format.
// Each of the eight ValueFormat bits occupies a uint16 in the record
// (the four Device-table bits store an offset16, still two bytes).
func valueLen(format int) int {
	n := 0
	for bit := 0; bit < 8; bit++ {
		if format&(1<<bit) != 0 {
			n += 2
		}
	}
	return n
}

// parseClassDef decodes a class definition table (either format) into a
// glyph -> class map. Class 0 is the implicit default and is not stored.
func parseClassDef(data []byte, cd int) map[uint16]int {
	if cd < 0 || cd+4 > len(data) {
		return nil
	}
	switch int(be16(data[cd : cd+2])) {
	case 1:
		if cd+6 > len(data) {
			return nil
		}
		start := be16(data[cd+2 : cd+4])
		n := int(be16(data[cd+4 : cd+6]))
		if cd+6+n*2 > len(data) {
			return nil
		}
		m := make(map[uint16]int, n)
		for i := 0; i < n; i++ {
			if cls := int(be16(data[cd+6+i*2 : cd+8+i*2])); cls != 0 {
				m[start+uint16(i)] = cls
			}
		}
		return m
	case 2:
		n := int(be16(data[cd+2 : cd+4]))
		if cd+4+n*6 > len(data) {
			return nil
		}
		m := make(map[uint16]int, n*4)
		for i := 0; i < n; i++ {
			p := cd + 4 + i*6
			start := be16(data[p : p+2])
			end := be16(data[p+2 : p+4])
			cls := int(be16(data[p+4 : p+6]))
			if end < start || cls == 0 {
				continue
			}
			for g := start; ; g++ {
				if len(m) >= maxRangeGlyphs {
					return nil
				}
				m[g] = cls
				if g == end {
					break
				}
			}
		}
		return m
	}
	return nil
}

// ligInit parses (once) the GSUB liga feature for this face.
func (f *Face) ligInit() *layout {
	if !f.ligaInit {
		f.ligaInit = true
		f.liga = parseLayout(f.gsub, "liga", 4)
	}
	return f.liga
}

// kernLayout parses (once) the GPOS kern feature for this face.
func (f *Face) kernLayout() *layout {
	if !f.kernInit {
		f.kernInit = true
		f.kern = parseLayout(f.gpos, "kern", 2)
	}
	return f.kern
}

// PairAdvanceUPEM is the total kerning adjustment between first and second in
// font design units: the sum of every kern lookup's contribution, which is
// how HarfBuzz treats multiple lookups over one pair. Fonts without a GPOS
// kern feature always report 0.
func (f *Face) PairAdvance(first, second uint16) int {
	l := f.kernLayout()
	if l == nil {
		return 0
	}
	total := 0
	if m, ok := l.pairs[first]; ok {
		total += m[second]
	}
	for i := range l.classPairs {
		if x, ok := l.classPairs[i].pairAdjust(f.gpos, first, second); ok {
			total += x
		}
	}
	return total
}

// HasLigatures reports whether the font carries a liga feature this package
// can apply.
func (f *Face) HasLigatures() bool { return f.ligInit() != nil }

// HasKerning reports whether the font carries a kern feature this package
// can apply.
func (f *Face) HasKerning() bool { return f.kernLayout() != nil }

// ShapeLatin maps text to glyph ids through the cmap and then applies the
// opt-in layout pass: greedy longest-first ligature substitution from GSUB
// liga, then GPOS pair kerning between adjacent glyphs. Clusters are UTF-8
// byte offsets of the first rune of each cluster, so a ligature points at
// the byte offset of its first component. Advances and offsets are font
// design units; scale them with scaleUPEM via AdvanceGIDPx-style math at
// render time.
//
// The shaping model is deliberately the fixed-point form HarfBuzz uses for
// these features: ligature substitution may enable a later ligature (f + fi
// + i patterns), so the liga pass repeats until no substitution fires; pair
// positioning is one pass, in lookup order, over the final glyph stream.
// Unsupported tables, scripts, or features shape as a cmap-only no-op.
func (f *Face) ShapeLatin(text string) []ShapedGlyph {
	// cmap pass: one glyph per UTF-8 rune, clusters at rune starts.
	gids := make([]uint16, 0, len(text))
	clusters := make([]int, 0, len(text))
	for i, r := range text {
		gids = append(gids, f.GlyphIndex(r))
		clusters = append(clusters, i)
	}

	// GSUB liga: greedy left-to-right, longest component list first,
	// repeating until a full pass makes no substitution.
	if l := f.ligInit(); l != nil {
		for changed := true; changed; {
			changed = false
			out := make([]ShapedGlyph, 0, len(gids))
			for i := 0; i < len(gids); i++ {
				g := ShapedGlyph{GID: gids[i], Cluster: clusters[i]}
				matched := false
				if sets, ok := l.ligatures[gids[i]]; ok {
					for _, ls := range sets {
						if i+len(ls.comps) <= len(gids) {
							ok := true
							for k := 1; k < len(ls.comps); k++ {
								if gids[i+k] != ls.comps[k] {
									ok = false
									break
								}
							}
							if ok {
								out = append(out, ShapedGlyph{GID: ls.lig, Cluster: clusters[i]})
								i += len(ls.comps) - 1
								matched = true
								changed = true
								break
							}
						}
					}
				}
				if !matched {
					out = append(out, g)
				}
			}
			gids = gids[:0]
			clusters = clusters[:0]
			for _, s := range out {
				gids = append(gids, s.GID)
				clusters = append(clusters, s.Cluster)
			}
		}
	}

	out := make([]ShapedGlyph, len(gids))
	for i := range gids {
		out[i] = ShapedGlyph{
			GID:      gids[i],
			Cluster:  clusters[i],
			XAdvance: f.GlyphAdvanceUPEM(gids[i]),
		}
	}
	if k := f.kernLayout(); k != nil {
		for i := 0; i+1 < len(out); i++ {
			out[i].XAdvance += f.PairAdvance(gids[i], gids[i+1])
		}
	}
	return out
}
