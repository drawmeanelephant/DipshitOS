// Package tabcodec is an independent Go implementation of the VirelaiOS
// `.tabs` v2 tab-session format (M53 Card 2, issue #1246).
//
// The format is frozen in user/src/tabwm.zig — the TWM `.tabs` v2 block
// (`serialize_tabs_v2` / `parse_tabs_v2`) and its tests TWM/ST1..TWM/ST4.
// This package is a second, independent implementation of those bytes, so a
// second language can own TABWM session state without touching the kernel,
// TABWM, or the Zig side.
//
// Layout
//
//	header (6 bytes): version(2) | active+1 (0 = none) | count | seq_lo | seq_hi | prefs
//	record (69 bytes): title(32, NUL-padded) | flags(1) | group(12, NUL-padded) | bin(24, NUL-padded)
//
// flag bits: 0x01 pinned, 0x02 frozen, 0x04 dock-at-launch.
// At most 16 tabs, so a maximal file is 6 + 16*69 = 1110 bytes.
//
// Decode is TOTAL: a short header, a wrong version byte, a count above
// MaxTabs, a truncated record body, or an out-of-range active index is
// rejected with an error rather than trusted. Bytes trailing the last record
// are ignored, exactly like the Zig parser (it only enforces the minimum
// length). A fixed-width field is read up to its first NUL and at most its
// width.
//
// This package is pure data: no syscalls, no build tags, no dependencies.
// It is tested on the host with the stock Go toolchain.
package tabcodec

import (
	"errors"
	"fmt"
)

// Format constants, mirroring user/src/tabwm.zig.
const (
	// Version is the `.tabs` v2 version byte.
	Version uint8 = 2

	// MaxTabs is the maximum number of records (tabwm.zig `max_tabs`).
	MaxTabs = 16

	// HeaderBytes is the fixed header width.
	HeaderBytes = 6

	// Per-field record widths (persist_title_max / persist_group_max / persist_bin_max).
	TitleMax = 32
	GroupMax = 12
	BinMax   = 24

	// RecordBytes is one record's width: title + flags + group + bin.
	RecordBytes = TitleMax + 1 + GroupMax + BinMax // 69

	// MaxBytes is the largest possible file: a header plus a full tab list.
	MaxBytes = HeaderBytes + MaxTabs*RecordBytes // 1110

	// Record flag bits (tab_flag_pinned / tab_flag_frozen / tab_flag_dock).
	FlagPinned uint8 = 0x01
	FlagFrozen uint8 = 0x02
	FlagDock   uint8 = 0x04
)

// Decode rejection errors. Every one wraps ErrCorrupt, so "this is not a
// `.tabs` v2 buffer" is one case and the specifics are details.
var (
	ErrCorrupt          = errors.New("tabcodec: malformed .tabs v2 buffer")
	ErrShortHeader      = fmt.Errorf("%w: shorter than %d header bytes", ErrCorrupt, HeaderBytes)
	ErrBadVersion       = fmt.Errorf("%w: version byte is not %d", ErrCorrupt, Version)
	ErrCountTooLarge    = fmt.Errorf("%w: tab count exceeds MaxTabs (%d)", ErrCorrupt, MaxTabs)
	ErrShortBody        = fmt.Errorf("%w: buffer shorter than the declared record count", ErrCorrupt)
	ErrActiveOutOfRange = fmt.Errorf("%w: active index is not inside the tab list", ErrCorrupt)
)

// ErrTooManyTabs is returned by Encode for a state it cannot represent.
var ErrTooManyTabs = errors.New("tabcodec: too many tabs to encode")

// Tab is one persisted tab record.
type Tab struct {
	Title string // up to TitleMax bytes (longer is truncated)
	Flags uint8  // FlagPinned | FlagFrozen | FlagDock
	Group string // up to GroupMax bytes (longer is truncated)
	Bin   string // up to BinMax bytes (longer is truncated)
}

// State is a decoded `.tabs` v2 session. A nil Active means "no active tab"
// (the header's 0 in byte 1); Prefs is the reserved header byte the Zig
// writer always emits as 0.
type State struct {
	Active *int
	Seq    uint16
	Prefs  uint8
	Tabs   []Tab
}

