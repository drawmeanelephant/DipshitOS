package main

import (
	"testing"

	"virelai/vi"
)

func TestHidUsagesMatchRunner(t *testing.T) {
	if hidUsageP != 0x13 {
		t.Fatalf("hidUsageP = %#x want 0x13 (USB HID 'p')", hidUsageP)
	}
	if hidUsageT != 0x17 {
		t.Fatalf("hidUsageT = %#x want 0x17 (USB HID 't')", hidUsageT)
	}
	if hidUsageD != 0x07 {
		t.Fatalf("hidUsageD = %#x want 0x07 (USB HID 'd')", hidUsageD)
	}
	if hidUsageF != 0x09 {
		t.Fatalf("hidUsageF = %#x want 0x09 (USB HID 'f')", hidUsageF)
	}
	if hidUsageTab != 0x2B {
		t.Fatalf("hidUsageTab = %#x want 0x2B (USB HID Tab)", hidUsageTab)
	}
	if hidUsageSpace != 0x2C {
		t.Fatalf("hidUsageSpace = %#x want 0x2C (USB HID Space)", hidUsageSpace)
	}
	if hidUsageEnter != 0x28 || hidUsageEscape != 0x29 || hidUsageBksp != 0x2A {
		t.Fatal("enter/esc/bksp HID usages drifted")
	}
}

// M71e (#1564): ctrl-shift-f flips the frozen badge on the focused tab, and
// only on the focused tab. It is a badge — the tab stays closable, which the
// second half pins so nobody quietly turns this into a lock.
func TestHandleWmKeyFreezeToggle(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") || !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab")
	}
	if !tabs.FocusTab(4) {
		t.Fatal("FocusTab")
	}
	chord := func() {
		handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(hidUsageF)})
	}
	chord()
	if !tabs.At(1).Frozen || tabs.At(0).Frozen {
		t.Fatalf("first ctrl-shift-f froze the wrong tab: %+v %+v", tabs.At(0), tabs.At(1))
	}
	if n := tabs.FrozenCount(); n != 1 {
		t.Fatalf("FrozenCount = %d want 1", n)
	}
	chord()
	if tabs.At(1).Frozen {
		t.Fatal("second ctrl-shift-f must thaw the focused tab")
	}
	if n := tabs.FrozenCount(); n != 0 {
		t.Fatalf("FrozenCount = %d want 0 after thaw", n)
	}
	// The badge is not a lock: a frozen tab still closes (Zig has no frozen
	// check in its close path, and neither may this seat).
	chord()
	if !tabs.At(1).Frozen {
		t.Fatal("third chord should freeze again")
	}
	if !tabs.CloseTab(4) {
		t.Fatal("a frozen tab must still close — freeze is a badge, not a lock")
	}
	if tabs.Count() != 1 {
		t.Fatalf("count = %d want 1", tabs.Count())
	}
}

// execRecorder swaps the chord exec seam for one that records every bin and
// acks it, so the chord -> re-exec path is observable off the guest.
func execRecorder() (*[]string, func()) {
	execs := &[]string{}
	prev := execApp
	execApp = func(name string, args ...string) (int64, error) {
		*execs = append(*execs, name)
		return 42, nil
	}
	return execs, func() { execApp = prev }
}

func TestHandleWmKeyReopenChordReexecsLastClosed(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") || !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab")
	}
	if !tabs.CloseTab(3) {
		t.Fatal("CloseTab Calc")
	}
	execs, restore := execRecorder()
	defer restore()

	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(hidUsageT)})
	if len(*execs) != 1 || (*execs)[0] != "GOCALC.ELF" {
		t.Fatalf("ctrl-shift-t execs = %v want [GOCALC.ELF]", *execs)
	}
	// The LIFO is drained by the reopen: a second press is an honest no-op,
	// not a second exec.
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(hidUsageT)})
	if len(*execs) != 1 {
		t.Fatalf("second ctrl-shift-t must not exec again: %v", *execs)
	}
	// Ctrl+Shift+T must not have re-opened the tab on the strip by itself:
	// the reopened app declares and joins as a fresh tab (D1, a re-exec).
	if _, ok := tabs.Focused(); !ok {
		t.Fatal("Edit should still be focused")
	}
}

func TestHandleWmKeyDuplicateChordReexecsFocused(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	// Focus a tab with a recorded bin, then a tab with none: duplicate must
	// follow the focus, and an honest no-op is a no-op with no exec at all.
	if !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab Edit")
	}
	execs, restore := execRecorder()
	defer restore()

	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(hidUsageD)})
	if len(*execs) != 1 || (*execs)[0] != "GOEDIT.ELF" {
		t.Fatalf("ctrl-shift-d execs = %v want [GOEDIT.ELF]", *execs)
	}
	// Duplicate does not add a tab itself (the new window declares over RPC).
	if tabs.Count() != 1 {
		t.Fatalf("count = %d want 1", tabs.Count())
	}
}

