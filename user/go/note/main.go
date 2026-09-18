// Command note is Zig NOTEPAD.BIN's Go successor: M66c (issue #1445). A small
// notepad — open, edit, save — full-viewport inside the tabbed desktop through
// user/go/tabapp, over the M66a-hardened file surface. The card's shape is
// M62h (#1406, CALC.BIN -> GOCALC.ELF) applied to the other leftover binary.
//
// It is deliberately NOT an editor: no find/replace, no selection, no undo.
// GOEDIT.ELF owns that arms race. What this app must have is the three things
// the seat gates assert of a hosted tab — it declares itself tab-aware, it
// relayouts on WIN_RESIZE, and it closes cleanly on WIN_CLOSE — plus load/save.
// The marker names are chosen to mirror the Zig app's (`note: resize relayout`,
// `note: win_close`), because the retarget that deletes NOTEPAD.BIN should be a
// prefix change in the seat specs, not a rewrite of what they assert.
//
// Two deliberate behaviour choices, both recorded here because a retarget has
// to reconcile them with the Zig app's coverage:
//
//   - The file is loaded at STARTUP and saved with Ctrl-S (and automatically on
//     WIN_CLOSE when the buffer is dirty, so a tab that is closed cannot lose
//     what was typed). The Zig notepad drove load/save from buttons; buttons
//     are not part of this card, and auto-save-on-close is the version that
//     cannot lose data.
//   - Long lines are CLIPPED at the right edge rather than wrapped (see
//     Buffer.View). Wrapping would make one logical line two rows, and the
//     caret's row a function of the canvas width.
//
// Non-ASCII input: the event wire carries a decoded symbol byte (ADR 0009), and
// the 8x8 face this app draws with is ASCII, so a codepoint above 0x7e is
// ignored rather than inserted as a byte that cannot be rendered.
//
// Every marker below is printed only AFTER its syscall returned, so a gate
// asserting them can only pass if the app actually ran.
package main

import (
	"virelai/tabapp"
	"virelai/vi"
	"virelai/webrender/font"
)

const (
	appName  = "NOTE.ELF"
	appTitle = "Note"
	natW     = 512
	natH     = 384

	// defaultPath is where the Zig notepad kept its text
	// (user/src/notepad.zig `notes_path`), kept identical so the seat specs'
	// existing share seeding still points at the same file.
	defaultPath = "/host/notes.txt"

	// readMax is one byte OVER the buffer bound: a file that does not fit is
	// then reported as truncated (Buffer.Load returns MaxBytes) instead of
	// silently losing its tail.
	readMax = MaxBytes + 1
)

// Marker vocabulary. Each one is printed only after the call that earns it.
const (
	markerOpen    = "note: open id="
	markerAccept  = "note: declare accepted"
	markerRefuse  = "note: declare refused"
	markerLoaded  = "note: loaded ok n="
	markerMiss    = "note: load miss "
	markerLoadErr = "note: load error "
	markerSaved   = "note: saved ok n="
	markerSaveErr = "note: save error "
	markerCursor  = "note: cursor line="
	markerResize  = "note: resize relayout"
	markerClose   = "note: win_close"
	markerOK      = "note OK"
	markerOpenErr = "note: error open "
)

// Frame geometry and the palette, both matching GOEDIT's frame so the two text
// apps look like the same desktop.
const (
	chromeH    = 24
	lineH      = 10
	textOrigin = 6
	caretW     = 2
	statusH    = 12
)

var (
	colChromeBg = uint32(0x1e2430)
	colPageBg   = uint32(0x101418)
	colInk      = uint32(0xe6edf3)
	colDim      = uint32(0x8b98a8)
	colCaret    = uint32(0xffd75f)
)

// Key codes. ADR 0009 row 1: arg0 is the HID usage / keycode and arg1 is the
// decoded symbol, so the arrows are read from arg0 (as user/src/notepad.zig
// reads them) and printable input from arg1 (as GOEDIT does).
const (
	modCtrl = uint16(0x0002)

	hidRight = 0x4f
	hidLeft  = 0x50
	hidDown  = 0x51
	hidUp    = 0x52

	codeBackspace = 0x08
	codeDelete    = 0x7f
	codeReturn    = 0x0d
	codeNewline   = 0x0a

	// keyS is the lowercase 's' codepoint and keyCtrlS the Ctrl chord's, the
	// same pair GOEDIT's save path documents.
	keyS     = 0x73
	keyCtrlS = 0x13
)

// app is the whole state: the window, the buffer, the scroll top and the dirty
// bit (which the chrome bar shows and the close path acts on).
type app struct {
	ta    *tabapp.TabApp
	buf   *Buffer
	path  string
	top   int
	dirty bool
	f     vi.Filler
}

