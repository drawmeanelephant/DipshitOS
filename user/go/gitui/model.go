//go:build virelai || gitui

// The Bubble Tea model: Virelai feeds key bytes from the bound /dev/tty
// (main.go), View renders through the untagged render layer. No host
// Program loop — the Virelai port has no POSIX tty or signals (M72c
// precedent).
package main

import (
	tea "charm.land/bubbletea/v2"
)

type model struct {
	data   *Data
	view   int
	scroll int
	quit   bool
}

// Init is intentionally command-free: main.go feeds key bytes.
func (model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return m, nil
	}
	switch key.Key().Text {
	case "q":
		m.quit = true
	case "1":
		m.view, m.scroll = viewStatus, 0
	case "2":
		m.view, m.scroll = viewLog, 0
	case "3":
		m.view, m.scroll = viewDiff, 0
	case "j":
		m.scroll++
	case "k":
		if m.scroll > 0 {
			m.scroll--
		}
	}
	return m, nil
}

func (m model) View() tea.View {
	// Alt screen, hide cursor, clear, home — re-emitted every frame
	// (charmhello's prologue), so each paint is a complete frame.
	return tea.NewView(
		"\x1b[?1049h\x1b[?25l" + RenderFrame(m.data, m.view, m.scroll),
	)
}

func keyPress(b byte) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Text: string([]byte{b}), Code: rune(b)})
}
