// GOTABWM.ELF — M62e (issue #1403): persist the in-process strip as `.tabs`
// v2 on /host/SESSION.TABS. Encode/Decode is a guest-safe copy of the
// host tabcodec layout (tabsv2.go); do not exec the host tool in-guest.
// Corrupt bytes fail closed: empty strip, no trust.
package main

import "virelai/vi"

const (
	sessionPath   = "/host/SESSION.TABS"
	sessionIDBase = uint32(0x100) // placeholder ids; records have no window id
)

var (
	sessionSeq     uint16 = 1
	sessionWritten bool
)

func sessionTitlesLine(s *TabStrip) string {
	titles := ""
	pins := "pin="
	for i := 0; i < s.count; i++ {
		if i > 0 {
			titles += ","
			pins += ","
		}
		titles += s.tabs[i].Title
		if s.tabs[i].Pinned {
			pins += "1"
		} else {
			pins += "0"
		}
	}
	a := 0
	if s.count > 0 {
		a = s.focus
	}
	return titles + " " + pins + " active=" + dec(uint32(a))
}

// writeHostFile replaces path with data through the M66b crash-safe
// write: temp + fsync + delete/rename publish (vi.WriteFileSafe). M62e
// wrote in place — the write-open truncated the live file to zero before
// the first chunk landed — so a crash mid-write left a partial
// SESSION.TABS or LAYOUT.txt behind for the next boot to trust or trip
// over; now the live path only ever appears atomically, and the crash
// window leaves the previous bytes or none, which fail-closed readers
// treat as defaults.
func writeHostFile(path string, data []byte) bool {
	return vi.WriteFileSafe(path, data) == 0
}

// writeSession encodes the live strip and writes SESSION.TABS. M62e is
// this one pin-stay snapshot (seat.go case 2), not save-on-exit/detach.
// Refuses an empty strip and runs once (sessionWritten) so the two-tab
// close path cannot clobber a good save.
func writeSession() bool {
	if tabs.Count() == 0 || sessionWritten {
		return false
	}
	raw, ok := tabs.encodeTabsV2(sessionSeq)
	if !ok {
		vi.ConsoleLine("gotabwm: session write fail")
		return false
	}
	if !writeHostFile(sessionPath, raw) {
		vi.ConsoleLine("gotabwm: session write fail")
		return false
	}
	sessionWritten = true
	sessionSeq++
	vi.ConsoleLine(MarkerSessionWrite + vi.Itoa64(int64(tabs.Count())))
	return true
}

// loadSession reads SESSION.TABS. Missing is a no-op (first boot).
// Corrupt/truncated bytes fail closed: empty strip + MarkerSessionBad.
func loadSession() {
	b, r := vi.ReadFileAll(sessionPath, tabsV2MaxBytes)
	if r < 0 || b == nil {
		return
	}
	seq, ok := tabs.applyTabsV2(b)
	if !ok {
		vi.ConsoleLine(MarkerSessionBad)
		return
	}
	sessionSeq = seq + 1
	if tabs.Count() == 0 {
		return
	}
	// Placeholder ids (sessionIDBase+) are not kernel windows. Leave
	// hostedApp=0 so a later Wmctl* cannot aim at 0x100+i. stripDone
	// skips the live choreography that would close/split them.
	hostedApp = 0
	stripDone = true
	vi.ConsoleLine(MarkerSessionLoad + vi.Itoa64(int64(tabs.Count())))
	vi.ConsoleLine(MarkerSessionTitles + sessionTitlesLine(&tabs))
	// M71e (#1564): how many restored tabs came back carrying the frozen
	// badge — the observable that the flag survived the round-trip. A
	// separate line, not a field on the titles line above: that line's exact
	// shape is asserted by go-wm-tabs run 02.
	vi.ConsoleLine(MarkerSessionFreeze + vi.Itoa64(int64(tabs.FrozenCount())))
	dumpOrder()
	_ = writeLayoutFile()
}
