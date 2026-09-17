// GOTABWM.ELF — M62b (issue #1400): an in-process tab strip.
//
// OpenTab / CloseTab / FocusTab are a pure state machine: no syscalls, no
// WM_RPC. The seat (interop.go / seat.go) hooks each successful mutation
// with the kernel primitive that made it true, then prints a marker.
//
// Close of the focused tab moves focus to the neighbour that shifts into
// its slot (Zig TABWM remove_tab). Close of the last tab leaves the strip
// empty; the seat stays registered. Max 16 tabs (ADR 0033 / `.tabs` v2).
package main

import "unsafe"

// MaxTabs is the `.tabs` v2 / ADR 0033 cap.
const MaxTabs = 16

// RailHeight is the tab strip's scanout band, matching the kernel's
// tab_bar_height so the compose-N overlay covers the same chrome row Zig
// TABWM paints into a window.
const RailHeight = 22

// Tab is one strip entry. ID is the kernel window id the client declared.
type Tab struct {
	ID    uint32
	Title string
}

// TabStrip is the in-process tab list. The zero value is empty.
type TabStrip struct {
	tabs  [MaxTabs]Tab
	count int
	focus int // index into tabs[0:count]; ignored when count == 0
}

// The tab-strip marker lines the class-B gate greps. Exported so tabs_test.go
// pins the exact shapes.
const (
	MarkerTabOpen   = "gotabwm: tab open id="
	MarkerTabFocus  = "gotabwm: tab focus id="
	MarkerTabClose  = "gotabwm: tab close id="
	MarkerRail      = "gotabwm: rail "
	MarkerTabsEmpty = "gotabwm: tabs empty"
)

const (
	railIdleRGB  uint32 = 0x2E3448
	railFocusRGB uint32 = 0x3A7BD5
	railGapRGB   uint32 = 0x1A1E2E
)

// Count is how many tabs are currently open.
func (s *TabStrip) Count() int { return s.count }

// At returns the tab at i, or a zero Tab when i is out of range.
func (s *TabStrip) At(i int) Tab {
	if i < 0 || i >= s.count {
		return Tab{}
	}
	return s.tabs[i]
}

// Focused returns the focused tab's window id.
func (s *TabStrip) Focused() (uint32, bool) {
	if s.count == 0 || s.focus < 0 || s.focus >= s.count {
		return 0, false
	}
	return s.tabs[s.focus].ID, true
}

// OpenTab adds id to the strip. A duplicate id updates the title and is
// not a new tab (returns false). id 0 is refused. The first tab becomes
// focused; a later OpenTab does not steal focus (FocusTab does that).
func (s *TabStrip) OpenTab(id uint32, title string) bool {
	if id == 0 {
		return false
	}
	if i := s.index(id); i >= 0 {
		s.tabs[i].Title = title
		return false
	}
	if s.count >= MaxTabs {
		return false
	}
	s.tabs[s.count] = Tab{ID: id, Title: title}
	if s.count == 0 {
		s.focus = 0
	}
	s.count++
	return true
}

// CloseTab removes id. If it was focused, focus moves to the neighbour
// that occupies its slot after the shift (or the new last tab). Closing
// the last tab leaves the strip empty with no focus. Returns whether id
// was present.
func (s *TabStrip) CloseTab(id uint32) bool {
	i := s.index(id)
	if i < 0 {
		return false
	}
	for j := i; j+1 < s.count; j++ {
		s.tabs[j] = s.tabs[j+1]
	}
	s.tabs[s.count-1] = Tab{}
	s.count--
	if s.count == 0 {
		s.focus = 0
		return true
	}
	if s.focus > i {
		s.focus--
	} else if s.focus >= s.count {
		s.focus = s.count - 1
	}
	return true
}

// FocusTab makes id the focused tab. Returns false when id is not open.
func (s *TabStrip) FocusTab(id uint32) bool {
	i := s.index(id)
	if i < 0 {
		return false
	}
	s.focus = i
	return true
}

// NextID is the window id cycle would move to (wrap). One tab returns
// that tab; none returns false.
func (s *TabStrip) NextID() (uint32, bool) {
	if s.count == 0 {
		return 0, false
	}
	i := 0
	if s.focus >= 0 && s.focus < s.count {
		i = (s.focus + 1) % s.count
	}
	return s.tabs[i].ID, true
}

func (s *TabStrip) index(id uint32) int {
	for i := 0; i < s.count; i++ {
		if s.tabs[i].ID == id {
			return i
		}
	}
	return -1
}

// paintRail fills the top stripH rows of a width x height scanout with
// one cell per tab. The focused cell uses railFocusRGB; the rest use
// railIdleRGB. Returns how many pixels in the strip were written. No
// syscalls — the seat paints, then presents, then prints the rail marker.
func paintRail(scan []byte, width, height, stripH int, ts *TabStrip) int {
	n := ts.Count()
	if n == 0 || width <= 0 || height <= 0 || stripH <= 0 || len(scan) < 4 {
		return 0
	}
	if stripH > height {
		stripH = height
	}
	pixN := len(scan) / 4
	if pixN < width {
		return 0
	}
	maxH := pixN / width
	if maxH < stripH {
		stripH = maxH
	}
	if stripH <= 0 {
		return 0
	}
	pix := unsafe.Slice((*uint32)(unsafe.Pointer(&scan[0])), pixN)
	// Trough behind the cells (matches the blank desktop so a gap is a gap).
	written := fillRect(pix, width, maxH, 0, 0, width, stripH, railGapRGB)
	cellW := width / n
	if cellW < 48 {
		cellW = 48
	}
	focus, _ := ts.Focused()
	for i := 0; i < n; i++ {
		x := i * cellW
		w := cellW
		if x >= width {
			break
		}
		if x+w > width {
			w = width - x
		}
		if w <= 1 {
			continue
		}
		rgb := railIdleRGB
		if ts.At(i).ID == focus {
			rgb = railFocusRGB
		}
		// 1px trough on the left, like kernel paint_tab_strip.
		written += fillRect(pix, width, maxH, x+1, 0, w-1, stripH, rgb)
	}
	return written
}

func fillRect(pix []uint32, width, height, x, y, w, h int, rgb uint32) int {
	if w <= 0 || h <= 0 || width <= 0 {
		return 0
	}
	if x < 0 {
		w += x
		x = 0
	}
	if y < 0 {
		h += y
		y = 0
	}
	n := 0
	for row := y; row < y+h && row < height; row++ {
		off := row * width
		for col := x; col < x+w && col < width; col++ {
			idx := off + col
			if idx < 0 || idx >= len(pix) {
				continue
			}
			pix[idx] = rgb
			n++
		}
	}
	return n
}
