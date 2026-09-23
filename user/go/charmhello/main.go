//go:build virelai || charmhello

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
	markerMouse   = "charmhello: mouse b="
	markerSize    = "charmhello: size "
)

// M73j (#1636): the port's unit pin for tea.WindowSizeMsg — CELLS, never
// pixels. Both numbers mirror kernel formulas for the SAME rect:
//
//	cols  = clamp(w/cellW, 8, 80) — terminal.zig syncWindowCols -> setCols
//	        (the M49 SD5-effective column count the grid reflows to)
//	rows  = (h - 16)/cellH         — driving_award.zig rows_visible, the
//	        16 px title band (wnd_core title_bar_h) is NOT client area
//
// M73l (#1661): cellW/cellH mirror kernel/src/font_metrics.zig —
// FiraCode at pixel size 13: advance 8, ascent+descent 16.
//
// A TUI can therefore never ask for geometry the grid will not render;
// TestSizeMsgPinsKernelCellMath pins the agreement class-A.
func sizeMsg(w, h uint32) tea.WindowSizeMsg {
	const cellW, cellH = 8, 16
	cols := int(w / cellW)
	if cols < 8 {
		cols = 8
	}
	if cols > 80 {
		cols = 80
	}
	rows := 1 // kernel: `if (h > title) (h-title)/cellH else 1`
	if h > 16 {
		rows = int((h - 16) / cellH)
	}
	return tea.WindowSizeMsg{Width: cols, Height: rows}
}

func sizeMarker(m model) string {
	return markerSize + vi.Itoa64(int64(m.cols)) + "x" + vi.Itoa64(int64(m.rows))
}

type model struct {
	paused bool
	keys   uint32
	quit   bool
	cols   int
	rows   int
}

// Init is intentionally command-free: Virelai feeds key bytes below.
func (model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	// M73j (#1636): the size message arrives ONCE at startup (from the
	// declared rect) and on every WIN_RESIZE (clamped w/h) — charm v2's
	// documented WindowSizeMsg cadence, in cells.
	if ws, ok := msg.(tea.WindowSizeMsg); ok {
		m.cols, m.rows = ws.Width, ws.Height
		return m, nil
	}
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
			"  keys:   \x1b[1;97m" + vi.Itoa64(int64(m.keys)) + "\x1b[0m\n" +
			"  size:   \x1b[1;97m" + vi.Itoa64(int64(m.cols)) + "x" + vi.Itoa64(int64(m.rows)) + "\x1b[0m\n\n" +
			"\x1b[90m  space toggles · q exits\x1b[0m\n",
	)
}

func keyPress(b byte) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Text: string([]byte{b}), Code: rune(b)})
}

// M73i (#1635): a ?1006 SGR mouse report shares the tty with keys:
// ESC [ < b ; x ; y M|m. ms holds a possibly-mouse escape prefix; any
// non-mouse escape (the arrow keys) flushes through the ordinary key path,
// so every pre-existing marker stays byte-identical.
var ms []byte
var mouseB, mouseX, mouseY int

type msAction int

const (
	msWait  msAction = iota // prefix so far is mouse-compatible; need more
	msMouse                 // complete report in mouseB/X/Y
	msDrop                  // not a mouse sequence: flush ms as keys
)

func msStep(b byte) msAction {
	switch len(ms) {
	case 0:
		if b == 0x1b {
			ms = append(ms, b)
			return msWait
		}
		return msDrop // never reached: the caller gates on ESC/pending
	case 1: // ESC
		if b == '[' {
			ms = append(ms, b)
			return msWait
		}
		ms = ms[:0]
		return msDrop
	case 2: // ESC [
		if b == '<' {
			ms = append(ms, b)
			return msWait
		}
		ms = ms[:0]
		return msDrop
	default: // ESC [ < … body
		if (b >= '0' && b <= '9') || b == ';' {
			if len(ms) >= 32 { // runaway: never a mouse report
				ms = ms[:0]
				return msDrop
			}
			ms = append(ms, b)
			return msWait
		}
		if b == 'M' || b == 'm' {
			ms = append(ms, b)
			ok, btn, x, y := parseSGRMouse(ms)
			ms = ms[:0]
			if ok {
				mouseB, mouseX, mouseY = btn, x, y
				return msMouse
			}
			return msDrop
		}
		ms = ms[:0]
		return msDrop
	}
}

