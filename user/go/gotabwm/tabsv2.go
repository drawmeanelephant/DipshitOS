// Guest-safe `.tabs` v2 codec (M62e / ADR 0033 D3). Layout matches
// tools/go/tabcodec (header v2, active+1, count, seq, 69-byte records),
// but it must not import that package: tabcodec uses fmt.Errorf, fmt
// pulls os, and os is not a GOOS=virelai guest import.
//
// Byte identity vs tabcodec.Encode is claimed only for Prefs=0 and an
// in-range focus (host tests pin Seq=1, Prefs=0). This writer always
// emits buf[5]=0; an out-of-range focus becomes "no active" rather than
// an error (tabcodec.Encode refuses a bad Active).
package main

const (
	tabsV2Version     uint8 = 2
	tabsV2HeaderBytes       = 6
	tabsV2TitleMax          = 32
	tabsV2GroupMax          = 12
	tabsV2BinMax            = 24
	tabsV2RecordBytes       = tabsV2TitleMax + 1 + tabsV2GroupMax + tabsV2BinMax // 69
	tabsV2MaxBytes          = tabsV2HeaderBytes + MaxTabs*tabsV2RecordBytes      // 1110
)

func putFixed(dst []byte, s string) int {
	n := copy(dst, s)
	for i := n; i < len(dst); i++ {
		dst[i] = 0
	}
	return len(dst)
}

func readFixed(src []byte) string {
	n := 0
	for n < len(src) && src[n] != 0 {
		n++
	}
	return string(src[:n])
}

// encodeTabsV2 serializes the strip as `.tabs` v2 with Prefs=0. See the
// file comment for where this is not a full tabcodec.Encode equivalent.
func (s *TabStrip) encodeTabsV2(seq uint16) ([]byte, bool) {
	n := s.count
	if n > MaxTabs {
		return nil, false
	}
	buf := make([]byte, tabsV2HeaderBytes+n*tabsV2RecordBytes)
	buf[0] = tabsV2Version
	if n > 0 && s.focus >= 0 && s.focus < n {
		buf[1] = byte(s.focus + 1)
	}
	buf[2] = byte(n)
	buf[3] = byte(seq & 0xff)
	buf[4] = byte((seq >> 8) & 0xff)
	off := tabsV2HeaderBytes
	for i := 0; i < n; i++ {
		t0 := s.tabs[i]
		off += putFixed(buf[off:off+tabsV2TitleMax], t0.Title)
		buf[off] = tabFlags(t0)
		off++
		off += putFixed(buf[off:off+tabsV2GroupMax], "")
		off += putFixed(buf[off:off+tabsV2BinMax], t0.Bin)
	}
	return buf, true
}

type tabsV2Record struct {
	Title  string
	Bin    string
	Pinned bool
	// M71e (#1564): the frozen badge round-trips too. The codec already
	// defines bit 0x02; GOTABWM dropped it on both encode and decode.
	Frozen bool
}

func decodeTabsV2(b []byte) (seq uint16, recs []tabsV2Record, active int, hasActive bool, ok bool) {
	if len(b) < tabsV2HeaderBytes {
		return
	}
	if b[0] != tabsV2Version {
		return
	}
	count := int(b[2])
	if count > MaxTabs {
		return
	}
	if len(b) < tabsV2HeaderBytes+count*tabsV2RecordBytes {
		return
	}
	if b[1] != 0 {
		a := int(b[1]) - 1
		if a >= count {
			return
		}
		active = a
		hasActive = true
	}
	seq = uint16(b[3]) | uint16(b[4])<<8
	recs = make([]tabsV2Record, count)
	off := tabsV2HeaderBytes
	for i := 0; i < count; i++ {
		recs[i].Title = readFixed(b[off : off+tabsV2TitleMax])
		off += tabsV2TitleMax
		recs[i].Pinned = b[off]&FlagPinned != 0
		recs[i].Frozen = b[off]&FlagFrozen != 0
		off++
		off += tabsV2GroupMax // group unused
		recs[i].Bin = readFixed(b[off : off+tabsV2BinMax])
		off += tabsV2BinMax
	}
	ok = true
	return
}

// applyTabsV2 replaces the strip with decoded records. Order and pin bits
// are taken as written (no Pin() partition). Placeholder ids start at
// sessionIDBase so they cannot be 0 (OpenTab refuses 0).
func (s *TabStrip) applyTabsV2(raw []byte) (uint16, bool) {
	seq, recs, active, hasActive, ok := decodeTabsV2(raw)
	if !ok {
		return 0, false
	}
	*s = TabStrip{}
	for i := 0; i < len(recs); i++ {
		id := sessionIDBase + uint32(i)
		if !s.OpenTab(id, recs[i].Title) {
			*s = TabStrip{}
			return 0, false
		}
		// OpenTab fills Bin via guessBin(title). The record wins, including
		// empty: a generic `.tabs` file must round-trip, not grow a guessed bin.
		s.tabs[i].Bin = recs[i].Bin
		s.tabs[i].Pinned = recs[i].Pinned
		s.tabs[i].Frozen = recs[i].Frozen
	}
	if hasActive && active >= 0 && active < s.count {
		s.focus = active
	}
	return seq, true
}
