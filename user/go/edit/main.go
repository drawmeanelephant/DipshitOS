// Command edit is the M58b (issue #1306) Go editor: open a share file, type
// into a buffer, save it back, and close - full-viewport inside Zig TABWM via
// user/go/tabapp.
//
// M66c follow-on (#1485): the three contracts the Zig NOTEPAD.BIN was the last
// live home for landed here, so the leftover binary could be deleted without
// dropping coverage. GOEDIT is the app M66c's own non-goals named as the owner
// of the editor arms race, and this file is what moved into it:
//
//   - find + goto-line (M20 U3). Ctrl-F opens the find bar, Return searches
//     from the caret and prints `goedit: find '<pat>' hit=N/M`, Ctrl-G opens
//     the goto-line bar and Return prints `goedit: goto line=N offset=O` (or
//     `miss lines=L`) as it moves the caret. The pattern buffer, the match
//     total/ordinal and the line offsets are pure functions with host tests,
//     so the live gate asserts the rules the unit tests pin.
//   - the unsaved-changes dialog client (M42 UX r2, WMS8 Gate 4). The kernel
//     posts WIN_UNSAVED (kind 17) when the user picks Save on a dirty window:
//     this app publishes the buffer and exits. The dialog's other two choices
//     never reach the owner as kind 17 - the kernel closes the window itself,
//     so they arrive as WIN_CLOSE (kind 8), which is the ActionClosed arm. An
//     editor's buffer is published by Ctrl-S or by an explicit Save, never
//     silently by a close; that is the whole point of the dialog.
//
// What did NOT land here, and why: the M14 S3 composition selfdemo (clipboard
// slots 38/39 + an app-timer blink, slot 40). It belongs to the same rehome, but
// this app's data segment is the wrong place for it. kernel/src/exec.zig packs
// argv+envp (256 + 2048 bytes) into the data segment's tail while the Go
// runtime's sbrk heap starts at `memRound(firstmoduledata.end)`, and
// `mmap_collides` extends the data aperture through `argv_end_va`: an image whose
// `mem_size mod 4096 > 1792` has that block straddling the break start, so the
// runtime's FIRST sys_mmap is refused and the app dies with `fatal error:
// runtime: cannot allocate memory` inside mallocinit. Every referenced string
// literal costs 16 bytes of that segment, and this app's budget is 240 bytes
// (measured, not guessed: memsz 0x2f610 mod 4096 = 1552 against the 1792 wall).
// The selfdemo needs ~192 of them, so it lives in a purpose-built probe,
// user/go/compose, whose own budget is ~1 KB. Take this file over the wall and
// the app stops booting, silently.
//
// What this is NOT: EDIT.BIN's feature list. The buffer is a byte slice with a
// caret, find is a forward substring search, and there is no selection, undo,
// replace or syntax highlighting.
//
// The palette stays local (colChromeBg/colPageBg) rather than importing
// webrender's theme: the full webrender package drags in layout + HTML parsing,
// and the Go runtime's init then exceeds the kernel's sbrk region budget
// (observed live as "runtime: cannot allocate memory" in mallocinit).
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

	// M20 U3 rehomed (#1485): the find and goto-line bar results, in the Zig
	// app's exact shape (`find '<pat>' hit=N/M`, `goto line=N offset=O`,
	// `goto line=N miss lines=L`) so the gate that asserted them moved by
	// binary name and marker prefix alone.
	markerFind = "goedit: find '"
	markerGoto = "goedit: goto line="

	// M42 UX r2 / WMS8 Gate 4 rehomed (#1485): the unsaved-changes dialog.
	markerUnsaved = "goedit: win_unsaved"

	// modCtrl is the ADR 0009 Ctrl modifier bit; every chord below tests it.
	modCtrl = uint16(0x0002)
	// keyS/keyF/keyG are the LOWERCASE Unicode codepoints. kernel/src/input.zig
	// puts the derived ASCII char in arg1, and for a Ctrl chord that is the
	// control code ('s' & 0x1f = 0x13), so both spellings are accepted for
	// every chord (the duality the save chord has always handled).
	keyS     = 0x73
	keyCtrlS = 0x13
	keyF     = 0x66
	keyCtrlF = 0x06
	keyG     = 0x67
	keyCtrlG = 0x07
	// backspace/delete/return/escape codepoints (the kernel sends the
	// codepoint in arg1).
	codeBackspace = 0x08
	codeDelete    = 0x7f
	codeReturn    = 0x0d
	codeNewline   = 0x0a
	codeEscape    = 0x1b

	// barMax bounds the find pattern and the goto digits; gotoDigitsMax is the
	// Zig app's 5-digit bound on a goto line number.
	barMax        = 32
	gotoDigitsMax = 5

	// defaultPath is the share fixture the gate seeds.
	defaultPath = "/host/EDIT/SEED.TXT"
	// maxBuffer bounds the buffer to the SDK's file bound.
	maxBuffer = vi.MaxFileBytes
)

