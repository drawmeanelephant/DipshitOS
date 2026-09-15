// Package tabapp is the M56d (issue #1315) Go mirror of
// user/src/lib/tabapp.zig — the ~40-line shape that makes a Go app work
// full-viewport inside the tabbed desktop (Zig TABWM). It packages four
// things once:
//
//  1. Open   — win_open at the legacy fixed rect (presentation unchanged).
//  2. Declare — a kind-8 declare_fullscreen WM_RPC (best-effort: TABWM accepts
//     and marks the tab full-viewport eligible; WND.BIN/the shim refuse the
//     additive kind and the app keeps its native size — the zero-regression
//     path).
//  3. Dispatch — WIN_CLOSE -> clean exit, WIN_RESIZE -> relayout at the new
//     canvas (the app tracks w/h here).
//  4. Scale — map a fixed layout into the new canvas; the identity mapping at
//     the native canvas is the zero-regression fixed point.
//
// No heap beyond the returned struct's own state, no libc, no cgo. On the host
// every vi call degrades to -ENOSYS, so init returns nil and the dispatch/scale
// logic stays plain unit-test surface.
package tabapp

import "virelai/vi"

// Config opens/starts a tab app. Name is THIS process's own executable name
// (the WM ack-routing needs it); Title is the tab title.
type Config struct {
	Name  string
	Title string
	X, Y  uint32
	W, H  uint32
}

// Action is what Dispatch decided the app should do with an event.
type Action int

const (
	// ActionNone: not a WM-lifecycle event — handle as usual.
	ActionNone Action = iota
	// ActionResized: relayout at the new canvas (W, H).
	ActionResized
	// ActionClosed: clean up and exit.
	ActionClosed
)

// Rect is a layout rectangle in canvas coordinates.
type Rect struct{ X, Y, W, H int }

// TabApp is the app shell state.
type TabApp struct {
	Win      int
	W, H     uint32
	Name     string
	TabAware bool
	OpenOK   bool
}

// Init opens the window and declares tab-awareness. It returns nil when
// win_open fails (the caller prints and exits).
func Init(cfg Config) *TabApp {
	win, res := vi.WinOpen(cfg.X, cfg.Y, cfg.W, cfg.H)
	if res < 0 {
		return nil
	}
	ta := &TabApp{
		Win:    win,
		W:      cfg.W,
		H:      cfg.H,
		Name:   cfg.Name,
		OpenOK: true,
	}
	// Best-effort declaration: one blocking RPC at startup. TABWM accepts it;
	// the shim/WND refuse and the app keeps its native presentation.
	ta.TabAware = vi.DeclareFullscreen(uint32(win), cfg.Title, cfg.Name)
	return ta
}

// Dispatch classifies one event and tracks the canvas size. Everything that is
// not a WM-lifecycle event stays the app's own business.
func (t *TabApp) Dispatch(ev vi.Event) Action {
	switch ev.Kind {
	case vi.EvWinClose:
		return ActionClosed
	case vi.EvWinResize:
		t.W = ev.Arg0
		t.H = ev.Arg1
		return ActionResized
	}
	return ActionNone
}

// Present flushes the current frame (the app draws first).
func (t *TabApp) Present() { vi.WinPresent(t.Win) }

// Close closes the window without exiting.
func (t *TabApp) Close() { vi.WinClose(t.Win) }

// CloseAndExit is the common exit path: close the window, then exit.
func (t *TabApp) CloseAndExit(status int) {
	t.Close()
	vi.Exit(status)
}

// DeclareNav tells the WM this tab navigated to path (the browser-history
// analogue for FILE/EDIT tabs). Best-effort.
func (t *TabApp) DeclareNav(path string) { vi.DeclareNav(uint32(t.Win), path, t.Name) }

// PollNav returns a back/forward target the user picked, or "",false.
func (t *TabApp) PollNav() (string, bool) { return vi.PollNav(uint32(t.Win), t.Name) }

// Scale maps r from a fromW x fromH canvas into toW x toH (integer math,
// rounding toward the top-left, minimum 1px). At the identity mapping
// (to == from) every rect maps to itself exactly — the zero-regression fixed
// point that makes an un-resized tab render byte-identically.
func Scale(r Rect, fromW, fromH, toW, toH uint32) Rect {
	if fromW == 0 || fromH == 0 {
		return r
	}
	if fromW == toW && fromH == toH {
		return r
	}
	x := int(uint64(uint32(r.X)) * uint64(toW) / uint64(fromW))
	y := int(uint64(uint32(r.Y)) * uint64(toH) / uint64(fromH))
	w := int(uint64(uint32(r.W)) * uint64(toW) / uint64(fromW))
	h := int(uint64(uint32(r.H)) * uint64(toH) / uint64(fromH))
	if w < 1 {
		w = 1
	}
	if h < 1 {
		h = 1
	}
	return Rect{x, y, w, h}
}

// Layout scales r from the native canvas into THIS app's current canvas.
func (t *TabApp) Layout(r Rect, fromW, fromH uint32) Rect {
	return Scale(r, fromW, fromH, t.W, t.H)
}
