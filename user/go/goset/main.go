// Command settings is GOSET.ELF — M71f (#1565): the Go settings panel.
//
// The Zig panel (user/src/settings_panel.zig, SETTINGS.BIN) is gone. On the
// DEFAULT seat the panel you launch is this one: a Go app, in the Go catalogue,
// writing the same schema-v2 /host/SETTINGS.TXT the seat and the kernel already
// read. That is the whole point of the card — before this, `wm` could not be
// changed from a Go UI on the default seat.
//
// What it edits is exactly what is IN FORCE (card D1, no new schema): the rows
// the file carries, plus one row per kernel-table key the file omits, holding
// the compiled default (settings.KnownKeys, pinned against kernel/src/settings.zig
// by a host test). Unknown keys that a file happens to carry are preserved
// byte-for-byte through a save but are not offered for editing.
//
// Two ways to edit, both reading the SAME display table:
//
//	Up/Down      select a row
//	Left/Right   cycle the selected row through its vocabulary (wm, theme, ...)
//	key=value ⏎  apply and save (the typed line the gate drives)
//	⏎ alone      save the table as shown
//	Esc          quit without saving
//
// M73m (#1662) adds the PALETTE surface: `theme` cycles the three built-in
// presets plus `custom`, and choosing `custom` reveals the three colour rows
// (palette_fg/palette_bg/palette_accent, six hex digits each) plus a live
// swatch band — the colours are visible before they are saved. The kernel
// resolves them at paint time (settings.zig's apply chain), so the terminal
// repaints on the next frame after the store is written; the panel's own
// chrome follows only presets (theme.Set knows dark|light and refuses the
// rest, so an amber/custom choice leaves this window on its current tokens —
// never a typo-invented palette).
//
// A save goes through the codec's crash-safe publish (vi.WriteFileSafe: temp +
// fsync + delete/rename), never an in-place truncate. A CORRUPT file is
// refused whole, exactly as the kernel and the seat refuse it: the panel names
// it, shows the compiled defaults that are therefore in force, and refuses
// every write — a panel must never launder a file the kernel rejected.
//
// Every marker below is printed only AFTER the step that made it true returned,
// so a gate that greps one cannot pass on a panel that did not do the work.
package main

