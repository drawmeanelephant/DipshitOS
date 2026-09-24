// GOTABWM.ELF — M63b–e (issues #1420–#1423): chords, rail click/drag, type-in.
//
// Frozen table on #1418 (no new ADR, no new kernel cmd, no ctrl-tab), plus
// M71d (#1563) BT1 reopen/duplicate:
//
//	ctrl-shift-p  -> Pin() the focused tab
//	ctrl-shift-t  -> reopen the most recently closed tab (re-exec its bin)
//	ctrl-shift-d  -> duplicate the focused tab (re-exec its bin)
//	ctrl-shift-f  -> toggle the focused tab's frozen BADGE (M71e / #1564)
//	alt-tab       -> FocusTab + WmctlTaskbarClick (cmd 12), wrapping
//	rail click    -> top strip, equal-width cells, same TASKBAR+FocusTab
//	rail drag     -> press/release over different cells → existing Reorder()
//	ordinary keys -> ignored here (ADR 0009: KEY_DOWN still reaches the app)
//
// Markers print only after the mutation/syscall that made them true.
// Ctrl+W is not bound (it collides with the editor). Ctrl+Tab waits on M63r.
// Close-x, sash, and hover-preview are later cards. Client-area is ignored.
//
// M71d pick: Ctrl+Shift+T / Ctrl+Shift+D are Zig TABWM's own BT1 bindings
// (user/src/tabwm.zig:151/:427). They are free on GOTABWM — the only
// ctrl-shift chord bound here is ctrl-shift-p, and Ctrl+T (Zig's "+ New
// tab") is not bound at all on this seat, whose launcher is Ctrl+Space.
//
// M71e pick: Ctrl+Shift+F is Zig TABWM's own freeze binding (user/src/
// tabwm.zig:1448). It is a BADGE there too — Zig checks `frozen` in no close
// path — so the port keeps that shape rather than inventing a lock.
package main

import "virelai/vi"

const (
	MarkerAltTab    = "gotabwm: alt-tab id="
	MarkerRailClick = "gotabwm: rail-click id="
	// M71d (#1563): the BT1 chord outcomes. <bin> is the re-exec'd executable,
	// matching Zig's `tabwm: reopen <bin>` / `tabwm: duplicate <bin>`.
	MarkerReopen           = "gotabwm: reopen "
	MarkerDuplicate        = "gotabwm: duplicate "
	MarkerReopenMissing    = "gotabwm: reopen missing "
	MarkerDuplicateMissing = "gotabwm: duplicate missing "

	// USB HID keyboard usages (the kernel's WM_KEY arg0).
	hidUsageD   uint8 = 0x07 // 'd'
	hidUsageF   uint8 = 0x09 // 'f'; M71e (#1564) freeze-badge toggle
	hidUsageP   uint8 = 0x13
	hidUsageT   uint8 = 0x17 // 't'
	hidUsageTab uint8 = 0x2B
	hidBtnLeft  uint8 = 0x01
)

// execApp is the exec seam for the BT1 chords. It is vi.Exec in the guest;
// the indirection exists because vi.Exec calls the raw syscall4 gateway and so
// bypasses vi's host-test syscall hook, which would leave the chord -> re-exec
// path unobservable off the guest.
var execApp = vi.Exec

// hidChordHold is how many composite ticks the two-tab choreography waits
// after first seeing n>=2, so a rail click (3×2.5 s), a press/release drag
// (pointerDragHold), `--input-string` into GOEDIT, and `--input-chords`
// land before auto reorder/pin. The type-in and drag boots are separate.
// M73z (#1638): raised 20 -> 32 so go-dogfood boot 04's acceptance
// chain (6-step pointer phase incl. the refocus rail click, chords,
// script2 tail, expect) finishes before the choreography's first
// close (n==2 + hold + 7 steps ~ tick 68).
const hidChordHold = 32

// pointerDragHold is one `--pointer-virtio 'x,y,d;x,y,u'` (4 messages × 2.5 s).
const pointerDragHold = 12