func TestHandleWmKeyIgnoresUnboundCtrlShiftKeys(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab")
	}
	execs, restore := execRecorder()
	defer restore()
	// ctrl-shift-x is not a GOTABWM chord and must not reach the ring or the
	// duplicate path.
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: 0x1B})
	if len(*execs) != 0 {
		t.Fatalf("ctrl-shift-x exec'd: %v", *execs)
	}
}

func TestCtrlIndexMapsHIDNumberRow(t *testing.T) {
	for usage, want := range map[uint8]int{0x1e: 1, 0x1f: 2, 0x26: 9} {
		got, ok := ctrlIndex(usage)
		if !ok || got != want {
			t.Fatalf("ctrlIndex(%#x) = %d ok=%v want %d", usage, got, ok, want)
		}
	}
	for _, usage := range []uint8{0x04, 0x27, 0x2b} { // a, 0, Tab
		if got, ok := ctrlIndex(usage); ok {
			t.Fatalf("ctrlIndex(%#x) = %d ok=true want false", usage, got)
		}
	}
}

func TestAltTabNextPolicy(t *testing.T) {
	if _, ok := altTabNext(0, 0, false); ok {
		t.Fatal("zero tabs must no-op")
	}
	if _, ok := altTabNext(1, 0, false); ok {
		t.Fatal("one tab must no-op")
	}
	if i, ok := altTabNext(3, 0, false); !ok || i != 1 {
		t.Fatalf("forward 0 -> %d ok=%v want 1", i, ok)
	}
	if i, ok := altTabNext(3, 1, false); !ok || i != 2 {
		t.Fatalf("forward 1 -> %d ok=%v want 2", i, ok)
	}
	if i, ok := altTabNext(3, 2, false); !ok || i != 0 {
		t.Fatalf("forward wrap 2 -> %d ok=%v want 0", i, ok)
	}
	if i, ok := altTabNext(3, 0, true); !ok || i != 2 {
		t.Fatalf("shift wrap 0 -> %d ok=%v want 2", i, ok)
	}
	if i, ok := altTabNext(3, 2, true); !ok || i != 1 {
		t.Fatalf("shift 2 -> %d ok=%v want 1", i, ok)
	}
	if i, ok := altTabNext(3, -1, false); !ok || i != 1 {
		t.Fatalf("out-of-range focus starts at 0: got %d ok=%v", i, ok)
	}
}

func TestHandleWmKeyPinFocused(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") || !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab")
	}
	if !tabs.FocusTab(4) {
		t.Fatal("FocusTab")
	}
	handleWmKey(vi.Event{
		Kind:  vi.EvWmKey,
		Flags: vi.ModCtrl | vi.ModShift,
		Arg0:  uint32(hidUsageP),
	})
	if !tabs.At(0).Pinned || tabs.At(0).ID != 4 {
		t.Fatalf("pin did not jump left: %+v pinned=%v", tabs.At(0), tabs.At(0).Pinned)
	}
	id, ok := tabs.Focused()
	if !ok || id != 4 {
		t.Fatalf("focus after pin = %d ok=%v want 4", id, ok)
	}
	// Already pinned: Pin() is false, no second mutation.
	handleWmKey(vi.Event{
		Kind:  vi.EvWmKey,
		Flags: vi.ModCtrl | vi.ModShift,
		Arg0:  uint32(hidUsageP),
	})
	if tabs.At(1).Pinned {
		t.Fatal("second ctrl-shift-p must not pin the other tab")
	}
}

// focusIndexRecorder replaces the guest-only focus seam so dispatch tests can
// observe the selected rail index without slot 65 or marker output.
func focusIndexRecorder() (*[]int, func()) {
	indices := &[]int{}
	prev := focusByIndex
	focusByIndex = func(i int) bool {
		*indices = append(*indices, i)
		return true
	}
	return indices, func() { focusByIndex = prev }
}

