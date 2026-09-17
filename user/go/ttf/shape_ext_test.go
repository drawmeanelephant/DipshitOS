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
//	64 PairPosFormat1 (12 bytes header)
//	76 Coverage (6 bytes)
//	82 PairSet (6 bytes)
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

// buildPairFormat2Layout is a GPOS table whose only kern lookup is
// PairPosFormat2 (class matrix, no format-1 pairs). A pass here proves
// parseLayout does not drop a class-only feature, which is how many
// real fonts (Inter included) store kerning.
//
// Layout (offsets from table start):
//
//	 0 header (10)
//	10 ScriptList / Script / LangSys (20)
//	30 FeatureList / Feature (14)
//	44 LookupList (4)
//	48 Lookup type 2 (8)
//	56 PairPosFormat2 header (16) + 2x2 XAdvance matrix (8)
//	80 Coverage (6)
//	86 ClassDef1 (8)
//	94 ClassDef2 (8)
func buildPairFormat2Layout() []byte {
	b := []byte{}
	put16 := func(v int) { b = append(b, byte(v>>8), byte(v)) }
	put32 := func(v uint32) {
		b = append(b, byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
	}
	put32(0x00010000)
	put16(10)
	put16(30)
	put16(44)

	put16(1)
	b = append(b, 'l', 'a', 't', 'n')
	put16(8)
	put16(4)
	put16(0)
	put16(0)
	put16(0xFFFF)
	put16(1)
	put16(0)

	put16(1)
	b = append(b, 'k', 'e', 'r', 'n')
	put16(8)
	put16(0)
	put16(1)
	put16(0)

	put16(1)
	put16(4)
	put16(2)
	put16(0)
	put16(1)
	put16(8)

	// PairPosFormat2 at 56: coverage@24, vf1 XAdvance, vf2 0,
	// classDef1@30, classDef2@38, class1Count=2, class2Count=2.
	put16(2)
	put16(24)
	put16(0x0004)
	put16(0)
	put16(30)
	put16(38)
	put16(2)
	put16(2)
	// Matrix: only class1=1, class2=1 is -120.
	put16(0)
	put16(0)
	put16(0)
	put16(-120 & 0xFFFF)

	// Coverage at 80: glyph 7 (A).
	put16(1)
	put16(1)
	put16(7)
	// ClassDef1 at 86: glyph 7 -> class 1.
	put16(1)
	put16(7)
	put16(1)
	put16(1)
	// ClassDef2 at 94: glyph 8 -> class 1.
	put16(1)
	put16(8)
	put16(1)
	put16(1)
	return b
}

func TestParsePairFormat2Isolated(t *testing.T) {
	lay := parseLayout(buildPairFormat2Layout(), "kern", 2)
	if lay == nil {
		t.Fatal("class-only PairPosFormat2 did not resolve to a layout")
	}
	if len(lay.pairs) != 0 {
		t.Fatalf("format 2 must not populate the format-1 pair map: %v", lay.pairs)
	}
	if len(lay.classPairs) != 1 {
		t.Fatalf("classPairs = %d, want 1", len(lay.classPairs))
	}
	got, ok := lay.classPairs[0].pairAdjust(buildPairFormat2Layout(), 7, 8)
	if !ok || got != -120 {
		t.Errorf("pairAdjust(7,8) = (%d,%v), want (-120,true)", got, ok)
	}
}

// buildPairFormat1Placement puts XPlacement=99 in front of XAdvance=-120
// (ValueFormat 0x0005). readXAdvance must skip the placement field.
func buildPairFormat1Placement() []byte {
	b := []byte{}
	put16 := func(v int) { b = append(b, byte(v>>8), byte(v)) }
	put32 := func(v uint32) {
		b = append(b, byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
	}
	put32(0x00010000)
	put16(10)
	put16(30)
	put16(44)

	put16(1)
	b = append(b, 'l', 'a', 't', 'n')
	put16(8)
	put16(4)
	put16(0)
	put16(0)
	put16(0xFFFF)
	put16(1)
	put16(0)

	put16(1)
	b = append(b, 'k', 'e', 'r', 'n')
	put16(8)
	put16(0)
	put16(1)
	put16(0)

	put16(1)
	put16(4)
	put16(2)
	put16(0)
	put16(1)
	put16(8)

	// PairPosFormat1 at 56: coverage@12, vf1 = XPlacement|XAdvance, vf2 0,
	// pairSetCount 1, pairSet@18.
	put16(1)
	put16(12)
	put16(0x0005)
	put16(0)
	put16(1)
	put16(18)
	// Coverage at 68.
	put16(1)
	put16(1)
	put16(7)
	// PairSet at 74: second=8, XPlacement=99, XAdvance=-120.
	put16(1)
	put16(8)
	put16(99)
	put16(-120 & 0xFFFF)
	return b
}

func TestReadXAdvanceSkipsPlacement(t *testing.T) {
	lay := parseLayout(buildPairFormat1Placement(), "kern", 2)
	if lay == nil {
		t.Fatal("placement+advance pair table did not parse")
	}
	m, ok := lay.pairs[7]
	if !ok {
		t.Fatalf("no pair entry for first glyph 7: %v", lay.pairs)
	}
	if m[8] != -120 {
		t.Errorf("pair (7,8) = %d, want -120 (XAdvance, not XPlacement 99)", m[8])
	}
}

func TestPairSetHugeCountDoesNotPanic(t *testing.T) {
	data := buildExtLayout()
	// The PairSet lives at offset 82 in the extension fixture. Overwrite
	// its count with 0xFFFF so a missing bounds check would slice past
	// the buffer and panic.
	if len(data) < 84 {
		t.Fatalf("extension fixture too short: %d", len(data))
	}
	data[82] = 0xFF
	data[83] = 0xFF
	parseLayout(data, "kern", 2)
}
