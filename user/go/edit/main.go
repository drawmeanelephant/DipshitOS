// Command edit is the M58b (issue #1306) Go editor: open a share file, type
// into a buffer, save it back, and close - full-viewport inside Zig TABWM via
// user/go/tabapp. Zig EDIT.BIN / NOTEPAD.BIN stay in place (M60 deletes).
//
// This is deliberately NOT EDIT.BIN's feature list: a usable buffer and a
// save, which is what the card asks for. Rendering is the M56e text surface
// (webrender.DrawText over the kernel fill batcher) - no LIBUI, no new Zig.
//
// Every marker below is printed only AFTER its syscall returned, so the
// go-edit VZ gate's asserts can only pass if the app actually ran.
package main

import (
	"virelai/tabapp"
	"virelai/vi"
	"virelai/webrender/font"
)

const (
	appName  = "GOEDIT.ELF"
	appTitle = "Edit"
	natW     = 512
	natH     = 384

	// The marker lines the class-B gate greps.
	markerOpen    = "goedit: open id="
	markerDeclare = "goedit: declare accepted"
	markerRead    = "goedit: read "
	markerPresent = "goedit: present"
	markerDirty   = "goedit: dirty"
	markerSaved   = "goedit: saved "
	markerSaveErr = "goedit: save error "
	markerClose   = "goedit: close"
	markerOK      = "goedit OK"
	markerOpenErr = "goedit: error open "

	// ADR 0009 event flags: the Ctrl modifier bit (vi.ModCtrl).
	modCtrl = uint16(0x0002)
	// keyS is the LOWERCASE 's' Unicode codepoint; kernel/src/input.zig puts
	// the derived ASCII char in arg1, and for a Ctrl chord that is the control
	// code ('s' & 0x1f = 0x13), so both are accepted as the save chord.
	keyS     = 0x73
	keyCtrlS = 0x13
	// backspace/delete codepoints (the kernel sends the codepoint in arg1).
	codeBackspace = 0x08
	codeDelete    = 0x7f
	codeReturn    = 0x0d
	codeNewline   = 0x0a

	// defaultPath is the share fixture the gate seeds.
	defaultPath = "/host/EDIT/SEED.TXT"
	// maxBuffer bounds the buffer to the SDK's file bound.
	maxBuffer = vi.MaxFileBytes
)

// The editor's own palette (the browser's chrome/body tones).
const (
	colChromeBg = uint32(0x11171c)
	colPageBg   = uint32(0x182026)
	colInk      = uint32(0xe6edf3)
	colText     = uint32(0xe6edf3)
)

// fill is one clamped background rectangle through the kernel fill batcher.
func (e *editor) fill(x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 || x < 0 || y < 0 {
		return
	}
	e.f.Rect(e.ta.Win, uint32(x), uint32(y), uint32(w), uint32(h), rgb)
}

// drawText paints ASCII with the VirelaiOS 8x8 face (virelai/webrender/font),
// coalescing each row's lit run into ONE fill. It is deliberately local: the
// full webrender package drags in layout + HTML parsing, and the Go runtime's
// init then exceeds the kernel's 16-region sbrk budget (observed live as
// "runtime: cannot allocate memory" in mallocinit).
func (e *editor) drawText(x, y int, text string, rgb uint32) {
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
				e.fill(cx+col, y+row, run, 1, rgb)
				col += run
			}
		}
		cx += font.Advance(1)
	}
}

// editor is the whole app state: the path, the byte buffer, and the dirty flag.
type editor struct {
	ta    *tabapp.TabApp
	path  string
	buf   []byte
	dirty bool
	f     vi.Filler
}

func main() {
	path := defaultPath
	if args := vi.Args(); len(args) > 1 && len(args[1]) > 0 {
		path = args[1]
	}

	ta := tabapp.Init(tabapp.Config{
		Name:  appName,
		Title: appTitle,
		X:     32,
		Y:     32,
		W:     natW,
		H:     natH,
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine("goedit: declare refused")
	}

	e := &editor{ta: ta, path: path}
	e.load()
	e.draw()
	ta.Present()
	// The first frame is on the scanout: the gate releases the injected
	// keystrokes on this marker, so the editor is already in its event loop.
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
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			vi.ConsoleLine(markerClose)
			vi.ConsoleLine(markerOK)
			ta.CloseAndExit(0)
		case tabapp.ActionResized:
			e.draw()
			ta.Present()
		case tabapp.ActionNone:
			if e.key(ev) {
				e.draw()
				ta.Present()
			}
		}
	}
}