func TestHandleWmKeyCtrlTabAndDigitDispatch(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	for i, id := range []uint32{3, 4, 5} {
		if !tabs.OpenTab(id, string(rune('A'+i))) {
			t.Fatal("OpenTab")
		}
	}
	if !tabs.FocusTab(5) {
		t.Fatal("FocusTab")
	}
	indices, restore := focusIndexRecorder()
	defer restore()
	key := func(flags uint16, usage uint8) {
		handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: flags, Arg0: uint32(usage)})
	}

	key(vi.ModCtrl, hidUsageTab)             // wrap 2 -> 0
	key(vi.ModCtrl|vi.ModShift, hidUsageTab) // reverse 2 -> 1
	key(vi.ModCtrl, 0x1f)                    // Ctrl+2 -> index 1
	key(vi.ModCtrl, 0x23)                    // Ctrl+4 is past a 3-tab strip
	key(vi.ModCtrl, 0x1a)                    // Ctrl+W remains app-owned
	key(vi.ModCtrl|vi.ModAlt, hidUsageTab)   // Ctrl+Alt+Tab remains unbound
	want := []int{0, 1, 1}
	if len(*indices) != len(want) {
		t.Fatalf("focus indexes = %v want %v", *indices, want)
	}
	for i := range want {
		if (*indices)[i] != want[i] {
			t.Fatalf("focus indexes = %v want %v", *indices, want)
		}
	}
}

func TestHandleWmKeyLauncherPrecedesCtrlChords(t *testing.T) {
	savedTabs := tabs
	savedLaunch := launch
	defer func() {
		tabs = savedTabs
		launch = savedLaunch
	}()
	tabs = TabStrip{}
	tabs.OpenTab(3, "A")
	tabs.OpenTab(4, "B")
	launch = launcherState{open: true}
	indices, restore := focusIndexRecorder()
	defer restore()

	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: uint32(hidUsageTab)})
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: 0x1f})
	if len(*indices) != 0 {
		t.Fatalf("launcher-open ctrl chords focused rail indexes %v", *indices)
	}
	if launch.filter != "2" {
		t.Fatalf("launcher filter = %q want %q", launch.filter, "2")
	}
}

func TestHandleWmKeyLeavesPlainKeysToApp(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	tabs.OpenTab(3, "A")
	tabs.OpenTab(4, "B")
	indices, restore := focusIndexRecorder()
	defer restore()

	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x1B}) // HID 'x'
	if len(*indices) != 0 {
		t.Fatalf("plain x focused rail indexes %v", *indices)
	}
}

func TestHandleWmKeyAltTabNeedsKernel(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	defer func() {
		tabs = saved
		hostedApp = savedHosted
	}()
	tabs = TabStrip{}
	hostedApp = 0
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(3)
	// Host WmctlTaskbarClick is ENOSYS: the strip must not change, so a
	// live miss is a guest-only failure rather than a silent host pass.
	if applyAltTab(false) {
		t.Fatal("host applyAltTab must fail closed (no slot 65)")
	}
	id, _ := tabs.Focused()
	if id != 3 {
		t.Fatalf("failed alt-tab mutated focus to %d", id)
	}
}

func TestPointerDownEdge(t *testing.T) {
	if pointerDownEdge(0, 0) || pointerDownEdge(0, hidBtnLeft) {
		t.Fatal("hover/up must not be a down edge")
	}
	if !pointerDownEdge(hidBtnLeft, 0) {
		t.Fatal("press must be a down edge")
	}
	if pointerDownEdge(hidBtnLeft, hidBtnLeft) {
		t.Fatal("held must not re-fire")
	}
}

func TestPointerUpEdge(t *testing.T) {
	if pointerUpEdge(0, 0) || pointerUpEdge(hidBtnLeft, 0) {
		t.Fatal("hover/press must not be an up edge")
	}
	if !pointerUpEdge(0, hidBtnLeft) {
		t.Fatal("release must be an up edge")
	}
	if pointerUpEdge(hidBtnLeft, hidBtnLeft) {
		t.Fatal("held must not look like an up")
	}
}

func TestRailCellAtTwoTabs(t *testing.T) {
	const w, n, h = 1280, 2, 22
	if i, ok := railCellAt(320, 10, w, n, h); !ok || i != 0 {
		t.Fatalf("tab 0 center (320,10) = %d ok=%v want 0", i, ok)
	}
	if i, ok := railCellAt(960, 10, w, n, h); !ok || i != 1 {
		t.Fatalf("tab 1 center (960,10) = %d ok=%v want 1", i, ok)
	}
	if i, ok := railCellAt(639, 0, w, n, h); !ok || i != 0 {
		t.Fatalf("left cell edge = %d ok=%v want 0", i, ok)
	}
	if i, ok := railCellAt(640, 21, w, n, h); !ok || i != 1 {
		t.Fatalf("right cell start = %d ok=%v want 1", i, ok)
	}
	if _, ok := railCellAt(320, 22, w, n, h); ok {
		t.Fatal("py == RailHeight is the pane, not the rail")
	}
	if _, ok := railCellAt(640, 360, w, n, h); ok {
		t.Fatal("client-area click must miss the rail")
	}
	if _, ok := railCellAt(320, 10, w, 0, h); ok {
		t.Fatal("empty strip has no cell")
	}
	// Remainder pixels past n*cellW still hit the last cell.
	if i, ok := railCellAt(1279, 10, 1280, 3, h); !ok || i != 2 {
		t.Fatalf("right remainder = %d ok=%v want 2", i, ok)
	}
}

