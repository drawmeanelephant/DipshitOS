// Command gitui is M74b's in-guest Git TUI (#1645): a read-only porcelain
// over a local .git — status, log and diff views in cells, rendered as
// plain ANSI (charmhello's View style) so this whole layer stays untagged
// and host-tested; main.go/model.go wrap it in a real tea.Model on the
// bound /dev/tty.
//
// Colour contract (the class-B gate counts these pixels): the magenta
// header is the app identity in every view, status rows are green/yellow/
// red (staged/modified/untracked), log shas are cyan, diff adds are green,
// removes red and @@ headers blue — and each view shows ONLY its own
// colours, which is how the PNG asserts prove the switch actually happened.
package main

import (
	"strconv"

	"virelai/git/gitread"
)

// Serial markers. Gate contracts: go-gitui.spec asserts these exact
// strings and render_test.go pins them host-side — renaming one is a spec
// change, not a refactor.
const (
	markerOpen    = "gitui: open id="
	markerAttach  = "gitui: attached"
	markerPainted = "gitui: painted"
	markerReady   = "gitui: ready"
	markerKey     = "gitui: key "
	markerRepaint = "gitui: repainted"
	markerView    = "gitui: view "
	markerMouse   = "gitui: mouse b="
	markerClose   = "gitui: close"
	markerOK      = "gitui OK"
	markerRepo    = "gitui: repo "
	markerStatus  = "gitui: status "
	markerEntry   = "gitui: entry "
	markerLog     = "gitui: log n="
	markerSubject = "gitui: subject "
	markerDiff    = "gitui: diff "
	markerErr     = "gitui: error "
)

// Views.
const (
	viewStatus = iota
	viewLog
	viewDiff
	viewCount
)

func viewName(v int) string {
	switch v {
	case viewStatus:
		return "status"
	case viewLog:
		return "log"
	case viewDiff:
		return "diff"
	}
	return "?"
}

// ANSI SGR set (hand-rolled, charmhello style — no lipgloss, so the module
// graph stays bubbletea-only). The bright-basic slots whose exact hue the
// fleet has NOT pinned (\e[90m, \e[97m) are avoided: tabs and body ink
// use M17 truecolour (live-term #1634 proves exact-RGB end to end), so no
// colour-contract assert ever rests on an unproven palette entry.
const (
	colReset  = "\x1b[0m"
	colHeader = "\x1b[1;95m"             // bold magenta: app identity, every view (M72c-proven)
	colInk    = "\x1b[38;2;230;230;230m" // truecolour white: active tab, log subjects
	colTabOff = "\x1b[38;2;130;130;130m" // truecolour gray: inactive tabs, help, root
	colStaged = "\x1b[1;92m"             // bold green: staged rows + counts
	colMod    = "\x1b[1;93m"             // bold yellow: modified rows (93=0xf5f543, live-term)
	colUntrk  = "\x1b[1;91m"             // bold red: untracked rows
	colSha    = "\x1b[96m"               // cyan: log shas (M72 pulse-proven)
	colPlus   = "\x1b[92m"               // green: diff added lines
	colMinus  = "\x1b[1;91m"             // red: diff removed lines
	colHunk   = "\x1b[94m"               // blue: diff file/hunk headers
)

// tabLabel is the row-0 tab strip; tabAtCell maps a 1-based SGR cell on
// row 1 (y == 1) to a view — the M73i mouse seam. Cell x positions come
// straight from this string:
//
//	1:" " 2-7:"status" 8:" " 9:"|" 10:" " 11-13:"log" 14:" " 15:"|" 16:" " 17-20:"diff" 21:" "
const tabLabel = " status | log | diff "

func tabAtCell(x, y int) int {
	if y != 1 {
		return -1
	}
	switch {
	case x >= 2 && x <= 7:
		return viewStatus
	case x >= 11 && x <= 13:
		return viewLog
	case x >= 17 && x <= 20:
		return viewDiff
	}
	return -1
}

// Data is everything the three views render: loaded once by main over
// gitread, built by tests over synthesized values.
type Data struct {
	Root   string
	Status gitread.Status
	Log    []gitread.Rev
	Diffs  []gitread.FileDiff
}

// clientRows is the 640x400 window's client grid (400 - 16 title = 384 /
// 8): rows 0 tabs, 1 header, 2 help, 3..47 content.
const clientRows = 45

func tabsLine(active int) string {
	out := "\x1b[2J\x1b[H" // full-frame clear: the View starts clean
	cells := []string{"status", "log", "diff"}
	// Rebuild tabLabel from parts so label text and tabAtCell stay in sync:
	// " status | log | diff "
	out += colTabOff + " "
	for i, c := range cells {
		if i > 0 {
			out += colTabOff + " | "
		}
		if i == active {
			out += colInk
		} else {
			out += colTabOff
		}
		out += c
	}
	out += colTabOff + " "
	return out + colReset
}

// frameLines builds the view's text rows (tab strip first, no prologue).
func frameLines(d *Data, view int) []string {
	lines := []string{tabsLine(view)}
	lines = append(lines,
		colHeader+"  VirelaiOS × GOGITUI"+colReset+" "+
			colTabOff+d.Root+colReset)
	lines = append(lines,
		colTabOff+"  1/2/3 views · j/k scrolls · q quits"+colReset)
	switch view {
	case viewStatus:
		st := &d.Status
		counts := "  " + colStaged + "staged=" + strconv.Itoa(len(st.Staged)) +
			colMod + " modified=" + strconv.Itoa(len(st.Modified)) +
			colUntrk + " untracked=" + strconv.Itoa(len(st.Untracked)) + colReset
		lines = append(lines, counts, "")
		for _, e := range st.Staged {
			lines = append(lines, "  "+colStaged+string([]byte{e.Code})+" "+e.Path+colReset)
		}
		for _, e := range st.Modified {
			lines = append(lines, "  "+colMod+string([]byte{e.Code})+" "+e.Path+colReset)
		}
		for _, e := range st.Untracked {
			lines = append(lines, "  "+colUntrk+string([]byte{e.Code})+" "+e.Path+colReset)
		}
	case viewLog:
		lines = append(lines, "")
		for _, r := range d.Log {
			lines = append(lines, "  "+colSha+gitread.ShortHex(r.Sha)+colReset+" "+colInk+r.Subject+colReset)
		}
	case viewDiff:
		lines = append(lines, "")
		for _, f := range d.Diffs {
			lines = append(lines, "  "+colHunk+"diff "+f.Path+colReset)
			lines = append(lines, "  "+colHunk+f.Header+colReset)
			for _, l := range f.Lines {
				if l.Op == '+' {
					lines = append(lines, "  "+colPlus+"+"+l.Text+colReset)
				} else {
					lines = append(lines, "  "+colMinus+"-"+l.Text+colReset)
				}
			}
			lines = append(lines, "")
		}
	}
	return lines
}

// RenderFrame is the whole window content: frame rows sliced by scroll.
func RenderFrame(d *Data, view, scroll int) string {
	lines := frameLines(d, view)
	if scroll > len(lines)-clientRows {
		scroll = len(lines) - clientRows
	}
	if scroll < 0 {
		scroll = 0
	}
	out := ""
	for i := scroll; i < len(lines); i++ {
		out += lines[i] + "\n"
		if i-scroll >= clientRows-1 {
			break
		}
	}
	return out
}
