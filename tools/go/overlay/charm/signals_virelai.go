//go:build virelai

package tea

import "virelai/vi"

// cellsForRect maps the clamped frame rect a WIN_RESIZE event carries
// (arg0 = w, arg1 = h — both kernel emit sites push the post-clamp number
// the reflow used) onto CELLS, the TUI contract:
//
//	cols = clamp(w/cellW, 8, 80) — terminal.zig syncWindowCols -> setCols
//	rows = (h - 16)/cellH         — driving_award.zig rows_visible; the 16 px
//	                               title band (wnd_core title_bar_h) is not
//	                               client area; kernel's `else 1` below it
//
// M73l (#1661): cellW/cellH mirror kernel/src/font_metrics.zig — the
// FiraCode advance at pixel size 13 is 8 wide, ascent+descent 16 tall
// (the boot look). M80i (#1725): the cell is the ACTIVE zoom rung's
// (7x13 / 8x16 / 10x21), passed in as vi.TerminalCell() — re-read per
// WIN_RESIZE, the same rung the kernel's reflow just used.
//
// tabapp.CellGrid carries the canonical class-A pin (M73j #1636
// TestCellGridPinsKernel, M80i extended to every rung); this five-line
// copy keeps the Charm module dependency-free — keep the two in step.
func cellsForRect(w, h, cellW, cellH uint32) (cols, rows int) {
	cols = int(w / cellW)
	if cols < 8 {
		cols = 8
	}
	if cols > 80 {
		cols = 80
	}
	rows = 1
	if h > 16 {
		rows = int((h - 16) / cellH)
	}
	return cols, rows
}

// listenForResize is the Virelai replacement for the SIGWINCH watcher
// (M73j #1636): there is no POSIX signal or ioctl TIOCGWINSZ in the guest,
// so the Program polls the process's own ADR 0009 event queue for
// WIN_RESIZE (kind 10) and delivers tea.WindowSizeMsg in cells — the
// cadence charm v2 documents (every resize; the INITIAL message is the
// app's first size pump, which the tabapp-driven apps send themselves
// before their first paint).
//
// Ownership contract: when this runs, THIS goroutine owns the event queue
// — a Program-loop app must not poll vi.PollEventRaw a second time. The
// manual-Update apps (charmhello, pulse) never run a Program, so they are
// unaffected and pump tabapp's ActionResized themselves.
func (p *Program) listenForResize(done chan struct{}) {
	go func() {
		for {
			select {
			case <-done:
				return
			default:
			}
			ev, _, ok := vi.PollEventRaw()
			if !ok {
				// Non-blocking poll: stay cooperative, one tick per idle.
				vi.Sleep(1)
				continue
			}
			if ev.Kind == vi.EvWinResize {
				// M80i (#1725): the rung may have moved — a font zoom
				// arrives as the same WIN_RESIZE payload shape.
				cw, ch := vi.TerminalCell()
				cols, rows := cellsForRect(ev.Arg0, ev.Arg1, cw, ch)
				p.Send(WindowSizeMsg{Width: cols, Height: rows})
			}
		}
	}()
}