func TestApplyRailClickMissesAndHostFailsClosed(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	savedBtn := prevPtrButtons
	defer func() {
		tabs = saved
		hostedApp = savedHosted
		prevPtrButtons = savedBtn
	}()
	tabs = TabStrip{}
	hostedApp = 0
	prevPtrButtons = 0
	if applyRailClick(320, 10) {
		t.Fatal("empty strip must miss")
	}
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(4)
	if applyRailClick(640, 360) {
		t.Fatal("client-area must not focus")
	}
	id, _ := tabs.Focused()
	if id != 4 {
		t.Fatalf("client-area mutated focus to %d", id)
	}
	if applyRailClick(960, 10) {
		t.Fatal("already-focused cell must not re-fire")
	}
	if applyRailClick(320, 10) {
		t.Fatal("host rail click must fail closed (no slot 65)")
	}
	id, _ = tabs.Focused()
	if id != 4 {
		t.Fatalf("failed rail click mutated focus to %d", id)
	}
}

func TestHandleWmPointerDownEdgeOnly(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	savedBtn := prevPtrButtons
	savedDrag := railDragFrom
	defer func() {
		tabs = saved
		hostedApp = savedHosted
		prevPtrButtons = savedBtn
		railDragFrom = savedDrag
	}()
	tabs = TabStrip{}
	hostedApp = 0
	prevPtrButtons = 0
	railDragFrom = -1
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(4)
	arg := uint32(320) | uint32(10)<<16
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: arg, Flags: 0})
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: arg, Flags: uint16(hidBtnLeft)})
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: arg, Flags: 0})
	id, _ := tabs.Focused()
	if id != 4 {
		t.Fatalf("host pointer sequence mutated focus to %d", id)
	}
	if prevPtrButtons != 0 {
		t.Fatalf("up must clear prevPtrButtons, got %#x", prevPtrButtons)
	}
	if railDragFrom != -1 {
		t.Fatalf("same-cell release must clear railDragFrom, got %d", railDragFrom)
	}
	if tabs.At(0).ID != 3 || tabs.At(1).ID != 4 {
		t.Fatal("same-cell click must not reorder")
	}
}

func TestRailDragReordersTwoTabs(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	savedBtn := prevPtrButtons
	savedDrag := railDragFrom
	defer func() {
		tabs = saved
		hostedApp = savedHosted
		prevPtrButtons = savedBtn
		railDragFrom = savedDrag
	}()
	tabs = TabStrip{}
	hostedApp = 0
	prevPtrButtons = 0
	railDragFrom = -1
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(4)
	down := uint32(320) | uint32(10)<<16
	up := uint32(960) | uint32(10)<<16
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: down, Flags: uint16(hidBtnLeft)})
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: up, Flags: uint16(hidBtnLeft)})
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: up, Flags: 0})
	if tabs.At(0).ID != 4 || tabs.At(1).ID != 3 {
		t.Fatalf("drag 0→1 left ids=%d,%d want 4,3", tabs.At(0).ID, tabs.At(1).ID)
	}
	id, _ := tabs.Focused()
	if id != 4 {
		t.Fatalf("focus follows by id: got %d want 4", id)
	}
	if railDragFrom != -1 {
		t.Fatalf("release must clear railDragFrom, got %d", railDragFrom)
	}
}

func TestRailDragMissesClientAreaAndSameCell(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	savedDrag := railDragFrom
	defer func() {
		tabs = saved
		hostedApp = savedHosted
		railDragFrom = savedDrag
	}()
	tabs = TabStrip{}
	hostedApp = 0
	railDragFrom = -1
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(4)
	beginRailDrag(640, 360)
	if railDragFrom != -1 {
		t.Fatal("client-area press must not arm a drag")
	}
	if endRailDrag(960, 10) {
		t.Fatal("unarmed release must not reorder")
	}
	beginRailDrag(320, 10)
	if railDragFrom != 0 {
		t.Fatalf("rail press armed %d want 0", railDragFrom)
	}
	if endRailDrag(320, 10) {
		t.Fatal("same-cell release must not reorder")
	}
	if tabs.At(0).ID != 3 || tabs.At(1).ID != 4 {
		t.Fatal("same-cell mutated order")
	}
	beginRailDrag(320, 10)
	if endRailDrag(640, 360) {
		t.Fatal("release off the rail must not reorder")
	}
	if tabs.At(0).ID != 3 {
		t.Fatal("off-rail release mutated order")
	}
}

