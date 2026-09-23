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

type sessionLoadState uint8

const (
	sessionMissing sessionLoadState = iota
	sessionRestored
	sessionCorrupt
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

// restoreSessionBytes keeps the missing/corrupt/present decisions testable on
// the host. A missing file is distinct from an invalid or valid empty session:
// only missing can request the first-boot workspace.
func restoreSessionBytes(strip *TabStrip, b []byte, readResult int64) (uint16, sessionLoadState) {
	if readResult < 0 || b == nil {
		return 0, sessionMissing
	}
	seq, ok := strip.applyTabsV2(b)
	if !ok {
		return 0, sessionCorrupt
	}
	return seq, sessionRestored
}

// loadSession reads SESSION.TABS. Missing is the first-boot branch; corrupt
// or truncated bytes fail closed, while a present valid file is restored.
func loadSession() sessionLoadState {
	b, r := vi.ReadFileAll(sessionPath, tabsV2MaxBytes)
	seq, state := restoreSessionBytes(&tabs, b, r)
	if state == sessionMissing {
		return state
	}
	if state == sessionCorrupt {
		vi.ConsoleLine(MarkerSessionBad)
		return state
	}
	sessionSeq = seq + 1
	if tabs.Count() == 0 {
		return state
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
	return state
}

// firstBootWorkspace is only for the default Go seat. A deliberately selected
// shim-only seat (wm=none) may exec GOTABWM for a gate, and the Zig fallback
// (wm=tabwm) owns its own startup path.
func firstBootWorkspace(state sessionLoadState, wm string) bool {
	return state == sessionMissing && wm == "gotabwm"
}

func hasLiveGuestELF(rows []vi.ProcRow) bool {
	for _, row := range rows {
		if row.State != vi.ProcCreated && row.State != vi.ProcRunning {
			continue
		}
		name := row.Name()
		if name != "GOTABWM.ELF" && len(name) > 4 && name[len(name)-4:] == ".ELF" {
			return true
		}
	}
	return false
}

// anotherGuestProgram prevents an explicitly started app (for example,
// GOSH in a gate script) from being duplicated by the first-boot default.
func anotherGuestProgram() bool {
	var rows [64]vi.ProcRow
	n, r := vi.Procs(rows[:])
	return r >= 0 && hasLiveGuestELF(rows[:n])
}
