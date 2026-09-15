// Command files is the M58a (issue #1305) Go file manager: list / open /
// navigate the host share, full-viewport inside Zig TABWM via user/go/tabapp.
// Zig FILE.BIN stays. No LIBUI — the three M56e widgets (text/button/list)
// are the whole toolkit.
//
// Every marker below is printed only AFTER its syscall returned, so the
// go-files VZ gate's asserts can only pass if the app actually ran.
package main

import (
	"virelai/tabapp"
	"virelai/vi"
	"virelai/widgets"
)

const (
	appName  = "GOFILES.ELF"
	appTitle = "Files"
	natW     = 512
	natH     = 384

	markerOpen    = "gofiles: open id="
	markerDeclare = "gofiles: declare accepted"
	markerList    = "gofiles: list "
	markerEntry   = "gofiles: entry "
	markerFound   = "gofiles: found KNOWN.TXT"
	markerView    = "gofiles: view "
	markerPresent = "gofiles: present"
	markerClose   = "gofiles: close"
	markerOK      = "gofiles OK"
	markerListErr = "gofiles: list error "
	markerCd      = "gofiles: cd "

	keyEnter  = 0x28
	keyEscape = 0x29
	keyBacksp = 0x2a
	keyDown   = 0x51
	keyUp     = 0x52
)

type app struct {
	ta       *tabapp.TabApp
	path     string
	entries  [vi.MaxDirEntries]vi.DirEntry
	n        int
	sel      int
	status   string
	preview  string
	list     widgets.List
	upBtn    widgets.Button
	openBtn  widgets.Button
	closeBtn widgets.Button
	pathTxt  widgets.Text
	statTxt  widgets.Text
}

func main() {
	ta := tabapp.Init(tabapp.Config{Name: appName, Title: appTitle, X: 32, Y: 32, W: natW, H: natH})
	if ta == nil {
		vi.ConsoleLine("gofiles: error open -1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine("gofiles: declare refused")
	}

	a := &app{ta: ta, path: startPath(), sel: 0}
	a.refresh()
	a.autoOpenKnown()
	a.draw()
	a.ta.Present()
	vi.ConsoleLine(markerPresent)

	for {
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				break
			}
			vi.Sleep(1)
			continue
		}
		switch a.ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			vi.ConsoleLine(markerClose)
			vi.ConsoleLine(markerOK)
			a.ta.CloseAndExit(0)
		case tabapp.ActionResized:
			a.draw()
			a.ta.Present()
		case tabapp.ActionNone:
			if a.handle(ev) {
				a.draw()
				a.ta.Present()
			}
		}
	}
}

func startPath() string {
	args := vi.Args()
	if len(args) > 1 && len(args[1]) > 0 && len(args[1]) <= maxPath {
		return args[1]
	}
	return rootPath
}

func (a *app) refresh() {
	n, rc := vi.DirList(a.path, a.entries[:])
	if rc < 0 {
		a.n = 0
		a.sel = 0
		a.status = "list err"
		vi.ConsoleLine(markerListErr + vi.Itoa64(rc))
		return
	}
	a.n = n
	if a.sel >= a.n {
		a.sel = 0
	}
	if a.sel < 0 {
		a.sel = 0
	}
	vi.ConsoleLine(markerList + a.path + " n=" + vi.Itoa64(int64(a.n)))
	for i := 0; i < a.n; i++ {
		name := a.entries[i].NameString()
		kind := "file"
		if a.entries[i].Dir() {
			kind = "dir"
		}
		vi.ConsoleLine(markerEntry + name + " " + kind + " size=" + vi.Itoa64(int64(a.entries[i].Size)))
		if name == knownName {
			vi.ConsoleLine(markerFound)
		}
	}
	a.status = "listed"
}

func (a *app) autoOpenKnown() {
	if !containsName(a.entries[:], a.n, knownName) {
		return
	}
	child, ok := joinPath(a.path, knownName)
	if !ok {
		return
	}
	a.viewFile(child, knownName)
}

func (a *app) viewFile(path, name string) {
	body, rc := vi.ReadFileAll(path, 512)
	if rc < 0 {
		a.status = "open err"
		return
	}
	a.preview = clipPreview(body)
	a.status = "view " + name
	vi.ConsoleLine(markerView + name + " bytes=" + vi.Itoa64(int64(len(body))))
}

func clipPreview(body []byte) string {
	const capN = 40
	n := 0
	for n < len(body) && n < capN && body[n] != '\n' && body[n] != '\r' {
		n++
	}
	return string(body[:n])
}