// M79b (#1705): the close-x hit zone is the cell's rightmost railCloseW px —
// pinned geometry including the min-48px cell (the zone is exactly a third of
// the cell) and the honest non-targets: cell body, rail edge rows, the last
// cell's remainder pixels, an empty strip.
func TestRailCloseZoneAtGeometry(t *testing.T) {
	if MarkerRailHover != "gotabwm: rail-hover id=" {
		t.Fatalf("MarkerRailHover = %q (gate grep target)", MarkerRailHover)
	}
	const w, h = 1280, 22
	// Two tabs: cellW = 640; zones are [624,640) and [1264,1280).
	if i, ok := railCloseZoneAt(632, 10, w, 2, h); !ok || i != 0 {
		t.Fatalf("cell 0 close-x = %d ok=%v want 0", i, ok)
	}
	if _, ok := railCloseZoneAt(623, 10, w, 2, h); ok {
		t.Fatal("the cell body (x=623) must not be a close-x target")
	}
	if _, ok := railCloseZoneAt(320, 10, w, 2, h); ok {
		t.Fatal("the cell centre must not be a close-x target")
	}
	if i, ok := railCloseZoneAt(1272, 10, w, 2, h); !ok || i != 1 {
		t.Fatalf("cell 1 close-x = %d ok=%v want 1", i, ok)
	}
	if _, ok := railCloseZoneAt(1263, 10, w, 2, h); ok {
		t.Fatal("x=1263 is cell 1 body, not its close-x")
	}
	if _, ok := railCloseZoneAt(632, 22, w, 2, h); ok {
		t.Fatal("py == RailHeight is the pane, not the close-x")
	}
	if _, ok := railCloseZoneAt(632, 360, w, 2, h); ok {
		t.Fatal("client area is never a close-x target")
	}
	if _, ok := railCloseZoneAt(632, 10, w, 0, h); ok {
		t.Fatal("empty strip has no close-x")
	}
	// Min-48px cells (n*48 > width clamps cellW to 48): the zone is the
	// rightmost third — [32,48) of cell 0, [80,96) of cell 1.
	if i, ok := railCloseZoneAt(40, 10, w, 30, h); !ok || i != 0 {
		t.Fatalf("min-cell close-x = %d ok=%v want 0", i, ok)
	}
	if _, ok := railCloseZoneAt(31, 10, w, 30, h); ok {
		t.Fatal("x=31 is min-cell body")
	}
	if i, ok := railCloseZoneAt(88, 10, w, 30, h); !ok || i != 1 {
		t.Fatalf("min-cell 1 close-x = %d ok=%v want 1", i, ok)
	}
	// The last cell's remainder pixels past n*cellW resolve to the last
	// cell (railCellAt's rule) but sit outside its paint, so they stay
	// click/drag territory and are never a close-x target.
	if i, ok := railCloseZoneAt(1277, 10, w, 3, h); !ok || i != 2 {
		t.Fatalf("cell 2 close-x = %d ok=%v want 2", i, ok)
	}
	if _, ok := railCloseZoneAt(1278, 10, w, 3, h); ok {
		t.Fatal("the remainder pixel (x=1278) must not be a close-x target")
	}
	if _, ok := railCloseZoneAt(1279, 10, w, 3, h); ok {
		t.Fatal("the remainder pixel (x=1279) must not be a close-x target")
	}
}

// M79b (#1705): hover tracks the rail cell under the pointer and clears off
// the rail. State only — the entry marker is motion-only (updateRailHover).
func TestRailHoverTracksCells(t *testing.T) {
	saved := tabs
	savedHover := railHover
	defer func() {
		tabs = saved
		railHover = savedHover
	}()
	tabs = TabStrip{}
	railHover = -1
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(4)
	motion := func(px uint32) {
		handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: px | uint32(10)<<16, Flags: 0})
	}
	motion(320) // cell 0
	if railHover != 0 {
		t.Fatalf("hover over cell 0 tracked %d", railHover)
	}
	motion(321) // same cell: state holds
	if railHover != 0 {
		t.Fatalf("same-cell motion lost hover: %d", railHover)
	}
	motion(960) // cell 1
	if railHover != 1 {
		t.Fatalf("hover over cell 1 tracked %d", railHover)
	}
	// Below the rail: hover clears.
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: 320 | uint32(360)<<16, Flags: 0})
	if railHover != -1 {
		t.Fatalf("client-area motion must clear hover, got %d", railHover)
	}
}

