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

func TestHandleWmKeyIgnoresCtrlWAndCtrlTab(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(3)
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: 0x1A}) // w
	if tabs.At(0).Pinned || tabs.At(1).Pinned {
		t.Fatal("Ctrl+W must not pin")
	}
	id, _ := tabs.Focused()
	if id != 3 {
		t.Fatalf("Ctrl+Tab must not cycle yet, focus=%d", id)
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: uint32(hidUsageTab)})
	id, _ = tabs.Focused()
	if id != 3 {
		t.Fatalf("Ctrl+Tab (M63r) must not cycle, focus=%d", id)
	}
	// Ordinary characters are the app's KEY_DOWN path (M63e). The seat
	// still sees kind 21, but must not treat them as chords.
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x1B}) // HID 'x'
	if tabs.At(0).Pinned || tabs.At(1).Pinned {
		t.Fatal("printable x must not pin")
	}
	id, _ = tabs.Focused()
	if id != 3 {
		t.Fatalf("printable x must not cycle, focus=%d", id)
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