func (a *app) openSelected() bool {
	if a.n == 0 || a.sel < 0 || a.sel >= a.n {
		return false
	}
	e := a.entries[a.sel]
	name := e.NameString()
	child, ok := joinPath(a.path, name)
	if !ok {
		return false
	}
	if e.Dir() {
		a.path = child
		a.sel = 0
		a.preview = ""
		vi.ConsoleLine(markerCd + a.path)
		a.refresh()
		return true
	}
	a.viewFile(child, name)
	return true
}

func (a *app) goUp() bool {
	parent := parentPath(a.path)
	if parent == a.path {
		return false
	}
	a.path = parent
	a.sel = 0
	a.preview = ""
	vi.ConsoleLine(markerCd + a.path)
	a.refresh()
	return true
}

func (a *app) handle(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvKeyDown:
		switch ev.Arg0 {
		case keyDown:
			if a.n > 0 && a.sel+1 < a.n {
				a.sel++
				return true
			}
		case keyUp:
			if a.sel > 0 {
				a.sel--
				return true
			}
		case keyEnter:
			return a.openSelected()
		case keyBacksp, keyEscape:
			return a.goUp()
		}
	case vi.EvMouseDown:
		if ev.Flags&vi.BtnLeft == 0 {
			return false
		}
		x, y := int(ev.Arg0), int(ev.Arg1)
		if a.upBtn.HitTest(x, y) {
			return a.goUp()
		}
		if a.closeBtn.HitTest(x, y) {
			vi.ConsoleLine(markerClose)
			vi.ConsoleLine(markerOK)
			a.ta.CloseAndExit(0)
		}
		if a.openBtn.HitTest(x, y) {
			return a.openSelected()
		}
		if i := a.list.ItemAt(x, y); i >= 0 {
			if i == a.sel {
				return a.openSelected()
			}
			a.sel = i
			return true
		}
	}
	return false
}

func (a *app) layout() {
	ta := a.ta
	a.pathTxt = widgets.Text{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 8, W: int(natW) - 16, H: 20}),
		Label: a.path,
		Fg:    0xffffff,
		Bg:    0x1e2430,
	}
	a.list = widgets.List{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 32, W: int(natW) - 16, H: 288}),
		Items: labelsOf(a.entries[:], a.n),
		RowH:  scaleH(ta, 18),
		Sel:   a.sel,
		Fg:    0xd8e0e8,
		Bg:    0x161c24,
		SelBg: 0x2c3a4c,
	}
	a.upBtn = widgets.Button{
		R:        scaleR(ta, widgets.Rect{X: 8, Y: 328, W: 56, H: 28}),
		Label:    "Up",
		Face:     0x2a3340,
		Border:   0x5a6a80,
		LabelRGB: 0xe0e8f0,
	}
	a.openBtn = widgets.Button{
		R:        scaleR(ta, widgets.Rect{X: 72, Y: 328, W: 64, H: 28}),
		Label:    "Open",
		Face:     0x2a3340,
		Border:   0x5a6a80,
		LabelRGB: 0xe0e8f0,
	}
	a.closeBtn = widgets.Button{
		R:        scaleR(ta, widgets.Rect{X: int(natW) - 104, Y: 328, W: 96, H: 28}),
		Label:    "Close",
		Face:     0x2a3340,
		Border:   0x5a6a80,
		LabelRGB: 0xe0e8f0,
	}
	stat := a.status
	if a.preview != "" {
		stat = a.status + " " + a.preview
	}
	a.statTxt = widgets.Text{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 360, W: int(natW) - 16, H: 16}),
		Label: stat,
		Fg:    0xa8b0b8,
		Bg:    0x101418,
	}
}

func (a *app) draw() {
	a.layout()
	var f vi.Filler
	f.Rect(a.ta.Win, 0, 0, a.ta.W, a.ta.H, 0x101418)
	cv := &widgetCanvas{f: &f, win: a.ta.Win}
	a.pathTxt.Draw(cv)
	a.list.Draw(cv)
	a.upBtn.Draw(cv)
	a.openBtn.Draw(cv)
	a.closeBtn.Draw(cv)
	a.statTxt.Draw(cv)
	f.Flush()
}

type widgetCanvas struct {
	f   *vi.Filler
	win int
}

func (c *widgetCanvas) FillRect(r widgets.Rect, rgb uint32) {
	if r.W <= 0 || r.H <= 0 {
		return
	}
	c.f.Rect(c.win, uint32(r.X), uint32(r.Y), uint32(r.W), uint32(r.H), rgb)
}

func scaleR(ta *tabapp.TabApp, r widgets.Rect) widgets.Rect {
	s := ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, natW, natH)
	return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
}

func scaleH(ta *tabapp.TabApp, h int) int {
	s := ta.Layout(tabapp.Rect{X: 0, Y: 0, W: 1, H: h}, natW, natH)
	if s.H < 1 {
		return 1
	}
	return s.H
}