// M79b (#1705): the close-x click closes the CELL's tab through the WM seam
// and nothing else — no focus change (the close tail never raises), no drag
// armed. A press on the cell body keeps today's click/drag behaviour byte for
// byte. The stubs are interop.go's closeWin / focusRaise seams (vi.Wmctl*
// bypasses the host syscall hook — the raw gateway is hardwired -ENOSYS).
func TestHandleWmPointerCloseXClosesWithoutFocusOrDrag(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	savedBtn := prevPtrButtons
	savedDrag := railDragFrom
	savedHover := railHover
	closed := []uint32{}
	raises := 0
	prevClose, prevRaise := closeWin, focusRaise
	closeWin = func(id uint32) int64 {
		closed = append(closed, id)
		return 0
	}
	focusRaise = func(id uint32) int64 {
		raises++
		return 0
	}
	defer func() {
		tabs = saved
		hostedApp = savedHosted
		prevPtrButtons = savedBtn
		railDragFrom = savedDrag
		railHover = savedHover
		closeWin, focusRaise = prevClose, prevRaise
	}()
	tabs = TabStrip{}
	hostedApp = 0
	prevPtrButtons = 0
	railDragFrom = -1
	railHover = -1
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(4)
	body := uint32(320) | uint32(10)<<16
	zone := uint32(632) | uint32(10)<<16
	// Cell body: the press still arms the drag (today's behaviour) and
	// still tries the click — the close-x is not a target there.
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: body, Flags: uint16(hidBtnLeft)})
	if railDragFrom != 0 {
		t.Fatalf("body press armed drag %d want 0", railDragFrom)
	}
	if len(closed) != 0 {
		t.Fatalf("a body press closed %v", closed)
	}
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: body, Flags: 0})
	if railDragFrom != -1 || tabs.At(0).ID != 3 || tabs.At(1).ID != 4 {
		t.Fatal("same-cell release must not reorder")
	}
	// The close-x: press + release closes cell 0's tab and NOTHING else.
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: zone, Flags: uint16(hidBtnLeft)})
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: zone, Flags: 0})
	if len(closed) != 1 || closed[0] != 3 {
		t.Fatalf("close-x closed %v want [3]", closed)
	}
	if raises != 0 {
		t.Fatalf("close-x must not focus: the close tail raised %d time(s)", raises)
	}
	if tabs.Count() != 1 || tabs.At(0).ID != 4 {
		t.Fatalf("strip after close-x holds %+v, want only id 4", tabs.At(0))
	}
	if id, _ := tabs.Focused(); id != 4 {
		t.Fatalf("focus moved to %d; close-x must not change focus", id)
	}
	if railDragFrom != -1 {
		t.Fatalf("close-x armed a drag: %d", railDragFrom)
	}
}

func TestHidUsageCharLetters(t *testing.T) {
	if c, ok := hidUsageChar(0x06); !ok || c != 'c' {
		t.Fatalf("HID c = %q ok=%v", c, ok)
	}
	if c, ok := hidUsageChar(0x04); !ok || c != 'a' {
		t.Fatalf("HID a = %q ok=%v", c, ok)
	}
	if c, ok := hidUsageChar(0x0f); !ok || c != 'l' {
		t.Fatalf("HID l = %q ok=%v", c, ok)
	}
	if _, ok := hidUsageChar(hidUsageEnter); ok {
		t.Fatal("enter is not a filter char")
	}
}

func TestLauncherCtrlSpaceToggleAndFilter(t *testing.T) {
	saved := launch
	defer func() { launch = saved }()
	launch = launcherState{}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: uint32(hidUsageSpace)})
	if !launch.open {
		t.Fatal("ctrl-space must open the launcher")
	}
	launch.catalog = []AppEntry{
		{Bin: "GOCALC.ELF", Label: "64-bit Calc"},
		{Bin: "NOTE.ELF", Label: "Text Editor"},
	}
	launch.refresh()
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x06}) // c
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x04}) // a
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x0f}) // l
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x06}) // c
	if launch.filter != "calc" {
		t.Fatalf("filter = %q want calc", launch.filter)
	}
	if len(launch.filtered) != 1 || launch.catalog[launch.filtered[0]].Bin != "GOCALC.ELF" {
		t.Fatalf("filtered = %v", launch.filtered)
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: uint32(hidUsageEscape)})
	if launch.open {
		t.Fatal("escape must dismiss")
	}
}

func TestLauncherFilterIgnoresStickyCtrl(t *testing.T) {
	saved := launch
	defer func() { launch = saved }()
	launch = launcherState{
		open:     true,
		catalog:  []AppEntry{{Bin: "GOCALC.ELF", Label: "64-bit Calc"}},
		filtered: []int{0},
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: 0x06}) // c, ctrl still down
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x04})                    // a
	if launch.filter != "ca" {
		t.Fatalf("sticky-ctrl filter = %q want ca", launch.filter)
	}
}