func main() {
	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	ta := tabapp.Init(tabapp.Config{Name: appName, Title: appTitle, X: 32, Y: 32, W: natW, H: natH})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	a.ta = ta
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerAccept)
	} else {
		// The WM refused the declaration (the shim / WND.BIN path): the app
		// keeps its native presentation, which is the documented no-regression
		// case, not a failure.
		vi.ConsoleLine(markerRefuse)
	}

	vi.ConsoleLine(a.load())
	a.top = a.buf.Follow(a.top, a.rowsIn())
	a.draw()
	vi.ConsoleLine(a.cursorMarker())

	for {
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				// Kernel refusal: nothing to wait for, so stop spinning.
				break
			}
			vi.Sleep(1)
			continue
		}
		switch a.ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			vi.ConsoleLine(markerClose)
			// Dirty text is saved on the way out: a closed tab must not be a
			// lost edit. The marker says what happened either way.
			if a.dirty {
				vi.ConsoleLine(a.save())
			}
			vi.ConsoleLine(markerOK)
			a.ta.CloseAndExit(0)
		case tabapp.ActionResized:
			a.top = a.buf.Follow(a.top, a.rowsIn())
			a.draw()
			vi.ConsoleLine(markerResize)
		case tabapp.ActionNone:
			if a.key(ev) {
				a.dirty = true
				a.top = a.buf.Follow(a.top, a.rowsIn())
				a.draw()
			}
		}
	}
}

// load reads the path into the buffer and returns the marker to print. The
// callers print it; keeping the decision here is what makes the three outcomes
// (read, absent, refused) host-testable, because the host file channel answers
// -ENOSYS and nothing panics.
func (a *app) load() string {
	data, rc := vi.ReadFileAll(a.path, readMax)
	if rc < 0 {
		// A missing file is the ordinary first-run case, not an error: an
		// empty notepad is a working notepad. Anything else is reported.
		if rc == -int64(vi.ErrENOENT) {
			return markerMiss + a.path
		}
		return markerLoadErr + vi.Itoa64(rc) + " " + a.path
	}
	n := a.buf.Load(data)
	if n == MaxBytes && len(data) > MaxBytes {
		// The file did not fit: say so with the bound, rather than presenting a
		// truncated document as the whole one.
		return markerLoaded + vi.Itoa64(int64(n)) + " truncated at " + vi.Itoa64(int64(MaxBytes))
	}
	return markerLoaded + vi.Itoa64(int64(n))
}

// save writes the buffer and returns the marker to print. It is the one place
// the app writes, so the read-only/no-write story for /host is a single call.
//
// M66b (#1444) landed vi.WriteFileSafe (temp + fsync + rename, no in-place
// truncation of the live path) while this app was being written, which is the
// swap the first version of this function pre-committed to: the notepad now
// publishes crash-safe, so a power loss during a Ctrl-S -- or during the
// automatic save on WIN_CLOSE -- cannot leave a half-written notes.txt. A
// short write is impossible by construction, because WriteFileSafe fails
// closed (removes its temp, reports the failing step's rc) instead of
// partially writing, so the marker's byte count is the length of the body that
// was published and there is no longer a partial-write branch to report.
func (a *app) save() string {
	data := a.buf.Bytes()
	if rc := vi.WriteFileSafe(a.path, data); rc < 0 {
		return markerSaveErr + vi.Itoa64(rc) + " " + a.path
	}
	a.dirty = false
	return markerSaved + vi.Itoa64(int64(len(data)))
}

// cursorMarker reports where the caret is. It is printed once at startup and
// after a save, so a run can assert the editing state without a marker per
// keystroke flooding the serial.
func (a *app) cursorMarker() string {
	return markerCursor + vi.Itoa64(int64(a.buf.Line())) + " col=" + vi.Itoa64(int64(a.buf.Col())) +
		" n=" + vi.Itoa64(int64(a.buf.Len()))
}

// rowsIn is how many text rows the canvas holds at the current size. A canvas
// too small for even one row still reports one, so a resize cannot make the
// view model empty and the caret disappear.
func (a *app) rowsIn() int {
	if a.ta == nil {
		return 1
	}
	h := int(a.ta.H)
	if h <= 0 {
		h = natH
	}
	rows := (h - chromeH - statusH) / lineH
	if rows < 1 {
		return 1
	}
	return rows
}

// colsIn is how many columns fit on a row at the current width.
func (a *app) colsIn() int {
	w := natW
	if a.ta != nil && int(a.ta.W) > 0 {
		w = int(a.ta.W)
	}
	cols := (w - 2*textOrigin) / font.Advance(1)
	if cols < 1 {
		return 1
	}
	return cols
}

