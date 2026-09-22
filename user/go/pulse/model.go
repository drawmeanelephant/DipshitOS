//go:build virelai || pulse

// Command pulse is PULSE.ELF: the Go seat's Charm TUI system monitor.
//
// Like charmhello (M72c) it owns a real tea.Model but does not run Bubble
// Tea's host Program loop: the Virelai port has no POSIX tty or signals, so
// key bytes come from the kernel's bound /dev/tty queue and View's ANSI goes
// back into that bound tty. A 1 Hz app timer (slot 40) drives the snapshot
// refresh; the snapshot layer is the only guest-only part, everything above
// it is pure and host-tested.
package main

import (
	tea "charm.land/bubbletea/v2"
)

// Tabs of the monitor.
type tab int

const (
	tabOverview tab = iota
	tabProcs
	tabNet
	tabStorage
	tabCount
)

func (t tab) name() string {
	switch t {
	case tabOverview:
		return "Overview"
	case tabProcs:
		return "Processes"
	case tabNet:
		return "Network"
	case tabStorage:
		return "Storage"
	}
	return "?"
}

// procInfo, snapshot and sortCol live in types.go: they are untagged there
// because the host stub and the pure derive layer must see them without the
// pulse tag (see that file's header).

type model struct {
	tab       tab
	snap      snapshot
	ticks     uint64
	sel       int
	sortCol   sortCol
	filter    string
	filtering bool
	confirm   bool
	notice    string
	help      bool
	quit      bool
	killFn    func(pid uint64) int64
	snapFn    func() snapshot
}

func newModel(killFn func(uint64) int64, snapFn func() snapshot) model {
	m := model{killFn: killFn, snapFn: snapFn}
	m.refresh()
	return m
}

// refresh takes a fresh snapshot and re-clamps the selection.
func (m *model) refresh() {
	if m.snapFn == nil {
		return
	}
	m.snap = m.snapFn()
	m.ticks++
	m.clampSel()
}

func (m *model) clampSel() {
	n := len(visibleProcs(m.snap, m.sortCol, m.filter))
	if n == 0 {
		m.sel = 0
		return
	}
	if m.sel < 0 {
		m.sel = 0
	}
	if m.sel >= n {
		m.sel = n - 1
	}
}

// Init is intentionally command-free: Virelai feeds key bytes from main.
func (model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return m, nil
	}
	m.handleKey(key.Key().Text)
	return m, nil
}

func keyPress(b byte) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Text: string([]byte{b}), Code: rune(b)})
}
