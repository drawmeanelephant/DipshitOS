// GOTABWM.ELF — M63b–e (issues #1420–#1423): chords, rail click/drag, type-in.
//
// Frozen table on #1418 (no new ADR, no new kernel cmd, no ctrl-tab):
//
//	ctrl-shift-p  -> Pin() the focused tab
//	alt-tab       -> FocusTab + WmctlTaskbarClick (cmd 12), wrapping
//	rail click    -> top strip, equal-width cells, same TASKBAR+FocusTab
//	rail drag     -> press/release over different cells → existing Reorder()
//	ordinary keys -> ignored here (ADR 0009: KEY_DOWN still reaches the app)
//
// Markers print only after the mutation/syscall that made them true.
// Ctrl+W is not bound (it collides with the editor). Ctrl+Tab waits on M63r.
// Close-x, sash, and hover-preview are later cards. Client-area is ignored.
package main

import "virelai/vi"

const (
	MarkerAltTab    = "gotabwm: alt-tab id="
	MarkerRailClick = "gotabwm: rail-click id="

	// USB HID keyboard usages (the kernel's WM_KEY arg0).
	hidUsageP   uint8 = 0x13
	hidUsageTab uint8 = 0x2B
	hidBtnLeft  uint8 = 0x01
)

// hidChordHold is how many composite ticks the two-tab choreography waits
// after first seeing n>=2, so a rail click (3×2.5 s), a press/release drag
// (pointerDragHold), `--input-string` into GOEDIT, and `--input-chords`
// land before auto reorder/pin. The type-in and drag boots are separate.
const hidChordHold = 20

// pointerDragHold is one `--pointer-virtio 'x,y,d;x,y,u'` (4 messages × 2.5 s).
const pointerDragHold = 12

// prevPtrButtons is the last kind-19 flags low byte; rail click is a left
// down edge and drag-reorder commits on the matching up edge, matching
// Zig TABWM begin_tab_drag / end_tab_drag.
var (
	prevPtrButtons uint8
	railDragFrom   = -1 // source cell, or -1 when no drag is armed
)

func handleWmKey(e vi.Event) {
	if handleLauncherKey(e) {
		return
	}
	usage := uint8(e.Arg0)
	ctrl := e.Flags&vi.ModCtrl != 0
	shift := e.Flags&vi.ModShift != 0
	alt := e.Flags&vi.ModAlt != 0
	if alt && !ctrl && usage == hidUsageTab {
		_ = applyAltTab(shift)
		return
	}
	if ctrl && shift && !alt && usage == hidUsageP {
		_ = applyHidPin()
	}
}

// altTabNext is Zig TABWM's alt_tab_next: the tab after `focus`, wrapping.
// Fewer than two tabs is a no-op. shift inverts. focus out of range starts at 0.
func altTabNext(count, focus int, shift bool) (int, bool) {
	if count < 2 {
		return 0, false
	}
	cur := focus
	if cur < 0 || cur >= count {
		cur = 0
	}
	if shift {
		if cur == 0 {
			return count - 1, true
		}
		return cur - 1, true
	}
	return (cur + 1) % count, true
}

func applyHidPin() bool {
	id, ok := tabs.Focused()
	if !ok {
		return false
	}
	if !tabs.Pin(id) {
		return false
	}
	vi.ConsoleLine(MarkerPin + "id=" + vi.Itoa64(int64(id)) + " on")
	dumpOrder()
	return true
}

func applyAltTab(shift bool) bool {
	i, ok := altTabNext(tabs.Count(), tabs.focus, shift)
	if !ok {
		return false
	}
	id := tabs.At(i).ID
	if !focusHosted(id) {
		return false
	}
	vi.ConsoleLine(MarkerAltTab + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(id)))
	dumpOrder()
	return true
}

func focusHosted(id uint32) bool {
	if id == 0 {
		return false
	}
	if vi.WmctlTaskbarClick(id) != 0 {
		return false
	}
	if !tabs.FocusTab(id) {
		return false
	}
	hostedApp = id
	return true
}

func handleWmPointer(e vi.Event) {
	px := e.Arg0 & 0xffff
	py := e.Arg0 >> 16
	btn := uint8(e.Flags & 0xff)
	down := pointerDownEdge(btn, prevPtrButtons)
	up := pointerUpEdge(btn, prevPtrButtons)
	prevPtrButtons = btn
	if launch.open {
		if down {
			i, ok := launchRowAt(px, py)
			if !ok {
				dismissLauncher()
				return
			}
			launch.sel = i
			execSelected()
		}
		return
	}
	if down {
		beginRailDrag(px, py)
		_ = applyRailClick(px, py)
		return
	}
	if up {
		_ = endRailDrag(px, py)
	}
}

func pointerDownEdge(btn, prev uint8) bool {
	return btn&hidBtnLeft != 0 && prev&hidBtnLeft == 0
}

func pointerUpEdge(btn, prev uint8) bool {
	return btn&hidBtnLeft == 0 && prev&hidBtnLeft != 0
}

// railCellAt is the top-strip hit-test (M63c). Equal-width cells matching
// paintRail (`cellW = width/n`, min 48). py must be in the rail; the rail
// wins over any pane whose rect includes y=0. Close-x is not a target.
func railCellAt(px, py uint32, width, n, stripH int) (int, bool) {
	if n <= 0 || width <= 0 || stripH <= 0 || py >= uint32(stripH) {
		return 0, false
	}
	cellW := width / n
	if cellW < 48 {
		cellW = 48
	}
	i := int(px) / cellW
	if i < 0 {
		return 0, false
	}
	if i >= n {
		i = n - 1
	}
	return i, true
}

func applyRailClick(px, py uint32) bool {
	n := tabs.Count()
	i, ok := railCellAt(px, py, vi.ScanoutWidth, n, RailHeight)
	if !ok {
		return false
	}
	id := tabs.At(i).ID
	if id == 0 {
		return false
	}
	if fid, focused := tabs.Focused(); focused && fid == id {
		return false
	}
	if !focusHosted(id) {
		return false
	}
	vi.ConsoleLine(MarkerRailClick + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(id)))
	dumpOrder()
	return true
}

func beginRailDrag(px, py uint32) {
	railDragFrom = -1
	i, ok := railCellAt(px, py, vi.ScanoutWidth, tabs.Count(), RailHeight)
	if ok {
		railDragFrom = i
	}
}

func endRailDrag(px, py uint32) bool {
	from := railDragFrom
	railDragFrom = -1
	if from < 0 {
		return false
	}
	to, ok := railCellAt(px, py, vi.ScanoutWidth, tabs.Count(), RailHeight)
	if !ok {
		return false
	}
	return applyRailReorder(from, to)
}

// applyRailReorder is Zig TABWM reorder_tab: Reorder() then the existing
// `gotabwm: reorder from->to` marker. Same-cell release is a click no-op.
// Does not write SESSION.TABS (M62e stays the once-only pin-stay snapshot).
func applyRailReorder(from, to int) bool {
	if !tabs.Reorder(from, to) {
		return false
	}
	vi.ConsoleLine(MarkerReorder + vi.Itoa64(int64(from)) + "->" + vi.Itoa64(int64(to)))
	dumpOrder()
	return true
}
