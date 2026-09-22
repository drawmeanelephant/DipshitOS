//go:build virelai || rssui

// Package ui adapts the pure app.Model to Bubble Tea's Model/Update/View
// contract and owns the guest tty byte stream's translation into tea key
// messages.
//
// The Virelai port has no POSIX tty and no signals, so Bubble Tea's own host
// Program loop cannot run; main owns the read loop and hands KeyPressMsg values
// to Update, exactly as user/go/charmhello does. The Model/Update/View contract
// is Bubble Tea's.
package ui

import (
	tea "charm.land/bubbletea/v2"

	"virelai/rss/app"
	"virelai/rss/keys"
)

// Model wraps the pure state machine.
type Model struct {
	A       *app.Model
	Pending app.Effects
}

// New builds a model at a nominal viewport.
func New(width, height int) Model { return Model{A: app.New(width, height)} }

// Init satisfies tea.Model; the app has no startup command (Virelai feeds key
// bytes from the bound tty).
func (m Model) Init() tea.Cmd { return nil }

// Update receives one Bubble Tea message. Key presses are the only messages
// this app consumes; everything else is ignored.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	km, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return m, nil
	}
	m.Pending = m.A.Apply(fromTea(km))
	return m, nil
}

// View renders the current frame as ANSI text for the bound tty.
func (m Model) View() tea.View { return tea.NewView(m.A.Render()) }

// Reset clears the pending effects once the caller has discharged them.
func (m *Model) Reset() { m.Pending = app.Effects{} }

// KeyMessages decodes a chunk of raw guest tty bytes into Bubble Tea key
// messages, one per key press. Bytes that decode to nothing are skipped.
func KeyMessages(b []byte) []tea.KeyPressMsg {
	var out []tea.KeyPressMsg
	for len(b) > 0 {
		ev, n := keys.Decode(b)
		if n <= 0 {
			break
		}
		b = b[n:]
		if ev.Key == keys.KeyNone {
			continue
		}
		out = append(out, toTea(ev))
	}
	return out
}

func toTea(ev keys.Event) tea.KeyPressMsg {
	switch ev.Key {
	case keys.KeyRune:
		return tea.KeyPressMsg(tea.Key{Text: string(ev.Rune), Code: ev.Rune})
	case keys.KeyUp:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyUp})
	case keys.KeyDown:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyDown})
	case keys.KeyLeft:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyLeft})
	case keys.KeyRight:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyRight})
	case keys.KeyEnter:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyEnter})
	case keys.KeyEsc:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyEscape})
	case keys.KeyBackspace:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyBackspace})
	case keys.KeyHome:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyHome})
	case keys.KeyEnd:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyEnd})
	case keys.KeyPageUp:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyPgUp})
	case keys.KeyPageDown:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyPgDown})
	case keys.KeyTab:
		return tea.KeyPressMsg(tea.Key{Code: '\t'})
	default:
		return tea.KeyPressMsg(tea.Key{Code: 3}) // Ctrl-C
	}
}

func fromTea(k tea.KeyPressMsg) keys.Event {
	switch k.Code {
	case tea.KeyUp:
		return keys.Event{Key: keys.KeyUp}
	case tea.KeyDown:
		return keys.Event{Key: keys.KeyDown}
	case tea.KeyLeft:
		return keys.Event{Key: keys.KeyLeft}
	case tea.KeyRight:
		return keys.Event{Key: keys.KeyRight}
	case tea.KeyEnter:
		return keys.Event{Key: keys.KeyEnter}
	case tea.KeyEscape:
		return keys.Event{Key: keys.KeyEsc}
	case tea.KeyBackspace:
		return keys.Event{Key: keys.KeyBackspace}
	case tea.KeyHome:
		return keys.Event{Key: keys.KeyHome}
	case tea.KeyEnd:
		return keys.Event{Key: keys.KeyEnd}
	case tea.KeyPgUp:
		return keys.Event{Key: keys.KeyPageUp}
	case tea.KeyPgDown:
		return keys.Event{Key: keys.KeyPageDown}
	case '\t':
		return keys.Event{Key: keys.KeyTab}
	case 3:
		return keys.Event{Key: keys.KeyCtrlC}
	}
	if k.Text != "" {
		r := []rune(k.Text)
		return keys.Event{Key: keys.KeyRune, Rune: r[0]}
	}
	if k.Code >= 0x20 {
		return keys.Event{Key: keys.KeyRune, Rune: k.Code}
	}
	return keys.Event{Key: keys.KeyNone}
}
