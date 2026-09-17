// GOTABWM.ELF — M62f (issue #1404): write /host/SELFTEST/LAYOUT.txt, the
// ADR 0033 D4 structural dump. UTF-8 LF, no timestamps or pointers. One
// line per tab from the applied SET_WINDOW rects (slot 19 WinQuery is
// owner-only, so the seat cannot read a hosted client's rect back). The
// file is closed before the serial line that names it.
package main

import "virelai/vi"

const (
	selftestDir = "/host/SELFTEST"
	layoutPath  = selftestDir + "/LAYOUT.txt"
)

func layoutBin(t Tab) string {
	if t.Bin != "" {
		return t.Bin
	}
	return t.Title
}

// layoutFileBody is the LAYOUT.txt payload for s. Empty strip yields nil
// (do not write an empty file over a good dump).
func layoutFileBody(s *TabStrip, scanW, scanH uint32) []byte {
	n := s.Count()
	if n == 0 {
		return nil
	}
	kind := s.Split()
	full := FullRect(scanW, scanH)
	ra, rb := full, full
	two := false
	if n == 2 {
		a, b, ok := s.PaneRects(scanW, scanH)
		if ok {
			ra, rb, two = a, b, true
		}
	}
	fid, has := s.Focused()
	out := make([]byte, 0, n*96)
	for i := 0; i < n; i++ {
		t := s.At(i)
		r := full
		if two {
			if i == 0 {
				r = ra
			} else {
				r = rb
			}
		}
		line := layoutLine(t.ID, layoutBin(t), r, has && t.ID == fid, kind)
		out = append(out, line...)
		out = append(out, '\n')
	}
	return out
}

func mkdirHost(path string) {
	h, r := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if r >= 0 {
		vi.FileClose(uint32(h))
	}
}

// writeLayoutFile writes LAYOUT.txt then prints the path. Callers must
// not print the path first.
func writeLayoutFile() bool {
	body := layoutFileBody(&tabs, uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
	if len(body) == 0 {
		return false
	}
	mkdirHost(selftestDir)
	if !writeHostFile(layoutPath, body) {
		vi.ConsoleLine("gotabwm: layout write fail")
		return false
	}
	vi.ConsoleLine(MarkerLayoutFile + layoutPath)
	return true
}