// Event kinds the SDK does not name. WIN_UNSAVED (kernel/src/events.zig kind
// 17) carries the unsaved-changes dialog's choice in arg0: 0 save, 1 don't
// save, 2 cancel. vi.EvTimer (9), vi.EvWinClose (8) and vi.EvWinResize (10)
// come from the SDK.
const evWinUnsaved uint16 = 17

// The editor's own palette (the browser's chrome/body tones).
const (
	colChromeBg = uint32(0x11171c)
	colPageBg   = uint32(0x182026)
	colInk      = uint32(0xe6edf3)
	colText     = uint32(0xe6edf3)
	// colCaret is the caret block and colDim the find/goto bar's label.
	colCaret = uint32(0xffd75f)
	colDim   = uint32(0x8b98a8)
)

// inputMode is which surface owns the keyboard: the document, the find bar, or
// the goto-line bar (M20 U3).
type inputMode uint8

const (
	modeEdit inputMode = iota
	modeFind
	modeGoto
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

// editor is the whole app state: the path, the byte buffer, the caret, and the
// dirty flag.
type editor struct {
	ta    *tabapp.TabApp
	path  string
	buf   []byte
	dirty bool
	f     vi.Filler

	// M20 U3: cur is the caret as a byte offset into buf, clamped on every use
	// so a buffer that shrank under it cannot index out of range; mode says
	// which bar owns the keyboard; bar holds that bar's typed text.
	cur  int
	mode inputMode
	bar  []byte
}

func main() {
	args := vi.Args()
	path := defaultPath
	if len(args) > 1 && len(args[1]) > 0 {
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
		// M42 UX r2: the dialog's Save choice is a request to publish the
		// buffer, not a close — handled before the tabapp dispatch, which has
		// no opinion about it.
		if ev.Kind == evWinUnsaved {
			e.unsavedExit(ev)
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
// The caret starts at the END of the buffer, which is what keeps the go-edit
// gate's typed characters appending to the seed exactly as they did before the
// caret existed.
func (e *editor) load() {
	b, rc := vi.ReadFileAll(e.path, maxBuffer)
	if rc < 0 {
		e.buf = nil
		e.cur = 0
		vi.ConsoleLine(markerRead + e.path + " n=0 rc=" + vi.Itoa64(rc))
		return
	}
	e.buf = b
	e.cur = len(b)
	vi.ConsoleLine(markerRead + e.path + " n=" + vi.Itoa64(int64(len(b))))
}

// key feeds one event to the buffer or to the focused bar, and reports whether
// the frame needs a redraw. The bar chords own the keyboard from ANY mode, so
// a Ctrl-G straight after a find's Return opens the goto bar instead of being
// swallowed as text.
func (e *editor) key(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown {
		return false
	}
	if isChord(ev, keyF, keyCtrlF) {
		return e.openBar(modeFind)
	}
	if isChord(ev, keyG, keyCtrlG) {
		return e.openBar(modeGoto)
	}
	switch e.mode {
	case modeFind:
		return e.barKey(ev, e.runFind)
	case modeGoto:
		return e.barKey(ev, e.runGoto)
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

// isChord reports whether ev is the Ctrl chord for a key, accepting either the
// bare codepoint or its derived control code (the duality isSave has always
// handled).
func isChord(ev vi.Event, key, ctrlCode uint32) bool {
	if ev.Kind != vi.EvKeyDown || ev.Flags&modCtrl == 0 {
		return false
	}
	return ev.Arg1 == key || ev.Arg1 == ctrlCode
}

// isSave reports whether the event is the Ctrl-S save chord.
func isSave(ev vi.Event) bool { return isChord(ev, keyS, keyCtrlS) }

// openBar focuses a bar with an empty entry.
func (e *editor) openBar(m inputMode) bool {
	e.mode = m
	e.bar = e.bar[:0]
	return true
}

// barKey handles one key while a bar owns the keyboard: Return runs the bar's
// action and closes it, Escape closes it without one, backspace trims it, and
// printable codepoints append (bounded by barMax).
func (e *editor) barKey(ev vi.Event, run func()) bool {
	if ev.Flags&modCtrl != 0 {
		return false
	}
	if ev.Arg1 == codeEscape {
		e.mode, e.bar = modeEdit, e.bar[:0]
		return true
	}
	if ev.Arg1 == codeReturn || ev.Arg1 == codeNewline {
		run()
		return true
	}
	if ev.Arg1 == codeBackspace || ev.Arg1 == codeDelete {
		if len(e.bar) == 0 {
			return false
		}
		e.bar = e.bar[:len(e.bar)-1]
		return true
	}
	if b, ok := insertionFor(ev); ok && len(e.bar) < barMax {
		e.bar = append(e.bar, b)
		return true
	}
	return false
}

// runFind runs the find bar's Return: search from the caret, move it to the
// match, and report the result. An empty pattern is a no-op with no marker.
func (e *editor) runFind() {
	pat := e.bar
	e.mode, e.bar = modeEdit, e.bar[:0]
	if len(pat) == 0 {
		return
	}
	total, ordinal, off := findFrom(e.buf, pat, e.cur)
	if off < 0 {
		vi.ConsoleLine(findMissMarker(pat))
		return
	}
	e.cur = off
	vi.ConsoleLine(findMarker(pat, ordinal, total))
}

// runGoto runs the goto bar's Return: move the caret to 1-based line n and
// report where that is, or how many lines the buffer actually has. An empty,
// non-digit, zero or over-long entry reports nothing (the Zig app's rule).
func (e *editor) runGoto() {
	digits := e.bar
	e.mode, e.bar = modeEdit, e.bar[:0]
	n, ok := parseLine(digits)
	if !ok {
		return
	}
	off := lineOffset(e.buf, n)
	if off < 0 {
		vi.ConsoleLine(gotoMissMarker(n, countLines(e.buf)))
		return
	}
	e.cur = off
	vi.ConsoleLine(gotoMarker(n, off))
}

// unsavedExit answers the unsaved-changes dialog: arg0 == 0 is the Save choice
// (the only one the kernel posts today; the dialog's other two choices close
// the window in the kernel, so they arrive as WIN_CLOSE and take the
// ActionClosed arm with no write at all). The markers come in the Zig client's
// order - the save reports first, then the dialog response, then the clean
// close - so the gate's stage marker keeps meaning the bytes are on the share.
func (e *editor) unsavedExit(ev vi.Event) {
	if ev.Arg0 == 0 {
		e.save()
	}
	vi.ConsoleLine(markerUnsaved)
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	e.ta.CloseAndExit(0)
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

// insert splices one byte in at the caret and marks the buffer dirty (the
// dirty marker prints once, on the first edit).
func (e *editor) insert(b byte) bool {
	if len(e.buf) >= maxBuffer {
		return false
	}
	e.clampCaret()
	e.buf = append(e.buf, 0)
	copy(e.buf[e.cur+1:], e.buf[e.cur:])
	e.buf[e.cur] = b
	e.cur++
	e.markDirty()
	return true
}

// backspace removes the byte before the caret.
func (e *editor) backspace() bool {
	e.clampCaret()
	if e.cur == 0 {
		return false
	}
	copy(e.buf[e.cur-1:], e.buf[e.cur:])
	e.buf = e.buf[:len(e.buf)-1]
	e.cur--
	e.markDirty()
	return true
}

// clampCaret keeps the caret inside the buffer, so a buffer that shrank under
// it (a host test builds an editor by hand) cannot make an index panic.
func (e *editor) clampCaret() {
	if e.cur < 0 {
		e.cur = 0
	}
	if e.cur > len(e.buf) {
		e.cur = len(e.buf)
	}
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

// findMarker is the find bar's serial result, in the Zig app's exact shape:
// the ordinal is 1-based among all matches.
func findMarker(pat []byte, ordinal, total int) string {
	return markerFind + string(pat) + "' hit=" + vi.Itoa64(int64(ordinal)) + "/" + vi.Itoa64(int64(total))
}

// findMissMarker is the find bar's no-match shape.
func findMissMarker(pat []byte) string {
	return markerFind + string(pat) + "' no-match"
}

// gotoMarker is the goto bar's success shape.
func gotoMarker(line, offset int) string {
	return markerGoto + vi.Itoa64(int64(line)) + " offset=" + vi.Itoa64(int64(offset))
}

// gotoMissMarker is the goto bar's beyond-the-buffer shape.
func gotoMissMarker(line, lines int) string {
	return markerGoto + vi.Itoa64(int64(line)) + " miss lines=" + vi.Itoa64(int64(lines))
}

// findFrom searches buf for pat from byte offset `from`, and returns the
// number of non-overlapping matches, the 1-based ordinal of the match the
// caret lands on, and that match's offset. The first match at or after the
// caret wins; when there is none the search wraps to the FIRST match (the find
// bar's "search again from the top" rule, and what makes Return on a
// single-match document report `hit=1/1`). No match returns -1.
func findFrom(buf, pat []byte, from int) (total, ordinal, off int) {
	off, ordinal = -1, 0
	if len(pat) == 0 || len(pat) > len(buf) {
		return 0, 0, -1
	}
	for i := 0; i+len(pat) <= len(buf); {
		if matchAt(buf, i, pat) {
			total++
			if off < 0 && i >= from {
				off, ordinal = i, total
			}
			i += len(pat)
			continue
		}
		i++
	}
	if off < 0 {
		for i := 0; i+len(pat) <= len(buf); i++ {
			if matchAt(buf, i, pat) {
				return total, 1, i
			}
		}
	}
	return total, ordinal, off
}

// matchAt reports whether pat matches at offset off.
func matchAt(buf []byte, off int, pat []byte) bool {
	if off < 0 || len(pat) == 0 || off+len(pat) > len(buf) {
		return false
	}
	for i := 0; i < len(pat); i++ {
		if buf[off+i] != pat[i] {
			return false
		}
	}
	return true
}

// countLines is the number of '\n'-separated lines. An empty buffer is one
// empty line, and a trailing newline opens a final empty one - the Zig app's
// count_lines rule verbatim, because the goto bar reports it.
func countLines(buf []byte) int {
	n := 1
	for _, b := range buf {
		if b == '\n' {
			n++
		}
	}
	return n
}

// lineOffset is the byte offset where 1-based line n starts (0 for line 1), or
// -1 when the buffer has fewer than n lines.
func lineOffset(buf []byte, n int) int {
	if n < 1 {
		return -1
	}
	if n == 1 {
		return 0
	}
	line := 1
	for i, b := range buf {
		if b != '\n' {
			continue
		}
		line++
		if line == n {
			return i + 1
		}
	}
	return -1
}

// parseLine parses the goto bar's digits as a 1-based line number. Empty,
// non-digit, zero and beyond-the-5-digit-bound entries are refused (the Zig
// app's rule), and a refused entry prints no marker at all: the gate greps
// only the two result shapes.
func parseLine(digits []byte) (int, bool) {
	if len(digits) == 0 || len(digits) > gotoDigitsMax {
		return 0, false
	}
	v := 0
	for _, c := range digits {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int(c-'0')
		if v > 99999 {
			return 0, false
		}
	}
	if v == 0 {
		return 0, false
	}
	return v, true
}

// Layout constants for the frame.
const (
	chromeH    = 24
	lineH      = 10
	maxLines   = 64
	textOrigin = 6
	caretW     = 2
)

// draw repaints the frame: a chrome bar with the path, the buffer line by
// line through the M56e text surface, the caret, and the focused bar's label.
// The fill batcher is flushed once.
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
	caretRow, caretCol := -1, 0
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
		// M20 U3: the caret's cell, so a find or a goto visibly MOVED it.
		if e.cur >= start && e.cur <= i {
			caretRow, caretCol = line, e.cur-start
		}
		y += lineH
		line++
		start = i + 1
	}
	if caretRow >= 0 && caretRow < maxLines {
		e.fill(textOrigin+caretCol*font.Advance(1), chromeH+4+caretRow*lineH, caretW, 8, colCaret)
	}
	if e.mode != modeEdit {
		label := "Find: "
		if e.mode == modeGoto {
			label = "Goto: "
		}
		e.drawText(textOrigin, h-lineH-2, label+string(e.bar), colDim)
	}
	_ = e.f.Flush()
}
