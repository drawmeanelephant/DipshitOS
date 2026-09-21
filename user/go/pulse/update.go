//go:build virelai || pulse

package main

// handleKey mutates the model for one decoded key text. The bound tty
// delivers decoded symbols (like the note app's EvKeyDown arg1): printable
// ASCII arrives verbatim, Return arrives as "\n", backspace as "\x7f",
// escape as "\x1b".
func (m *model) handleKey(text string) {
	// Help overlay eats everything except its dismiss keys.
	if m.help {
		switch text {
		case "?", "\x1b", "q":
			m.help = false
			if text == "q" {
				m.quit = true
			}
		}
		return
	}
	// Kill confirmation dialog.
	if m.confirm {
		switch text {
		case "y", "Y":
			m.doKill()
		case "n", "N", "\x1b":
			m.confirm = false
			m.notice = "kill cancelled"
		}
		return
	}
	// Filter entry mode.
	if m.filtering {
		switch text {
		case "\x7f", "\b":
			if len(m.filter) > 0 {
				m.filter = m.filter[:len(m.filter)-1]
			}
		case "\n", "\x1b":
			m.filtering = false
		default:
			if len(text) == 1 && text[0] >= 0x20 && text[0] < 0x7f && len(m.filter) < 24 {
				m.filter += text
			}
		}
		m.clampSel()
		return
	}

	switch text {
	case "1", "2", "3", "4":
		m.tab = tab(text[0] - '1')
		m.notice = ""
	case "j":
		if m.tab == tabProcs {
			m.sel++
			m.clampSel()
		}
	case "k":
		if m.tab == tabProcs {
			m.sel--
			m.clampSel()
		}
	case "s":
		// Cycle the sort column on the process table.
		if m.tab == tabProcs {
			m.sortCol = (m.sortCol + 1) % 3
			m.clampSel()
		}
	case "\n":
		// Return cycles the sort column too (matches the "enter sorts"
		// binding in the design).
		if m.tab == tabProcs {
			m.sortCol = (m.sortCol + 1) % 3
			m.clampSel()
		}
	case "/":
		if m.tab == tabProcs {
			m.filtering = true
		}
	case "x":
		if m.tab == tabProcs {
			rows := visibleProcs(m.snap, m.sortCol, m.filter)
			if m.sel >= 0 && m.sel < len(rows) {
				m.confirm = true
			} else {
				m.notice = "kill: no process selected"
			}
		}
	case "r":
		m.refresh()
		m.notice = "refreshed"
	case "?":
		m.help = true
	case "\x1b":
		// Escape closes nothing here; dialogs handle their own.
	case "q":
		m.quit = true
	}
}

// doKill arms the selected process for termination (slot 29) and reports the
// honest result: exit status 137 follows through the kernel's exit path.
func (m *model) doKill() {
	rows := visibleProcs(m.snap, m.sortCol, m.filter)
	m.confirm = false
	if m.sel < 0 || m.sel >= len(rows) {
		m.notice = "kill: no process selected"
		return
	}
	p := rows[m.sel]
	rc := int64(-38) // ENOSYS: no kill function injected (host default)
	if m.killFn != nil {
		rc = m.killFn(p.pid)
	}
	if rc == 0 {
		m.notice = "kill armed: pid=" + itoa64(p.pid) + " (" + p.name + ") -> exit 137"
	} else {
		m.notice = "kill pid=" + itoa64(p.pid) + " refused: " + killErrText(rc)
	}
	m.refresh()
}
