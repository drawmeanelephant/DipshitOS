// GOTABWM.ELF — M62c (issue #1401): apply SplitH / SplitV / Unsplit through
// the kernel's SET_WINDOW seam so each pane is a real WIN_RESIZE the client
// receives, not a paint-only fake.
//
// wm_apply_rect moves FIRST using the window's OLD size as the clamp, so a
// full-viewport window cannot be placed at x>0 or y>0 in one call (max_x
// is 0). applyRect shrinks at the origin first, then moves.
package main

import "virelai/vi"

// wmctlSetRect is the rect-proposal seam for the split/sash paths. It is
// vi.WmctlSetWindowRect in the guest; the indirection exists because that
// call goes out over syscall6, which bypasses vi's host-test syscall hook,
// and would otherwise leave the sash-drag -> relayout path unobservable off
// the guest. Same shape as hid.go's execApp.
var wmctlSetRect = vi.WmctlSetWindowRect

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
	_ = writeLayoutFile()
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
	_ = writeLayoutFile()
	return true
}

// applyRect proposes r through slot 65. A non-origin position is a two-step
// call so the kernel's move clamp sees the NEW size (see file comment).
func applyRect(id uint32, r Rect) bool {
	if r.X != 0 || r.Y != 0 {
		if wmctlSetRect(id, 0, 0, r.W, r.H) != 0 {
			return false
		}
	}
	return wmctlSetRect(id, r.X, r.Y, r.W, r.H) == 0
}

// applySashDrag commits a sash press-drag-release at divider position pos
// (an x for SplitVert, a y for SplitHoriz). The motion is NOT applied live:
// the seat paints no content-area chrome, so there is nothing truthful to
// preview with, and one relayout on the release edge keeps the feedback
// loop to a single WIN_RESIZE per pane. A release on the clamped position
// it already holds is an honest no-op (no syscalls, no markers). On a true
// change both rects go through applyRect first — the kernel clamp stays
// authoritative — and the sash is stored, marked, dumped, and persisted
// only after both calls returned.
func applySashDrag(pos int) bool {
	if tabs.Count() != 2 {
		return false
	}
	kind := tabs.Split()
	if kind != SplitVert && kind != SplitHoriz {
		return false
	}
	scanW, scanH := uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)
	from := tabs.sashCenter(scanW, scanH)
	to := clampSash(kind, pos, scanW, scanH)
	if to <= 0 || to == from {
		return false
	}
	ra, rb, ok := SplitRectsSash(kind, scanW, scanH, to)
	if !ok {
		return false
	}
	a, b := tabs.At(0), tabs.At(1)
	if !applyRect(a.ID, ra) || !applyRect(b.ID, rb) {
		return false
	}
	tabs.sash = to
	vi.ConsoleLine(MarkerSash + kind.String() +
		" from=" + vi.Itoa64(int64(from)) +
		" to=" + vi.Itoa64(int64(to)))
	dumpTab(a, ra, kind)
	dumpTab(b, rb, kind)
	_ = writeLayoutFile()
	return true
}

// applySplitCycle is the M79c (#1706) keyboard entry to a split: none -> V
// -> H -> none. Live mode has no other way to split — the choreography is
// demo-only — so without this the sash drag is unreachable outside a gate.
// Each step reuses the apply* path it lands on, so the markers and dumps
// are the same shapes the choreography already prints; a step the strip
// refuses (fewer than two tabs) is silent, like every other chord no-op.
func applySplitCycle() bool {
	switch tabs.Split() {
	case SplitVert:
		return applySplit(SplitHoriz)
	case SplitHoriz:
		return applyUnsplit()
	default:
		return applySplit(SplitVert)
	}
}

func dumpTab(t Tab, applied Rect, kind SplitKind) {
	focus := false
	if id, ok := tabs.Focused(); ok && id == t.ID {
		focus = true
	}
	vi.ConsoleLine(MarkerLayout + layoutLine(t.ID, layoutBin(t), applied, focus, kind))
	// Slot 19 WinQuery is owner-restricted (CALLER's window only). The
	// seat cannot read a hosted client's rect back. The pane line is the
	// rect SET_WINDOW just accepted; a kernel refusal skips dumpTab.
	vi.ConsoleLine(MarkerPane + paneLine(t.ID, applied))
}
