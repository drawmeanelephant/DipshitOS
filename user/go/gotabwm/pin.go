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

// applyPinStay pins the right-hand tab so it jumps to the left of the
// rail, then focuses the other tab. The pin stays at index 0.
func applyPinStay() bool {
	if tabs.Count() != 2 {
		return false
	}
	right := tabs.At(1)
	if right.ID == 0 || right.Pinned {
		return false
	}
	if !tabs.Pin(right.ID) {
		return false
	}
	vi.ConsoleLine(MarkerPin + "id=" + vi.Itoa64(int64(right.ID)) + " on")
	// First dump: pin bit + left partition. There is no kernel pin object
	// to ack; this is the strip after Pin().
	dumpOrder()
	fid, _ := tabs.Focused()
	other := tabs.At(0).ID
	if other == fid {
		other = tabs.At(1).ID
	}
	if other == 0 || other == fid {
		return false
	}
	// Second dump only after the kernel took the focus change. A failed
	// taskbar click must not look like pin-stayed-left-across-focus.
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
