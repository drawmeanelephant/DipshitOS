// Command charmhello is M72c's deliberately small Bubble Tea program.
//
// It does not run Bubble Tea's host Program loop: the Virelai port has no
// POSIX tty or signals, and this app must take bytes from the kernel's bound
// /dev/tty queue. It still owns a real tea.Model — Update receives HID-derived
// key messages and View emits Bubble Tea's ANSI text into that bound tty.
package main

import (
	tea "charm.land/bubbletea/v2"

	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "CHARMHELLO.ELF"
	appTitle = "Charm Hello"
	natW     = 640
	natH     = 400

	ttyPath = "/dev/tty"

	markerOpen    = "charmhello: open id="
	markerAttach  = "charmhello: attached"
	markerPainted = "charmhello: painted"
	markerReady   = "charmhello: ready"
	markerKey     = "charmhello: key "
	markerRepaint = "charmhello: repainted"
	markerClose   = "charmhello: close"
	markerOK      = "charmhello OK"
)

type model struct {
	paused bool
	keys   uint32
	quit   bool
}

// Init is intentionally command-free: Virelai feeds key bytes below.
func (model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return m, nil
	}
	switch key.Key().Text {
	case "q":
		m.quit = true
	case " ":
		m.paused = !m.paused
	default:
		m.keys++
	}
	return m, nil
}

func (m model) View() tea.View {
	state := "\x1b[1;92mRUNNING\x1b[0m"
	if m.paused {
		state = "\x1b[1;93mPAUSED\x1b[0m"
	}
	return tea.NewView(
		"\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H" +
			"\x1b[1;95m  VirelaiOS × Bubble Tea \x1b[0m\n\n" +
			"\x1b[96m  bound /dev/tty · real tea.Model\x1b[0m\n\n" +
			"  status: " + state + "\n" +
			"  keys:   \x1b[1;97m" + vi.Itoa64(int64(m.keys)) + "\x1b[0m\n\n" +
			"\x1b[90m  space toggles · q exits\x1b[0m\n",
	)
}

func keyPress(b byte) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Text: string([]byte{b}), Code: rune(b)})
}

func paint(fd uint32, m model) bool {
	v := m.View()
	n, rc := vi.FileWrite(fd, []byte(v.Content))
	return rc >= 0 && n == len(v.Content)
}

func main() {
	ta := tabapp.Init(tabapp.Config{
		Name:  appName,
		Title: appTitle,
		X:     32,
		Y:     32,
		W:     natW,
		H:     natH,
	})
	if ta == nil {
		vi.ConsoleLine("charmhello: open failed")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))

	h, rc := vi.FileOpen(ttyPath, vi.ModeRead|vi.ModeWrite)
	if rc < 0 {
		vi.ConsoleLine("charmhello: no /dev/tty")
		ta.CloseAndExit(2)
	}
	fd := uint32(h)
	if vi.TtyAttachWindow(ta.Win) != 0 {
		vi.FileClose(fd)
		vi.ConsoleLine("charmhello: attach failed")
		ta.CloseAndExit(3)
	}
	vi.ConsoleLine(markerAttach)

	m := model{}
	if !paint(fd, m) {
		shutdown(ta, fd, 4)
	}
	// A tty write marks the window dirty; yield once before the marker the
	// VZ gate uses as its screenshot barrier, so it describes a painted frame.
	vi.Sleep(2)
	vi.ConsoleLine(markerPainted)
	vi.ConsoleLine(markerReady)

	var in [64]byte
	for {
		n, _ := vi.FileRead(fd, in[:])
		if n > 0 {
			for _, b := range in[:n] {
				next, _ := m.Update(keyPress(b))
				m = next.(model)
				if m.quit {
					shutdown(ta, fd, 0)
				}
				if !paint(fd, m) {
					shutdown(ta, fd, 4)
				}
				vi.Sleep(1)
				if b == ' ' {
					vi.ConsoleLine(markerKey + "space")
				} else {
					vi.ConsoleLine(markerKey + string([]byte{b}))
				}
				vi.ConsoleLine(markerRepaint)
			}
		}

		ev, result, ok := vi.PollEventRaw()
		if !ok {
			if result < 0 {
				shutdown(ta, fd, 5)
			}
			if n <= 0 {
				vi.Sleep(1)
			}
			continue
		}
		if ta.Dispatch(ev) == tabapp.ActionClosed {
			shutdown(ta, fd, 0)
		}
	}
}

func shutdown(ta *tabapp.TabApp, fd uint32, status int) {
	_, _ = vi.FileWrite(fd, []byte("\x1b[?1049l\x1b[?25h"))
	_ = vi.TtyAttach(vi.TtyDetach)
	vi.FileClose(fd)
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	ta.CloseAndExit(status)
}