import (
	"strings"

	"virelai/appkit"
	"virelai/settings"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

const (
	appName  = "GOSET.ELF"
	appTitle = "Settings"
	natW     = 560
	natH     = 360

	markerOpen     = "goset: open id="
	markerDeclare  = "goset: declare accepted"
	markerBad      = "goset: settings bad"
	markerReady    = "goset: ready "
	markerSet      = "goset: set "
	markerDiscard  = "goset: discard "
	markerSaved    = "goset: saved "
	markerRefused  = "goset: save refused"
	markerSaveFail = "goset: save failed rc="
	markerPresent  = "goset: present"
	markerClose    = "goset: close"
	markerOK       = "goset OK"

	// Key codes. ADR 0009 row 1: arg0 is the HID usage, arg1 the decoded
	// symbol byte — the same split user/go/note and user/go/edit read.
	hidLeft  = 0x50
	hidRight = 0x4F
	hidUp    = 0x52
	hidDown  = 0x51

	codeEscape    = 0x1b
	codeBackspace = 0x08
	codeDelete    = 0x7f
	codeReturn    = 0x0d
	codeNewline   = 0x0a

	inputMax = settings.MaxKey + settings.MaxVal + 2
)

type panel struct {
	ta   *tabapp.TabApp
	file settings.File
	disp []settings.Setting
	sel  int
	// input is the typed command line ("wm=tabwm"). Printable bytes only,
	// bounded by inputMax.
	input         string
	status        string
	exitRequested bool

	rowsTxt     widgets.Text
	headTxt     widgets.Text
	inputTxt    widgets.Text
	statusT     widgets.Text
	paletteTxt  widgets.Text
	list        widgets.List
	saveBtn     widgets.Button
	quitBtn     widgets.Button
	paletteSwat [3]widgets.Rect
}

func main() {
	ta := tabapp.Init(tabapp.Config{Name: appName, Title: appTitle, X: 48, Y: 48, W: natW, H: natH})
	if ta == nil {
		vi.ConsoleLine("goset: error open -1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine("goset: declare refused")
	}

	a := newPanel(ta)
	loop := appkit.NewLoop(a.ta, a.draw, a.handle)
	loop.OnInitialPresent = func() { vi.ConsoleLine(markerPresent) }
	loop.OnExit = func(status int) {
		vi.ConsoleLine(markerClose)
		vi.ConsoleLine(markerOK)
		a.ta.CloseAndExit(status)
	}
	loop.ShouldQuit = func() (int, bool) {
		if a.exitRequested {
			return 0, true
		}
		return 0, false
	}
	loop.Run()
}

// newPanel decodes the file, names its verdict, and builds the display table.
// A corrupt file is read-only: the compiled defaults are in force (that is what
// the kernel's refusal means) and every write is refused.
func newPanel(ta *tabapp.TabApp) *panel {
	a := &panel{ta: ta}
	a.file = settings.Load()
	switch a.file.State {
	case settings.StateCorrupt:
		vi.ConsoleLine(markerBad)
		// Show what is in force, not what the file said: the kernel refused
		// the file whole, so the compiled defaults are the live table.
		a.disp = settings.File{State: settings.StateMissing}.Display()
		a.status = "corrupt file: read-only"
	default:
		a.disp = a.file.Display()
		a.status = "type key=value + Enter to save"
	}
	vi.ConsoleLine(markerReady + a.summary() + " mode=" + a.mode())
	// M73m: a file that already chose `custom` shows its colours as rows.
	a.ensurePaletteRows()
	return a
}

// ensurePaletteRows (M73m #1662) grows the display table with the three
// custom-palette rows the moment `custom` is chosen — the colours the user is
// choosing become visible, selectable rows. Idempotent, and it never REMOVES
// a row (a palette written while custom stays visible and saved when the
// theme cycles back: the kernel ignores those keys for any preset, so keeping
// them costs nothing and keeps the user's colours around). While theme is a
// preset the table is untouched, so a default panel still reports keys=8.
func (a *panel) ensurePaletteRows() {
	if theme, _ := settings.Get(a.disp, "theme"); theme != "custom" {
		return
	}
	for _, k := range settings.PaletteKeys {
		if _, ok := settings.Get(a.disp, k.Name); ok {
			continue
		}
		a.disp = append(a.disp, settings.Setting{Key: k.Name, Val: k.Default})
	}
}

// mode is the write verdict for the gate: rw only when a save would be honored.
func (a *panel) mode() string {
	if a.file.State == settings.StateCorrupt {
		return "ro"
	}
	return "rw"
}

// summary is the publishable state of the display table: how many rows it
// carries and the two values the card names (the seat is chosen by `wm`).
func (a *panel) summary() string {
	wm, _ := settings.Get(a.disp, "wm")
	t, _ := settings.Get(a.disp, "theme")
	return "keys=" + vi.Itoa64(int64(len(a.disp))) + " wm=" + wm + " theme=" + t
}

// set applies one edit to the display table and reports it. The value is
// written verbatim — the vocabulary is the panel's help, not a gate: the
// kernel's own reader is the authority on what it will ignore.
func (a *panel) set(key, val string) bool {
	if a.file.State == settings.StateCorrupt {
		vi.ConsoleLine(markerRefused + " " + key)
		return false
	}
	a.disp = settings.Set(a.disp, key, val)
	// Live preview for the one key a running process can act on: the seat
	// reads `theme` at boot, and theme.Set is the same table the panel draws
	// with. Unknown values are refused by theme.Set, so a typo cannot invent
	// a palette (it is still written, and still ignored at the next boot).
	// M73m: `amber`/`custom` are refused the same way — this window keeps its
	// current tokens while the STORE (and the kernel terminal) takes the
	// choice; the swatch band below shows the custom colours either way.
	if key == "theme" {
		_ = theme.Set(val)
	}
	// M73m: choosing `custom` reveals the colour rows it applies to.
	if key == "theme" {
		a.ensurePaletteRows()
	}
	vi.ConsoleLine(markerSet + key + "=" + val)
	return true
}

// applyInput consumes the typed command line: `key=value` for a key the kernel
// table knows. Anything else is named and dropped, never written.
func (a *panel) applyInput() bool {
	if a.input == "" {
		return false
	}
	line := a.input
	a.input = ""
	key, val, hasEq := strings.Cut(line, "=")
	key = strings.TrimSpace(key)
	val = strings.TrimSpace(val)
	if !hasEq || key == "" {
		vi.ConsoleLine(markerDiscard + line)
		return true
	}
	// Known kernel-table key OR one of the custom-palette keys (M73m)...
	if !settings.Editable(key) {
		vi.ConsoleLine(markerDiscard + line)
		return true
	}
	// ...and a palette colour must be six hex digits: a malformed value is
	// named and dropped HERE, before it can reach the file (the kernel
	// refuses the same value again at apply — neither side paints it).
	if settings.IsPaletteKey(key) && !settings.ValidColour(val) {
		a.status = key + ": six hex digits (RRGGBB)"
		vi.ConsoleLine(markerDiscard + line)
		return true
	}
	a.set(key, val)
	return true
}

// save publishes the display table crash-safe. Corrupt is refused (one honest
// line, nothing written); any other negative return is the kernel code of the
// step that failed, and the temp is gone either way.
func (a *panel) save() {
	if a.file.State == settings.StateCorrupt {
		vi.ConsoleLine(markerRefused)
		a.status = "corrupt file: read-only"
		return
	}
	f := settings.File{Rows: a.disp, State: settings.StateOK}
	rc := f.Save()
	if rc == settings.SaveRefused {
		vi.ConsoleLine(markerRefused)
		return
	}
	if rc < 0 {
		vi.ConsoleLine(markerSaveFail + vi.Itoa64(rc))
		a.status = "save failed rc=" + vi.Itoa64(rc)
		return
	}
	a.file = f
	vi.ConsoleLine(markerSaved + a.summary())
	a.status = "saved " + settings.Path
}

// cycle moves the selected row to the next value in its vocabulary. A key with
// no vocabulary (hostname, prompt, scrollback, the palette colours) is left
// alone: the panel does not guess a value space the kernel never declared —
// type those as key=value, exactly like the kernel's own reader.
func (a *panel) cycle(dir int) bool {
	if a.sel < 0 || a.sel >= len(a.disp) {
		return false
	}
	key := a.disp[a.sel].Key
	vocab, ok := settings.Vocab(key)
	if !ok || len(vocab) == 0 {
		if settings.IsPaletteKey(key) {
			a.status = key + ": six hex digits (RRGGBB) + Enter"
		} else {
			a.status = key + ": type a value (key=value)"
		}
		return true
	}
	cur := a.disp[a.sel].Val
	if dir < 0 {
		return a.set(key, prevVocab(vocab, cur))
	}
	return a.set(key, settings.Next(vocab, cur))
}

// prevVocab is the backward step through the same cycle; a value outside the
// vocabulary starts at the end, mirroring settings.Next's start-at-the-top.
func prevVocab(vocab []string, cur string) string {
	for i, v := range vocab {
		if v == cur {
			return vocab[(i+len(vocab)-1)%len(vocab)]
		}
	}
	return vocab[len(vocab)-1]
}

// handle applies one event. It returns whether the frame changed.
func (a *panel) handle(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvKeyDown:
		return a.key(ev)
	case vi.EvMouseDown:
		if ev.Flags&vi.BtnLeft == 0 {
			return false
		}
		x, y := int(ev.Arg0), int(ev.Arg1)
		if a.saveBtn.HitTest(x, y) {
			a.save()
			return true
		}
		if a.quitBtn.HitTest(x, y) {
			a.exitRequested = true
			return true
		}
		if i := a.list.ItemAt(x, y); i >= 0 {
			a.sel = i
			return true
		}
	}
	return false
}

func (a *panel) key(ev vi.Event) bool {
	switch ev.Arg0 {
	case hidUp:
		if a.sel > 0 {
			a.sel--
			return true
		}
		return false
	case hidDown:
		if a.sel+1 < len(a.disp) {
			a.sel++
			return true
		}
		return false
	case hidLeft:
		return a.cycle(-1)
	case hidRight:
		return a.cycle(1)
	}
	switch ev.Arg1 {
	case codeReturn, codeNewline:
		a.applyInput()
		a.save()
		return true
	case codeEscape:
		a.exitRequested = true
		return true
	case codeBackspace, codeDelete:
		if len(a.input) > 0 {
			a.input = a.input[:len(a.input)-1]
			return true
		}
		return false
	}
	if ev.Arg1 >= 0x20 && ev.Arg1 < 0x7f {
		if len(a.input) < inputMax {
			a.input += string(byte(ev.Arg1))
			return true
		}
	}
	return false
}

// --- paint ------------------------------------------------------------------

func (a *panel) layout() {
	ta := a.ta
	w := int(natW) - 16
	a.headTxt = widgets.Text{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 8, W: w, H: 22}),
		Label: "Settings  " + settings.Path,
		Fg:    theme.Current.Text,
		Bg:    theme.Current.Surface,
	}
	// M73m: 18px rows so all ELEVEN rows (the eight defaults + the three
	// palette rows once `custom` is chosen) fit the 200px list — the surface
	// never scrolls a chosen colour off-screen.
	a.list = widgets.List{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 36, W: w, H: 200}),
		Items: a.labels(),
		RowH:  scaleH(ta, 18),
		Sel:   a.sel,
		Fg:    theme.Current.Text,
		Bg:    theme.Current.Bg,
		SelBg: theme.Current.Surface,
	}
	// M73m: the palette band — three swatches + their stored values, drawn
	// under the list so the colours being chosen are visible, not just typed.
	for i := range a.paletteSwat {
		a.paletteSwat[i] = scaleR(ta, widgets.Rect{X: 8 + i*20, Y: 240, W: 16, H: 16})
	}
	fg, bg, accent := a.paletteColours()
	a.paletteTxt = widgets.Text{
		R: scaleR(ta, widgets.Rect{X: 72, Y: 240, W: int(natW) - 80, H: 16}),
		Label: "custom fg=" + paletteHex(fg) + " bg=" + paletteHex(bg) +
			" accent=" + paletteHex(accent),
		Fg: 0xa8b0b8,
		Bg: 0x101418,
	}
	in := a.input
	if in == "" {
		in = "<key=value>"
	}
	a.inputTxt = widgets.Text{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 258, W: w, H: 22}),
		Label: "> " + in,
		Fg:    0xe0e8f0,
		Bg:    0x161c24,
	}
	a.statusT = widgets.Text{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 286, W: w, H: 18}),
		Label: a.status,
		Fg:    0xa8b0b8,
		Bg:    0x101418,
	}
	a.saveBtn = widgets.Button{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 312, W: 88, H: 28}),
		Label: "Save",
	}
	a.quitBtn = widgets.Button{
		R:     scaleR(ta, widgets.Rect{X: int(natW) - 96, Y: 312, W: 88, H: 28}),
		Label: "Close",
	}
}