// prevPtrButtons is the last kind-19 flags low byte; rail click is a left
// down edge and drag-reorder commits on the matching up edge, matching
// Zig TABWM begin_tab_drag / end_tab_drag.
var (
	prevPtrButtons uint8
	railDragFrom   = -1 // source cell, or -1 when no drag is armed
	// contentDown tracks a pointer-down that went to the kernel as content
	// (#1688): the matching release is content too, wherever it lands.
	// Chrome downs (start surface, rail) never set it.
	contentDown bool
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
	if ctrl && shift && !alt {
		switch usage {
		case hidUsageP:
			_ = applyHidPin()
		case hidUsageT:
			_ = applyReopen()
		case hidUsageD:
			_ = applyDuplicate()
		case hidUsageF:
			_ = applyFreezeToggle()
		}
		return
	}
	// M71e (#1564): Enter on an empty strip is the start surface's keyboard
	// affordance — it summons the same launcher the panel points at.
	if !ctrl && !shift && !alt && usage == hidUsageEnter && tabs.Count() == 0 {
		openLauncher()
	}
}

// applyFreezeToggle is Zig TABWM freeze_toggle: flip the frozen badge on the
// focused tab and report which way it went. M71e (#1564) is deliberate about
// the shape — this is a BADGE, not a lock: Zig checks `frozen` nowhere in its
// close path, and neither does GOTABWM, so a frozen tab still closes.
func applyFreezeToggle() bool {
	id, ok := tabs.Focused()
	if !ok {
		return false
	}
	if tabs.Freeze(id) {
		vi.ConsoleLine(MarkerFreeze + vi.Itoa64(int64(id)) + " on")
		dumpOrder()
		return true
	}
	if tabs.Thaw(id) {
		vi.ConsoleLine(MarkerThaw + vi.Itoa64(int64(id)))
		dumpOrder()
		return true
	}
	return false
}

// applyReopen is Zig TABWM reopen_last_closed(): pop the bounded LIFO, skip
// entries with no recorded bin, and re-exec the executable as a new hosted
// tab. A tab the seat never spawned has no bin and is an honest no-op.
func applyReopen() bool {
	c, ok := tabs.ReopenLastClosed()
	if !ok {
		return false
	}
	if _, err := execApp(c.Bin); err != nil {
		vi.ConsoleLine(MarkerReopenMissing + c.Bin)
		return false
	}
	vi.ConsoleLine(MarkerReopen + c.Bin)
	return true
}

// applyDuplicate is Zig TABWM duplicate_active_tab(): re-exec the focused
// tab's executable so it joins as a new tab. Honest no-op when nothing is
// focused or the focused tab has no recorded bin.
func applyDuplicate() bool {
	bin, ok := tabs.DuplicateFocused()
	if !ok {
		return false
	}
	if _, err := execApp(bin); err != nil {
		vi.ConsoleLine(MarkerDuplicateMissing + bin)
		return false
	}
	vi.ConsoleLine(MarkerDuplicate + bin)
	return true
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
		// M71e (#1564): on an empty strip the start surface is the click
		// target. Checked before the rail so it cannot be shadowed by a
		// rail cell that happens to span the point (the rail has no cells
		// when the strip is empty, so this is belt-and-braces).
		if tabs.Count() == 0 && startSurfaceHit(px, py) {
			openLauncher()
			return
		}
		beginRailDrag(px, py)
		_, onRail := railCellAt(px, py, vi.ScanoutWidth, tabs.Count(), RailHeight)
		_ = applyRailClick(px, py)
		if !onRail {
			// #1688: not chrome — content for the kernel's local path
			// (terminal text selection, mouse-tracking reports). The
			// kernel derives press/release edges from this serialized
			// stream itself; consumed chrome is never forwarded.
			contentDown = true
			vi.WmctlContentPtr(px, py, btn)
		}
		return
	}
	if up {
		_ = endRailDrag(px, py)
		if contentDown {
			vi.WmctlContentPtr(px, py, btn)
			contentDown = false
		}
		return
	}
	// #1688: motion is content too, unless it rides the rail chrome —
	// the only pointer consumer here besides the launcher above.
	if _, onRail := railCellAt(px, py, vi.ScanoutWidth, tabs.Count(), RailHeight); !onRail {
		vi.WmctlContentPtr(px, py, btn)
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