func TestLaunchRowAtHitsFirstRow(t *testing.T) {
	saved := launch
	defer func() { launch = saved }()
	launch = launcherState{
		open:     true,
		catalog:  []AppEntry{{Bin: "GOCALC.ELF", Label: "64-bit Calc"}},
		filtered: []int{0},
	}
	cx := uint32(launchX + 20)
	cy := uint32(launchY + launchHdr + 2)
	i, ok := launchRowAt(cx, cy)
	if !ok || i != 0 {
		t.Fatalf("row at (%d,%d) = %d ok=%v", cx, cy, i, ok)
	}
	if _, ok := launchRowAt(10, 10); ok {
		t.Fatal("outside panel must miss")
	}
}

// M79c (#1706): the split-cycle chord is USB HID 'v' (0x19), like every
// other ctrl-shift chord in the frozen table.
func TestHidUsageVMatchesRunner(t *testing.T) {
	if hidUsageV != 0x19 {
		t.Fatalf("hidUsageV = %#x want 0x19 (USB HID 'v')", hidUsageV)
	}
}

// rectCall is one wmctlSetRect proposal the seat made.
type rectCall struct {
	id, x, y, w, h uint32
}

// rectRecorder swaps the slot-65 rect seam for a recorder (success), so the
// split/sash -> relayout path is observable off the guest. Same shape as
// hid_test.go's execRecorder.
func rectRecorder() (*[]rectCall, func()) {
	calls := &[]rectCall{}
	prev := wmctlSetRect
	wmctlSetRect = func(id, x, y, w, h uint32) int64 {
		*calls = append(*calls, rectCall{id, x, y, w, h})
		return 0
	}
	return calls, func() { wmctlSetRect = prev }
}

// saveSeatState snapshots the globals a pointer/chord test can disturb.
// tabs rides by value (fixed arrays); launch rides whole-struct, the
// existing hid_test.go pattern.
func saveSeatState() func() {
	ts, pl := tabs, launch
	pb, cd, rd, rh, sd := prevPtrButtons, contentDown, railDragFrom, railHover, sashDragging
	return func() {
		tabs, launch = ts, pl
		prevPtrButtons, contentDown, railDragFrom, railHover, sashDragging = pb, cd, rd, rh, sd
	}
}

func ptrEvent(x, y uint32, buttons uint8) vi.Event {
	return vi.Event{Kind: vi.EvWmPointer, Arg0: x | y<<16, Flags: uint16(buttons)}
}

func openTwoTabs(t *testing.T) {
	t.Helper()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") || !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab")
	}
}

// M79c (#1706): ctrl-shift-v cycles none -> V -> H -> none through the same
// apply* paths the choreography uses, so the markers and dumps are shapes
// the gates already pin. Fewer than two tabs is a silent no-op.
func TestSplitCycleChord(t *testing.T) {
	defer saveSeatState()()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") {
		t.Fatal("OpenTab")
	}
	calls, restore := rectRecorder()
	defer restore()
	chord := func() {
		handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(hidUsageV)})
	}
	launch.open = false
	chord()
	if tabs.Split() != SplitNone || len(*calls) != 0 {
		t.Fatalf("one tab: split=%s rects=%d (must be a silent no-op)", tabs.Split(), len(*calls))
	}
	if !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab")
	}
	chord()
	if tabs.Split() != SplitVert {
		t.Fatalf("first chord: split=%s want v", tabs.Split())
	}
	// The right pane moves off-origin, so applyRect's two-step
	// (shrink-at-origin, then move) proposes 3 rects, not 2.
	if len(*calls) != 3 {
		t.Fatalf("split v must propose 3 rects, got %d: %+v", len(*calls), *calls)
	}
	if (*calls)[0] != (rectCall{3, 0, 0, 640, 720}) ||
		(*calls)[1] != (rectCall{4, 0, 0, 640, 720}) ||
		(*calls)[2] != (rectCall{4, 640, 0, 640, 720}) {
		t.Fatalf("split v rects = %+v", *calls)
	}
	chord()
	if tabs.Split() != SplitHoriz {
		t.Fatalf("second chord: split=%s want h", tabs.Split())
	}
	if len(*calls) != 6 {
		t.Fatalf("split h must propose 3 more rects, got %d: %+v", len(*calls), *calls)
	}
	if (*calls)[3] != (rectCall{3, 0, 0, 1280, 360}) ||
		(*calls)[4] != (rectCall{4, 0, 0, 1280, 360}) ||
		(*calls)[5] != (rectCall{4, 0, 360, 1280, 360}) {
		t.Fatalf("split h rects = %+v", *calls)
	}
	chord()
	if tabs.Split() != SplitNone {
		t.Fatalf("third chord: split=%s want none", tabs.Split())
	}
}

