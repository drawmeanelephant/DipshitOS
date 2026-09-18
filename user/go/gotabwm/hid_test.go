package main

import (
	"testing"

	"virelai/vi"
)

func TestHidUsagesMatchRunner(t *testing.T) {
	if hidUsageP != 0x13 {
		t.Fatalf("hidUsageP = %#x want 0x13 (USB HID 'p')", hidUsageP)
	}
	if hidUsageTab != 0x2B {
		t.Fatalf("hidUsageTab = %#x want 0x2B (USB HID Tab)", hidUsageTab)
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