// key feeds one event to the buffer and reports whether the frame changed.
// Ctrl-S saves; printable symbols insert; Return breaks the line; backspace and
// delete remove; the arrows and Tab move. Every other chord belongs to the WM
// and is left alone.
func (a *app) key(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown {
		return false
	}
	if isSave(ev) {
		vi.ConsoleLine(a.save())
		vi.ConsoleLine(a.cursorMarker())
		return true
	}
	if ev.Flags&modCtrl != 0 {
		return false
	}
	switch ev.Arg0 {
	case hidLeft:
		return a.buf.Left()
	case hidRight:
		return a.buf.Right()
	case hidUp:
		return a.buf.Up()
	case hidDown:
		return a.buf.Down()
	}
	if ev.Arg1 == codeBackspace {
		return a.buf.Backspace()
	}
	if ev.Arg1 == codeDelete {
		return a.buf.Delete()
	}
	if b, ok := insertionFor(ev); ok {
		return a.buf.Insert(b)
	}
	return false
}

// isSave reports whether the event is the Ctrl-S chord. Both spellings of 's'
// are accepted: the kernel puts the decoded symbol in arg1, and a chord can
// arrive as either the control code or the letter depending on the path that
// produced it (GOEDIT accepts both for the same reason).
func isSave(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown || ev.Flags&modCtrl == 0 {
		return false
	}
	return ev.Arg1 == keyCtrlS || ev.Arg1 == keyS
}

// insertionFor maps a key event to the byte it inserts. The kernel puts the
// decoded symbol in arg1 (ADR 0009), so a printable ASCII symbol inserts
// verbatim and Return/Newline become '\n'. Anything outside that range inserts
// nothing — see the file header on non-ASCII input.
func insertionFor(ev vi.Event) (byte, bool) {
	if ev.Kind != vi.EvKeyDown || ev.Flags&modCtrl != 0 {
		return 0, false
	}
	if ev.Arg1 == codeReturn || ev.Arg1 == codeNewline {
		return '\n', true
	}
	if ev.Arg1 >= 0x20 && ev.Arg1 < 0x7f {
		return byte(ev.Arg1), true
	}
	return 0, false
}

// fill is one clamped background rectangle through the kernel fill batcher.
func (a *app) fill(x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 || x < 0 || y < 0 || a.ta == nil {
		return
	}
	a.f.Rect(a.ta.Win, uint32(x), uint32(y), uint32(w), uint32(h), rgb)
}

// drawText paints ASCII with the VirelaiOS 8x8 face (virelai/webrender/font),
// coalescing each row's lit run into one fill. Local on purpose: the full
// webrender package drags in layout and HTML parsing, and GOEDIT's header
// records what that costs — the Go runtime's init then exceeds the kernel's
// 16-region sbrk budget ("runtime: cannot allocate memory" in mallocinit).
func (a *app) drawText(x, y int, text string, rgb uint32) {
	cx := x
	for i := 0; i < len(text); i++ {
		g := font.Glyph8(rune(text[i]))
		for row := 0; row < 8; row++ {
			bits := g[row]
			col := 0
			for col < 8 {
				if bits&(1<<uint(col)) == 0 {
					col++
					continue
				}
				run := 1
				for col+run < 8 && bits&(1<<uint(col+run)) != 0 {
					run++
				}
				a.fill(cx+col, y+row, run, 1, rgb)
				col += run
			}
		}
		cx += font.Advance(1)
	}
}

// draw repaints the frame: chrome bar, the visible text rows, the caret, and a
// status line. One flush at the end — the batcher is the only paint path.
func (a *app) draw() {
	if a.ta == nil {
		return
	}
	w, h := int(a.ta.W), int(a.ta.H)
	if w <= 0 || h <= 0 {
		w, h = natW, natH
	}
	a.fill(0, 0, w, chromeH, colChromeBg)
	a.fill(0, chromeH, w, h-chromeH, colPageBg)

	title := appTitle + "  " + a.path
	if a.dirty {
		title += " *"
	}
	a.drawText(textOrigin, 8, title, colInk)

	rows := a.rowsIn()
	a.top = a.buf.Follow(a.top, rows)
	cols := a.colsIn()
	y := chromeH + 4
	for _, row := range a.buf.View(a.top, rows, cols) {
		a.drawText(textOrigin, y, row.Text, colInk)
		if row.Col >= 0 {
			// The caret, drawn after the glyphs so it is never painted over.
			// A caret past the clip sits on the edge: the clip is the view's
			// right boundary, and hiding the caret there would be worse than
			// showing it at the margin.
			col := row.Col
			if col > cols {
				col = cols
			}
			a.fill(textOrigin+col*font.Advance(1), y, caretW, 8, colCaret)
		}
		y += lineH
	}

	status := "line " + vi.Itoa64(int64(a.buf.Line())) + ":" + vi.Itoa64(int64(a.buf.Col())) +
		"  bytes " + vi.Itoa64(int64(a.buf.Len())) + "/" + vi.Itoa64(int64(MaxBytes))
	a.drawText(textOrigin, h-statusH, status, colDim)
	_ = a.f.Flush()
}