// load reads the fixture into the buffer. A missing file is not fatal: the
// editor starts on an empty buffer (the create path), which is what a real
// editor does, and the read marker reports the byte count it actually got.
func (e *editor) load() {
	b, rc := vi.ReadFileAll(e.path, maxBuffer)
	if rc < 0 {
		e.buf = nil
		vi.ConsoleLine(markerRead + e.path + " n=0 rc=" + vi.Itoa64(rc))
		return
	}
	e.buf = b
	vi.ConsoleLine(markerRead + e.path + " n=" + vi.Itoa64(int64(len(b))))
}

// key feeds one event to the buffer. Ctrl-S saves; printable codepoints
// insert; backspace/delete remove; Return inserts a newline. Anything else is
// ignored. Returns whether the frame needs a redraw.
func (e *editor) key(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown {
		return false
	}
	if isSave(ev) {
		e.save()
		return true
	}
	if ev.Flags&modCtrl != 0 {
		return false
	}
	if ev.Arg1 == codeBackspace || ev.Arg1 == codeDelete {
		return e.backspace()
	}
	if b, ok := insertionFor(ev); ok {
		return e.insert(b)
	}
	return false
}

// isSave reports whether the event is the Ctrl-S save chord.
func isSave(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown || ev.Flags&modCtrl == 0 {
		return false
	}
	return ev.Arg1 == keyS || ev.Arg1 == keyCtrlS
}

// insertionFor maps a key event to the byte it inserts. The kernel puts the
// Unicode codepoint in arg1 (ADR 0009), so a printable ASCII codepoint is
// inserted verbatim; Return becomes a newline. Anything else inserts nothing.
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

// insert appends one byte and marks the buffer dirty (the dirty marker prints
// once, on the first edit).
func (e *editor) insert(b byte) bool {
	if len(e.buf) >= maxBuffer {
		return false
	}
	e.buf = append(e.buf, b)
	e.markDirty()
	return true
}

// backspace drops the last byte.
func (e *editor) backspace() bool {
	if len(e.buf) == 0 {
		return false
	}
	e.buf = e.buf[:len(e.buf)-1]
	e.markDirty()
	return true
}

func (e *editor) markDirty() {
	if e.dirty {
		return
	}
	e.dirty = true
	vi.ConsoleLine(markerDirty)
}

// save writes the whole buffer back to the path (MODE_CREATE|MODE_WRITE,
// then truncate to the written length so a shorter edit cannot leave a
// tail). FileWrite is one kernel call (capped at 2048 B), so a longer
// buffer is looped. Reports the byte count it wrote.
func (e *editor) save() {
	h, rc := vi.FileOpen(e.path, vi.ModeWrite|vi.ModeCreate)
	if rc < 0 {
		vi.ConsoleLine(markerSaveErr + e.path + " " + vi.Itoa64(rc))
		return
	}
	written := 0
	for written < len(e.buf) {
		n, wrc := vi.FileWrite(uint32(h), e.buf[written:])
		if wrc < 0 || n <= 0 {
			vi.FileClose(uint32(h))
			vi.ConsoleLine(markerSaveErr + e.path + " " + vi.Itoa64(wrc))
			return
		}
		written += n
	}
	if trc := vi.FileTruncate(uint32(h), uint32(written)); trc < 0 {
		vi.FileClose(uint32(h))
		vi.ConsoleLine(markerSaveErr + e.path + " " + vi.Itoa64(trc))
		return
	}
	vi.FileClose(uint32(h))
	e.dirty = false
	vi.ConsoleLine(markerSaved + e.path + " n=" + vi.Itoa64(int64(written)))
}

// Layout constants for the frame.
const (
	chromeH    = 24
	lineH      = 10
	maxLines   = 64
	textOrigin = 6
)

// draw repaints the frame: a chrome bar with the path, then the buffer line by
// line through the M56e text surface. The fill batcher is flushed once.
func (e *editor) draw() {
	w, h := int(e.ta.W), int(e.ta.H)
	if w <= 0 || h <= 0 {
		w, h = natW, natH
	}
	e.fill(0, 0, w, chromeH, colChromeBg)
	e.fill(0, chromeH, w, h-chromeH, colPageBg)
	e.drawText(textOrigin, 8, "Edit  "+e.path, colInk)

	y := chromeH + 4
	line, start := 0, 0
	for i := 0; i <= len(e.buf); i++ {
		if i != len(e.buf) && e.buf[i] != '\n' {
			continue
		}
		if line >= maxLines {
			break
		}
		if i > start {
			e.drawText(textOrigin, y, string(e.buf[start:i]), colText)
		}
		y += lineH
		line++
		start = i + 1
	}
	_ = e.f.Flush()
}