// M79c (#1706): the pointer path end to end on the host — a down on the
// divider arms the sash (no rail drag, no focus change, no content), motion
// while armed stays swallowed, and the release commits the clamped divider
// through the rect seam.
func TestSashDragPointerPath(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	launch.open = false
	prevPtrButtons = 0
	calls, restore := rectRecorder()
	defer restore()
	if !applySplit(SplitVert) {
		t.Fatal("applySplit v")
	}
	*calls = (*calls)[:0]
	// Down on the divider (midpoint x=640, y=100: below the rail, clear of
	// the bottom chrome) arms the sash and consumes the press.
	handleWmPointer(ptrEvent(640, 100, hidBtnLeft))
	if !sashDragging {
		t.Fatal("divider down must arm sashDragging")
	}
	if contentDown {
		t.Fatal("sash down must not forward content")
	}
	if railDragFrom != -1 {
		t.Fatal("sash down must not arm a rail drag")
	}
	// Held-button motion is an in-progress resize, not content: swallowed,
	// and the divider does not move before the release edge.
	handleWmPointer(ptrEvent(700, 100, hidBtnLeft))
	if !sashDragging || contentDown {
		t.Fatal("armed motion must stay armed and content-free")
	}
	if tabs.sash != 0 {
		t.Fatal("motion must not move the divider (release-edge commit only)")
	}
	// Release at x=800 commits: the gutter pair goes out and the sash sticks.
	handleWmPointer(ptrEvent(800, 100, 0))
	if sashDragging {
		t.Fatal("release must disarm")
	}
	if tabs.sash != 800 {
		t.Fatalf("sash = %d want 800", tabs.sash)
	}
	// Left pane at the origin: 1 call. Right pane off-origin: the
	// two-step shrink-then-move, 2 calls.
	if len(*calls) != 3 {
		t.Fatalf("sash commit must propose 3 rects, got %d: %+v", len(*calls), *calls)
	}
	if (*calls)[0] != (rectCall{3, 0, 0, 797, 720}) ||
		(*calls)[1] != (rectCall{4, 0, 0, 477, 720}) ||
		(*calls)[2] != (rectCall{4, 803, 0, 477, 720}) {
		t.Fatalf("sash rects = %+v", *calls)
	}
	if contentDown {
		t.Fatal("sash release must not leave a content latch")
	}
}

// M79c (#1706): a release on the armed position is the press-on-the-divider
// release — an honest no-op: no syscalls, no state change.
func TestSashReleaseOnArmedPositionIsNoop(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	launch.open = false
	prevPtrButtons = 0
	calls, restore := rectRecorder()
	defer restore()
	if !applySplit(SplitVert) {
		t.Fatal("applySplit v")
	}
	*calls = (*calls)[:0]
	handleWmPointer(ptrEvent(640, 100, hidBtnLeft))
	if !sashDragging {
		t.Fatal("divider down must arm")
	}
	handleWmPointer(ptrEvent(640, 100, 0))
	if sashDragging || tabs.sash != 0 {
		t.Fatal("same-position release must disarm without storing")
	}
	if len(*calls) != 0 {
		t.Fatalf("no-op release proposed %d rects", len(*calls))
	}
}

// M79c (#1706): a reorder while split re-proposes both pane rects, so the
// panes follow the tabs instead of silently swapping which app is left.
// Unsplit reorders propose nothing.
func TestRailReorderReappliesWhileSplit(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	calls, restore := rectRecorder()
	defer restore()
	if !applySplit(SplitVert) {
		t.Fatal("applySplit v")
	}
	*calls = (*calls)[:0]
	if !applyRailReorder(0, 1) {
		t.Fatal("applyRailReorder")
	}
	if tabs.At(0).ID != 4 || tabs.At(1).ID != 3 {
		t.Fatalf("order = %d,%d want 4,3", tabs.At(0).ID, tabs.At(1).ID)
	}
	// Reordered panes follow the tabs (4 left, 3 right); the right pane's
	// off-origin move is the two-step, so 3 proposals.
	if len(*calls) != 3 {
		t.Fatalf("split reorder must re-propose 3 rects, got %d: %+v", len(*calls), *calls)
	}
	if (*calls)[0] != (rectCall{4, 0, 0, 640, 720}) ||
		(*calls)[1] != (rectCall{3, 0, 0, 640, 720}) ||
		(*calls)[2] != (rectCall{3, 640, 0, 640, 720}) {
		t.Fatalf("reordered pane rects = %+v", *calls)
	}
	if !tabs.Unsplit() {
		t.Fatal("Unsplit")
	}
	*calls = (*calls)[:0]
	if !applyRailReorder(0, 1) {
		t.Fatal("applyRailReorder unsplit")
	}
	if len(*calls) != 0 {
		t.Fatalf("unsplit reorder proposed %d rects", len(*calls))
	}
}
