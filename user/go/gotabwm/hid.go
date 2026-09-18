// GOTABWM.ELF — M63b (issue #1420): kind-21 WM_KEY chords.
//
// Frozen table on #1418 (no new ADR, no new kernel cmd, no ctrl-tab):
//
//	ctrl-shift-p  -> Pin() the focused tab
//	alt-tab       -> FocusTab + WmctlTaskbarClick (cmd 12), wrapping
//
// Markers print only after the mutation/syscall that made them true.
// Ctrl+W is not bound (it collides with the editor). Ctrl+Tab waits on M63r.
package main

import "virelai/vi"

const (
	MarkerAltTab = "gotabwm: alt-tab id="

	// USB HID keyboard usages (the kernel's WM_KEY arg0).
	hidUsageP   uint8 = 0x13
	hidUsageTab uint8 = 0x2B
)

// hidChordHold is how many composite ticks the two-tab choreography waits
// after first seeing n>=2, so `--input-chords 'ctrl-shift-p,alt-tab'` can
// land before auto reorder/pin/close. Virtio chords pace at 0.25 s/stroke
// plus a 1 s settle; 8 ticks at 1 Hz is the same budget as pointerClickHold.
const hidChordHold = 8

func handleWmKey(e vi.Event) {
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
	vi.ConsoleLine(MarkerAltTab + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(id)))
	dumpOrder()
	return true
}