// parseSGRMouse reads ESC [ < b ; x ; y M|m — hand-rolled (no strconv):
// the app only ever prints what the kernel sent.
func parseSGRMouse(seq []byte) (bool, int, int, int) {
	if len(seq) < 6 || seq[0] != 0x1b || seq[1] != '[' || seq[2] != '<' {
		return false, 0, 0, 0
	}
	var vals [3]int
	idx := 0
	cur := 0
	digits := false
	for i := 3; i < len(seq); i++ {
		b := seq[i]
		if b >= '0' && b <= '9' {
			cur = cur*10 + int(b-'0')
			digits = true
		} else if b == ';' {
			if !digits || idx >= 2 {
				return false, 0, 0, 0
			}
			vals[idx] = cur
			idx++
			cur = 0
			digits = false
		} else if b == 'M' || b == 'm' {
			if !digits || idx != 2 {
				return false, 0, 0, 0
			}
			vals[2] = cur
			return true, vals[0], vals[1], vals[2]
		} else {
			return false, 0, 0, 0
		}
	}
	return false, 0, 0, 0
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
	// M73i (#1635): enable xterm mouse reporting — ?1000 press/release
	// edges, ?1006 SGR encoding. The kernel tracks the modes per screen
	// (never painted) and reports plain pointer events over this window.
	if _, rcw := vi.FileWrite(fd, []byte("\x1b[?1000h\x1b[?1006h")); rcw < 0 {
		vi.ConsoleLine("charmhello: mouse enable failed")
	}

	m := model{}
	// M73j (#1636): the INITIAL WindowSizeMsg — the first frame paints at
	// the declared rect's real grid (640x400 -> 80x48), not a guess.
	next, _ := m.Update(sizeMsg(ta.W, ta.H))
	m = next.(model)
	vi.ConsoleLine(sizeMarker(m))
	if !paint(fd, m) {
		shutdown(ta, fd, 4)
	}
	// A tty write marks the window dirty; yield once before the marker the
	// VZ gate uses as its screenshot barrier, so it describes a painted frame.
	vi.Sleep(2)
	vi.ConsoleLine(markerPainted)
	vi.ConsoleLine(markerReady)

	// emitKey is the pre-M73i per-byte key path, unchanged: markers,
	// repaint and quit all fire exactly as they did before mouse parsing.
	emitKey := func(b byte) {
		next, _ := m.Update(keyPress(b))
		m = next.(model)
		if m.quit {
			shutdown(ta, fd, 0)
		}
		if b == 'r' {
			// M73j (#1636): the owner-side resize seam — sys_win_resize
			// (slot 47) clamps + reflows and pushes WIN_RESIZE; the loop's
			// ActionResized then delivers tea.WindowSizeMsg (512x384 ->
			// 64x46 cells) with its serial marker, the class-B proof.
			_ = vi.WinResize(ta.Win, 512, 384)
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

	var in [64]byte
	for {
		n, _ := vi.FileRead(fd, in[:])
		if n > 0 {
			for _, b := range in[:n] {
				if len(ms) > 0 || b == 0x1b {
					switch msStep(b) {
					case msWait:
						continue // holding a possible mouse prefix
					case msMouse:
						// Mouse is not a key: marker only, no repaint.
						vi.ConsoleLine(markerMouse + vi.Itoa64(int64(mouseB)) +
							" x=" + vi.Itoa64(int64(mouseX)) +
							" y=" + vi.Itoa64(int64(mouseY)))
						continue
					}
					// msDrop: flush the held prefix as keys, then this byte.
					pending := ms
					ms = nil
					for _, pb := range pending {
						emitKey(pb)
					}
				}
				emitKey(b)
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
		// M73j (#1636): tabapp.Dispatch already consumes WIN_RESIZE into
		// ActionResized (arg0/arg1 = the clamped w/h both emit sites
		// carry) — this used to fall through unhandled, so a resized
		// window repainted at stale geometry forever. Size msg ->
		// repaint -> serial marker with the NEW cells, the class-B seam.
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			shutdown(ta, fd, 0)
		case tabapp.ActionResized:
			next, _ := m.Update(sizeMsg(ev.Arg0, ev.Arg1))
			m = next.(model)
			if !paint(fd, m) {
				shutdown(ta, fd, 4)
			}
			vi.Sleep(1)
			vi.ConsoleLine(sizeMarker(m))
			vi.ConsoleLine(markerRepaint)
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
