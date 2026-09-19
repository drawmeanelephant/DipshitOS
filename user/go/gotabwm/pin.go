// GOTABWM.ELF — M62d (issue #1402): pin + reorder of already-open tabs.
// Pin is M48 flag parity (tabcodec.FlagPinned): pinned tabs sit at the
// left of the rail across focus changes. Closing a pinned tab is allowed.
package main

import "virelai/vi"

func dumpOrder() {
	vi.ConsoleLine(MarkerOrder + orderLine(&tabs))
}

// applySwapUnpinned reorders indices 0→1. The live two-tab path does this
// while both are still unpinned (the M62d card); Reorder itself matches
// Zig move_tab and will move a pinned tab too.
func applySwapUnpinned() bool {
	if tabs.Count() != 2 {
		return false
	}
	if !tabs.Reorder(0, 1) {
		return false
	}
	vi.ConsoleLine(MarkerReorder + "0->1")
	dumpOrder()
	return true
}

// applyPinStay pins Calc when that title is on the strip so SESSION.TABS
// is Calc-left regardless of which client declared first (the text client —
// the Zig notepad then, NOTE.ELF since M66c — often beats GOCALC.ELF to
// WM_RPC). Without a Calc tab (boot 03 GOEDIT+NOTE.ELF) it pins the
// right-hand tab. Then it focuses the other
// tab so pin-left is dumped twice, and restores focus to the pinned tab
// so the M62e snapshot's active index is 0.
func applyPinStay() bool {
	if tabs.Count() != 2 {
		return false
	}
	pinID := tabs.At(1).ID
	for i := 0; i < 2; i++ {
		t := tabs.At(i)
		if t.Title == "Calc" {
			pinID = t.ID
			break
		}
	}
	if pinID == 0 {
		return false
	}
	pi := tabs.index(pinID)
	if pi < 0 || tabs.At(pi).Pinned {
		return false
	}
	if !tabs.Pin(pinID) {
		return false
	}
	vi.ConsoleLine(MarkerPin + "id=" + vi.Itoa64(int64(pinID)) + " on")
	dumpOrder()
	fid, _ := tabs.Focused()
	other := tabs.At(0).ID
	if other == fid {
		other = tabs.At(1).ID
	}
	if other == 0 || other == fid {
		return false
	}
	if vi.WmctlTaskbarClick(other) != 0 {
		return false
	}
	if !tabs.FocusTab(other) {
		return false
	}
	vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(other)))
	vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(other)))
	hostedApp = other
	dumpOrder()
	left := tabs.At(0)
	if left.ID == 0 {
		return false
	}
	if !tabs.FocusTab(left.ID) {
		return false
	}
	if vi.WmctlTaskbarClick(left.ID) == 0 {
		hostedApp = left.ID
	}
	return true
}

// closePinnedFirst focuses a pinned tab if one exists, then closes it.
// Pin is not a lock.
func closePinnedFirst() bool {
	n := tabs.Count()
	for i := 0; i < n; i++ {
		t := tabs.At(i)
		if !t.Pinned {
			continue
		}
		_ = tabs.FocusTab(t.ID)
		hostedApp = t.ID
		if vi.WmctlTaskbarClick(t.ID) == 0 {
			vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(t.ID)))
		}
		return closeHosted()
	}
	return closeHosted()
}