// Count is the number of tabs in the state.
func (s State) Count() int { return len(s.Tabs) }

// ActiveIndex reports the active tab index and whether one is set.
func (s State) ActiveIndex() (int, bool) {
	if s.Active == nil {
		return 0, false
	}
	return *s.Active, true
}

// putFixed copies s into dst and zero-fills the remainder, mirroring the
// Zig writer's `@memcpy` + `@memset` pair. It returns len(dst).
func putFixed(dst []byte, s string) int {
	n := copy(dst, s) // copy truncates at len(dst), like @min(len, width)
	for i := n; i < len(dst); i++ {
		dst[i] = 0
	}
	return len(dst)
}

// readFixed reads a NUL-terminated fixed-width field: up to the first NUL and
// at most len(src) bytes.
func readFixed(src []byte) string {
	n := 0
	for n < len(src) && src[n] != 0 {
		n++
	}
	return string(src[:n])
}

// Encode serializes s exactly as tabwm.zig's serialize_tabs_v2 does: a 6-byte
// header followed by one 69-byte record per tab, each field truncated to its
// width and zero-filled. Truncation of an over-wide field is silent, exactly
// like the Zig writer; only a state the format cannot represent is an error.
func Encode(s State) ([]byte, error) {
	n := len(s.Tabs)
	if n > MaxTabs {
		return nil, fmt.Errorf("%w: %d tabs (max %d)", ErrTooManyTabs, n, MaxTabs)
	}
	buf := make([]byte, HeaderBytes+n*RecordBytes)
	buf[0] = Version
	if s.Active != nil {
		a := *s.Active
		if a < 0 || a >= n {
			return nil, fmt.Errorf("%w: active %d with %d tabs", ErrActiveOutOfRange, a, n)
		}
		buf[1] = byte(a + 1)
	}
	buf[2] = byte(n)
	buf[3] = byte(s.Seq & 0xff)
	buf[4] = byte((s.Seq >> 8) & 0xff)
	buf[5] = s.Prefs
	off := HeaderBytes
	for _, t := range s.Tabs {
		off += putFixed(buf[off:off+TitleMax], t.Title)
		buf[off] = t.Flags
		off++
		off += putFixed(buf[off:off+GroupMax], t.Group)
		off += putFixed(buf[off:off+BinMax], t.Bin)
	}
	return buf, nil
}

// Decode parses a `.tabs` v2 buffer. It is total: every malformed input is
// rejected with an error (wrapping ErrCorrupt) and it never panics.
func Decode(b []byte) (State, error) {
	if len(b) < HeaderBytes {
		return State{}, ErrShortHeader
	}
	if b[0] != Version {
		return State{}, fmt.Errorf("%w: got %d", ErrBadVersion, b[0])
	}
	count := int(b[2])
	if count > MaxTabs {
		return State{}, fmt.Errorf("%w: %d", ErrCountTooLarge, count)
	}
	if len(b) < HeaderBytes+count*RecordBytes {
		return State{}, fmt.Errorf("%w: %d bytes for %d records", ErrShortBody, len(b), count)
	}
	var active *int
	if b[1] != 0 {
		a := int(b[1]) - 1
		if a >= count {
			return State{}, fmt.Errorf("%w: active %d with %d tabs", ErrActiveOutOfRange, a, count)
		}
		active = &a
	}
	st := State{
		Active: active,
		Seq:    uint16(b[3]) | uint16(b[4])<<8,
		Prefs:  b[5],
		Tabs:   make([]Tab, count),
	}
	off := HeaderBytes
	for i := 0; i < count; i++ {
		st.Tabs[i].Title = readFixed(b[off : off+TitleMax])
		off += TitleMax
		st.Tabs[i].Flags = b[off]
		off++
		st.Tabs[i].Group = readFixed(b[off : off+GroupMax])
		off += GroupMax
		st.Tabs[i].Bin = readFixed(b[off : off+BinMax])
		off += BinMax
	}
	return st, nil
}
