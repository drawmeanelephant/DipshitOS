// GOTABWM.ELF — M62c (issue #1401): apply SplitH / SplitV / Unsplit through
// the kernel's SET_WINDOW seam so each pane is a real WIN_RESIZE the client
// receives, not a paint-only fake.
//
// wm_apply_rect moves FIRST using the window's OLD size as the clamp, so a
// full-viewport window cannot be placed at x>0 or y>0 in one call (max_x
// is 0). applyRect shrinks at the origin first, then moves.
package main

import "virelai/vi"

func applySplit(kind SplitKind) bool {
	ok := false
	switch kind {
	case SplitVert:
		ok = tabs.SplitV()
	case SplitHoriz:
		ok = tabs.SplitH()
	}
	if !ok {
		return false
	}
	ra, rb, ok := tabs.PaneRects(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
	if !ok {
		return false
	}
	a, b := tabs.At(0), tabs.At(1)
	if !applyRect(a.ID, ra) || !applyRect(b.ID, rb) {
		return false
	}
	vi.ConsoleLine(MarkerSplit + kind.String())
	dumpTab(a, ra, kind)
	dumpTab(b, rb, kind)
	return true
}

func applyUnsplit() bool {
	_ = tabs.Unsplit()
	full := FullRect(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
	n := tabs.Count()
	for i := 0; i < n; i++ {
		t := tabs.At(i)
		if !applyRect(t.ID, full) {
			return false
		}
		dumpTab(t, full, SplitNone)
	}
	vi.ConsoleLine(MarkerUnsplit)
	return true
}

// applyRect proposes r through slot 65. A non-origin position is a two-step
// call so the kernel's move clamp sees the NEW size (see file comment).
func applyRect(id uint32, r Rect) bool {
	if r.X != 0 || r.Y != 0 {
		if vi.WmctlSetWindowRect(id, 0, 0, r.W, r.H) != 0 {
			return false
		}
	}
	return vi.WmctlSetWindowRect(id, r.X, r.Y, r.W, r.H) == 0
}

func dumpTab(t Tab, applied Rect, kind SplitKind) {
	focus := false
	if id, ok := tabs.Focused(); ok && id == t.ID {
		focus = true
	}
	vi.ConsoleLine(MarkerLayout + layoutLine(t.ID, t.Title, applied, focus, kind))
	// Slot 19 WinQuery is owner-restricted (CALLER's window only). The
	// seat cannot read a hosted client's rect back. The pane line is the
	// rect SET_WINDOW just accepted; a kernel refusal skips dumpTab.
	vi.ConsoleLine(MarkerPane + paneLine(t.ID, applied))
}
