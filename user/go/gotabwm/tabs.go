// GOTABWM.ELF — M62b–g (issues #1400–#1405): an in-process tab strip
// with a two-pane constrained split, pin, reorder, `.tabs` v2 session,
// a headless LAYOUT.txt dump, and a shipping Go ELF as a tab (GOEDIT).
//
// OpenTab / CloseTab / FocusTab / SplitH / SplitV / Unsplit / Pin / Unpin /
// Reorder are a pure state machine: no syscalls, no WM_RPC. The seat hooks
// each successful mutation with the kernel primitive that made it true,
// then prints a marker.
//
// Close of the focused tab moves focus to the neighbour that shifts into
// its slot (Zig TABWM remove_tab). Close of the last tab leaves the strip
// empty; the seat stays registered. Max 16 tabs (ADR 0033 / `.tabs` v2).
// Split is exactly two panes; pane minimum is 160×120 (ADR 0033) on the
// 1280×720 scanout. Integer math; the kernel clamp stays authoritative.
package main

import (
	"unsafe"

	"virelai/theme"
)

// MaxTabs is the `.tabs` v2 / ADR 0033 cap.
const MaxTabs = 16

// RailHeight is the tab strip's scanout band, matching the kernel's
// tab_bar_height so the compose-N overlay covers the same chrome row Zig
// TABWM paints into a window.
const RailHeight = 22

// Tab is one strip entry. ID is the kernel window id the client declared.
type Tab struct {
	ID     uint32
	Title  string
	Bin    string // `.tabs` v2 bin field (guessBin from the declared title)
	Pinned bool   // FlagPinned (0x01); pinned tabs sit at the left of the rail
}

// TabStrip is the in-process tab list. The zero value is empty (unsplit).
type TabStrip struct {
	tabs  [MaxTabs]Tab
	count int
	focus int // index into tabs[0:count]; ignored when count == 0
	split SplitKind
	// M71d (#1563, M48 BT1): the bounded reopen LIFO. closed is a fixed
	// array and closedCount is monotonic, exactly like Zig tabwm.closed_count,
	// so the ring is BSS/fixed with no heap catalog of every close (D2).
	// closedLive is how many entries are still live (<= MaxTabs): Zig's
	// recently_closed_at only guards k < max_tabs, so once closed_count exceeds
	// the ring, reopen walks back over slots a later close already overwrote
	// and hands out evicted entries. The live counter makes the bound real.
	// Only Bin and Title are kept — never a window id — so reopen re-execs the
	// executable rather than cloning a process (D1).
	closed      [MaxTabs]ClosedTab
	closedCount int
	closedLive  int
}

// ClosedTab is one reopen-LIFO entry: the executable and title recorded when
// the tab closed. Zig tabwm.ClosedTab minus the window id.
type ClosedTab struct {
	Bin   string
	Title string
}

// The tab-strip marker lines the class-B gate greps. Exported so tabs_test.go
// pins the exact shapes.
const (
	MarkerTabOpen       = "gotabwm: tab open id="
	MarkerTabFocus      = "gotabwm: tab focus id="
	MarkerTabClose      = "gotabwm: tab close id="
	MarkerRail          = "gotabwm: rail "
	MarkerTabsEmpty     = "gotabwm: tabs empty"
	MarkerSplit         = "gotabwm: split "
	MarkerUnsplit       = "gotabwm: unsplit"
	MarkerLayout        = "gotabwm: layout "
	MarkerLayoutFile    = "gotabwm: layout file="
	MarkerPane          = "gotabwm: pane "
	MarkerPin           = "gotabwm: pin "
	MarkerReorder       = "gotabwm: reorder "
	MarkerOrder         = "gotabwm: order "
	MarkerSessionWrite  = "gotabwm: session write n="
	MarkerSessionLoad   = "gotabwm: session load n="
	MarkerSessionTitles = "gotabwm: session titles="
	MarkerSessionBad    = "gotabwm: session bad"
)

// FlagPinned is `.tabs` v2 bit 0 — the same value as tabcodec.FlagPinned
// / tabwm.tab_flag_pinned. Frozen/dock stay unused (M62d non-goal).
const FlagPinned uint8 = 0x01