// labels renders the display table: the value in force for every row, with the
// seat-choosing key first so the row that matters is never off-screen. The
// palette rows (M73m) are first-class — never marked "(kept)", which is the
// marker for a key the kernel table does NOT carry.
func (a *panel) labels() []string {
	out := make([]string, 0, len(a.disp))
	for _, s := range a.disp {
		line := s.Key + " = " + s.Val
		if !settings.Editable(s.Key) {
			line += "  (kept)"
		}
		out = append(out, line)
	}
	return out
}

// paletteColours is the custom palette IN FORCE as RGB: the display table's
// stored six-hex values, else the compiled default for that row (the same
// fallback the kernel applies — a malformed stored value never paints).
func (a *panel) paletteColours() (fg, bg, accent uint32) {
	conv := func(key string) uint32 {
		if v, ok := settings.Get(a.disp, key); ok {
			if c, ok := settings.Colour(v); ok {
				return c
			}
		}
		if k, ok := settings.PaletteKey(key); ok {
			if c, ok := settings.Colour(k.Default); ok {
				return c
			}
		}
		return 0
	}
	return conv("palette_fg"), conv("palette_bg"), conv("palette_accent")
}

// paletteHex formats a 24-bit colour as the six stored digits (lowercase).
func paletteHex(v uint32) string {
	const digits = "0123456789abcdef"
	var b [6]byte
	for i := 5; i >= 0; i-- {
		b[i] = digits[v&0xf]
		v >>= 4
	}
	return string(b[:])
}

func (a *panel) draw() {
	a.layout()
	var f vi.Filler
	f.Rect(a.ta.Win, 0, 0, a.ta.W, a.ta.H, theme.Current.Bg)
	cv := &widgetCanvas{f: &f, win: a.ta.Win}
	a.headTxt.Draw(cv)
	a.list.Draw(cv)
	// M73m: swatch plates — border first, colour inset, so a near-black bg
	// or a near-white fg is still visible against the panel.
	fg, bg, accent := a.paletteColours()
	for i, c := range [3]uint32{fg, bg, accent} {
		r := a.paletteSwat[i]
		cv.FillRect(r, theme.Current.Border)
		cv.FillRect(r.Inset(1), c)
	}
	a.paletteTxt.Draw(cv)
	a.inputTxt.Draw(cv)
	a.statusT.Draw(cv)
	a.saveBtn.Draw(cv)
	a.quitBtn.Draw(cv)
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
