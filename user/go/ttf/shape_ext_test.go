package ttf

import "testing"

// buildExtLayout assembles a minimal GPOS-shaped table by hand: latn script,
// kern feature, one ExtensionPos (type 9) lookup wrapping one PairPosFormat1
// subtable holding a single pair A,V -> XAdvance -120. Byte-for-byte it is
// the structure an extension-using font carries, so a pass here proves the
// extension dereference and the pair parse in isolation.
//
// Layout (offsets from table start; the header is 10 bytes):
//
//	 0 header (10 bytes)
//	10 ScriptList (20 bytes: list + script + langsys)
//	30 FeatureList (14 bytes: list + feature)
//	44 LookupList (4 bytes header)
//	48 Lookup (8 bytes: type 9, flag 0, count 1, off[0]=8)
//	56 ExtensionFormat1 (8 bytes: fmt 1, type 2, offset 8)
//	68 PairPosFormat1 (12 bytes header)
//	80 Coverage (6 bytes)
//	86 PairSet (6 bytes)
func buildExtLayout() []byte {
	b := []byte{}
	put16 := func(v int) { b = append(b, byte(v>>8), byte(v)) }
	put32 := func(v uint32) {
		b = append(b, byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
	}
	put32(0x00010000)
	put16(10) // script list
	put16(30) // feature list
	put16(44) // lookup list

	// ScriptList at 10: count=1; 'latn' -> script at 10+8=18.
	put16(1)
	b = append(b, 'l', 'a', 't', 'n')
	put16(8)
	// Script at 18: defaultLangSys@4 -> LangSys at 22.
	put16(4)
	put16(0)
	// LangSys at 22: order 0, req FFFF, count 1, indices [0].
	put16(0)
	put16(0xFFFF)
	put16(1)
	put16(0)

	// FeatureList at 30: count=1; 'kern' -> feature table at 30+8=38.
	put16(1)
	b = append(b, 'k', 'e', 'r', 'n')
	put16(8)
	// Feature at 38: params 0, lookupCount 1, lookups [0].
	put16(0)
	put16(1)
	put16(0)

	// LookupList at 44: count=1, offset[0]=4 -> lookup at 48.
	put16(1)
	put16(4)
	// Lookup at 48: type 9 (ExtensionPos), flag 0, subTableCount 1, off[0]=8.
	put16(9)
	put16(0)
	put16(1)
	put16(8)
	// ExtensionFormat1 at 56: format 1, extension type 2, offset 8 -> 64.
	put16(1)
	put16(2)
	put32(8)
	// PairPosFormat1 at 64: fmt 1, coverage@12, vf1 0x0004 (XAdvance), vf2 0,
	// pairSetCount 1, pairSet@18.
	put16(1)
	put16(12)
	put16(0x0004)
	put16(0)
	put16(1)
	put16(18)
	// Coverage at 64+12=76, fmt 1: count 1, glyph 7 (A).
	put16(1)
	put16(1)
	put16(7)
	// PairSet at 64+18=82: count 1; second=8 (V), value1 XAdvance = -120.
	put16(1)
	put16(8)
	put16(-120 & 0xFFFF)
	return b
}

// TestParseExtensionLookupIsolated drives parseLayout over the hand-built
// extension table: the kern pair must survive the type-9 hop.
func TestParseExtensionLookupIsolated(t *testing.T) {
	lay := parseLayout(buildExtLayout(), "kern", 2)
	if lay == nil {
		t.Fatal("extension lookup did not resolve to a pair layout")
	}
	m, ok := lay.pairs[7]
	if !ok {
		t.Fatalf("no pair entry for first glyph 7: %v", lay.pairs)
	}
	if m[8] != -120 {
		t.Errorf("pair (7,8) = %d, want -120", m[8])
	}
}