func pinFlag(t Tab) uint8 {
	if t.Pinned {
		return FlagPinned
	}
	return 0
}

// guessBin fills the `.tabs` v2 bin field from a declared title. WM_RPC
// carries the window title, not the executable name.
func guessBin(title string) string {
	switch title {
	case "Calc":
		return "GOCALC.ELF"
	case "Notepad":
		// M66c (#1445, completed by #1485): the text editor this shell
		// restores is the Go app, NOTE.ELF. The Zig binary is deleted, so
		// this is now the only app a restored "Notepad" tab can name.
		return "NOTE.ELF"
	case "Edit":
		return "GOEDIT.ELF"
	case "Term":
		return "GOTERM.ELF"
	default:
		return title
	}
}

func railIdleRGB() uint32  { return theme.Current.BtnIdle }
func railFocusRGB() uint32 { return theme.Current.Accent }
func railGapRGB() uint32   { return theme.Current.Bg }

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
		if s.tabs[i].Bin == "" {
			s.tabs[i].Bin = guessBin(title)
		}
		return false
	}
	if s.count >= MaxTabs {
		return false
	}
	s.tabs[s.count] = Tab{ID: id, Title: title, Bin: guessBin(title)}
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
	// M71d (#1563, M48 BT1): record the closed tab in the bounded reopen
	// LIFO before it is shifted out of the strip. Zig push_closed_tab runs at
	// the same close decision point, so every close path (HID, RPC detach,
	// choreography) feeds the ring through this one seam.
	s.recordClosed(s.tabs[i])
	for j := i; j+1 < s.count; j++ {
		s.tabs[j] = s.tabs[j+1]
	}
	s.tabs[s.count-1] = Tab{}
	s.count--
	if s.count == 0 {
		s.focus = 0
		s.split = SplitNone
		return true
	}
	if s.focus > i {
		s.focus--
	} else if s.focus >= s.count {
		s.focus = s.count - 1
	}
	if s.count < 2 {
		s.split = SplitNone
	}
	return true
}

// recordClosed pushes t onto the bounded reopen LIFO. Bounded: at most MaxTabs
// entries are live and the oldest is overwritten (D2).
func (s *TabStrip) recordClosed(t Tab) {
	s.closed[s.closedCount%MaxTabs] = ClosedTab{Bin: t.Bin, Title: t.Title}
	s.closedCount++
	if s.closedLive < MaxTabs {
		s.closedLive++
	}
}

// RecentlyClosed returns the k-th most recently closed tab (0 = most recent),
// or false when the ring holds fewer than k+1 live entries.
func (s *TabStrip) RecentlyClosed(k int) (ClosedTab, bool) {
	if k < 0 || k >= s.closedLive {
		return ClosedTab{}, false
	}
	return s.closed[(s.closedCount-1-k)%MaxTabs], true
}

// ReopenLastClosed pops the most recently closed tab and returns it for the
// caller to re-exec. Entries with no recorded bin are popped and skipped —
// Zig's rule: a tab the WM never spawned cannot be rebuilt, so the next press
// tries an older one. False when the ring holds nothing reopenable.
func (s *TabStrip) ReopenLastClosed() (ClosedTab, bool) {
	for s.closedLive > 0 {
		c := s.closed[(s.closedCount-1)%MaxTabs]
		s.closedCount--
		s.closedLive--
		if c.Bin == "" {
			continue
		}
		return c, true
	}
	return ClosedTab{}, false
}

// DuplicateFocused returns the focused tab's executable so the caller can
// re-exec it as a new tab. Honest no-op (false) when nothing is focused or
// the focused tab has no recorded bin. Zig duplicate_active_tab.
func (s *TabStrip) DuplicateFocused() (string, bool) {
	id, ok := s.Focused()
	if !ok {
		return "", false
	}
	i := s.index(id)
	if i < 0 || s.tabs[i].Bin == "" {
		return "", false
	}
	return s.tabs[i].Bin, true
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

// Pin sets FlagPinned on id and stable-partitions pinned tabs to the
// front (M48/BT3). Focus follows the same tab by id. False when id is
// missing or already pinned.
func (s *TabStrip) Pin(id uint32) bool {
	i := s.index(id)
	if i < 0 || s.tabs[i].Pinned {
		return false
	}
	s.tabs[i].Pinned = true
	s.normalizePinned()
	return true
}

// Unpin clears FlagPinned on id and re-partitions. Closing a pinned tab
// is allowed separately — pin is not a lock.
func (s *TabStrip) Unpin(id uint32) bool {
	i := s.index(id)
	if i < 0 || !s.tabs[i].Pinned {
		return false
	}
	s.tabs[i].Pinned = false
	s.normalizePinned()
	return true
}

// Reorder moves the tab at from to to. Same as Zig TABWM move_tab: any
// pair of indices, including pinned tabs. Pin-left is restored by Pin /
// Unpin (normalize_pinned), not by every move — a reorder can briefly
// leave a pinned tab off the front, matching M48. Focus follows by id.
func (s *TabStrip) Reorder(from, to int) bool {
	if from < 0 || to < 0 || from >= s.count || to >= s.count || from == to {
		return false
	}
	moved := s.tabs[from]
	fid, has := s.Focused()
	if from < to {
		for i := from; i < to; i++ {
			s.tabs[i] = s.tabs[i+1]
		}
	} else {
		for i := from; i > to; i-- {
			s.tabs[i] = s.tabs[i-1]
		}
	}
	s.tabs[to] = moved
	if has {
		s.focus = s.index(fid)
	}
	return true
}

func (s *TabStrip) normalizePinned() {
	if s.count == 0 {
		return
	}
	fid, has := s.Focused()
	var pinned, rest [MaxTabs]Tab
	np, nr := 0, 0
	for i := 0; i < s.count; i++ {
		if s.tabs[i].Pinned {
			pinned[np] = s.tabs[i]
			np++
		} else {
			rest[nr] = s.tabs[i]
			nr++
		}
	}
	n := 0
	for i := 0; i < np; i++ {
		s.tabs[n] = pinned[i]
		n++
	}
	for i := 0; i < nr; i++ {
		s.tabs[n] = rest[i]
		n++
	}
	if has {
		s.focus = s.index(fid)
	}
}

// orderLine is the rail report: ids and pin bits in strip order, plus
// who is focused. Not a LAYOUT.txt line (ADR 0033 has no pin= field).
func orderLine(s *TabStrip) string {
	ids := "ids="
	pins := "pin="
	for i := 0; i < s.count; i++ {
		if i > 0 {
			ids += ","
			pins += ","
		}
		ids += dec(s.tabs[i].ID)
		if s.tabs[i].Pinned {
			pins += "1"
		} else {
			pins += "0"
		}
	}
	f := uint32(0)
	if id, ok := s.Focused(); ok {
		f = id
	}
	return ids + " " + pins + " focus=" + dec(f)
}

// SplitKind is the two-pane layout (ADR 0033 LAYOUT.txt `split=`).
type SplitKind uint8

const (
	SplitNone  SplitKind = iota // split=none — full viewport
	SplitHoriz                  // split=h — top / bottom (horizontal divider)
	SplitVert                   // split=v — left / right (vertical divider)
)

func (k SplitKind) String() string {
	switch k {
	case SplitHoriz:
		return "h"
	case SplitVert:
		return "v"
	default:
		return "none"
	}
}

// PaneMinW / PaneMinH are the ADR 0033 pane floor (CSS-pixels on 1280×720).
const (
	PaneMinW uint32 = 160
	PaneMinH uint32 = 120
)

// Rect is a window rectangle in scanout pixels.
type Rect struct{ X, Y, W, H uint32 }

// FullRect is the unsplit viewport (origin + scanout size).
func FullRect(scanW, scanH uint32) Rect {
	return Rect{X: 0, Y: 0, W: scanW, H: scanH}
}

// Split reports the current two-pane kind.
func (s *TabStrip) Split() SplitKind { return s.split }

// SplitH splits two already-open tabs top/bottom. Refused unless count==2.
func (s *TabStrip) SplitH() bool { return s.setSplit(SplitHoriz) }

// SplitV splits two already-open tabs left/right. Refused unless count==2.
func (s *TabStrip) SplitV() bool { return s.setSplit(SplitVert) }

func (s *TabStrip) setSplit(k SplitKind) bool {
	if s.count != 2 || k == SplitNone {
		return false
	}
	s.split = k
	return true
}

// Unsplit restores the unsplit (full-viewport) kind. False when already none.
func (s *TabStrip) Unsplit() bool {
	if s.split == SplitNone {
		return false
	}
	s.split = SplitNone
	return true
}

// SplitRects is the integer two-pane layout. Remainder goes to the right
// (SplitV) or bottom (SplitH) pane so odd widths/heights do not drop a
// pixel. Refused when either pane would fall under PaneMinW×PaneMinH.
func SplitRects(kind SplitKind, scanW, scanH uint32) (Rect, Rect, bool) {
	if kind == SplitNone {
		full := FullRect(scanW, scanH)
		return full, full, true
	}
	if kind == SplitVert {
		left := scanW / 2
		right := scanW - left
		if left < PaneMinW || right < PaneMinW || scanH < PaneMinH {
			return Rect{}, Rect{}, false
		}
		return Rect{0, 0, left, scanH}, Rect{left, 0, right, scanH}, true
	}
	if kind == SplitHoriz {
		top := scanH / 2
		bot := scanH - top
		if scanW < PaneMinW || top < PaneMinH || bot < PaneMinH {
			return Rect{}, Rect{}, false
		}
		return Rect{0, 0, scanW, top}, Rect{0, top, scanW, bot}, true
	}
	return Rect{}, Rect{}, false
}

// PaneRects returns the two pane rects for the current split, or false
// when the strip is not two tabs.
func (s *TabStrip) PaneRects(scanW, scanH uint32) (Rect, Rect, bool) {
	if s.count != 2 {
		return Rect{}, Rect{}, false
	}
	return SplitRects(s.split, scanW, scanH)
}

// rectsWithin reports whether a and b differ by at most tol on every edge.
func rectsWithin(a, b Rect, tol uint32) bool {
	return uabs(a.X, b.X) <= tol && uabs(a.Y, b.Y) <= tol &&
		uabs(a.W, b.W) <= tol && uabs(a.H, b.H) <= tol
}

func uabs(a, b uint32) uint32 {
	if a > b {
		return a - b
	}
	return b - a
}

// layoutLine is one ADR 0033 LAYOUT.txt surface line (no trailing LF).
// bin is a single token: a space or newline would break bin=\S+ and the
// one-line-per-tab dump. Gate titles are app-controlled (GOCALC.ELF etc.).
func layoutLine(id uint32, bin string, r Rect, focus bool, kind SplitKind) string {
	if bin == "" {
		bin = "-"
	}
	f := "0"
	if focus {
		f = "1"
	}
	return "tab=" + dec(id) +
		" bin=" + bin +
		" x=" + dec(r.X) +
		" y=" + dec(r.Y) +
		" w=" + dec(r.W) +
		" h=" + dec(r.H) +
		" focus=" + f +
		" split=" + kind.String()
}

// paneLine is the applied-rect counterpart the gate pairs with layoutLine.
func paneLine(id uint32, r Rect) string {
	return "id=" + dec(id) +
		" x=" + dec(r.X) +
		" y=" + dec(r.Y) +
		" w=" + dec(r.W) +
		" h=" + dec(r.H)
}

func dec(v uint32) string {
	if v == 0 {
		return "0"
	}
	var b [10]byte
	i := len(b)
	for v > 0 {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
	}
	return string(b[i:])
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
	written := fillRect(pix, width, maxH, 0, 0, width, stripH, railGapRGB())
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
		rgb := railIdleRGB()
		if ts.At(i).ID == focus {
			rgb = railFocusRGB()
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
			// The scanout is B,G,R,X and the X byte must be opaque: the
			// kernel's own stores write 0xff there (virtio_gpu.gpu_fb), and
			// a 6-hex token leaves it 0x00 — which the host display honours
			// as alpha, hiding every seat pixel. M71c (#1562), measured:
			// with X=0 the seated frame showed only the kernel's opaque
			// splash, the seat's fill and chrome invisible.
			pix[idx] = rgb | 0xff000000
			n++
		}
	}
	return n
}
