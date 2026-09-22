// GOSH's line editor and session history: a dumb-terminal editor over the
// /dev/tty byte stream. The kernel's tty Screen (ADR 0020 A4) understands
// printable bytes, \r, \b, \t and the CSI pair `ESC[2J`/`ESC[H`, and it
// does NOT echo — so every edit repaints the line with `\r`, overwrites the
// old tail with spaces, and repositions the cursor with a second `\r` +
// prefix, the same discipline the Zig editor (lib/tty.zig) used over this
// seam. Pure code; main.go feeds it tty bytes and writes back what it
// returns. Covered keymap: arrows, Home/End, Delete, Ctrl-A/E/K/U/W/L/C/D,
// Backspace, Tab completion, and Up/Down history.
package shlib

import "strings"

// historyMax is the session history ring bound (SH.BIN kept 16 entries; a
// Go shell can afford more without changing the contract: session-only,
// dup-collapsed, no persistence).
const historyMax = 64

// maxLineBytes bounds one interactive line. The startup contract's per-file
// cap is the same 2048 (main.go maxStartupBytes), so a staged line can never
// trip it. Past it the editor answers with a bell instead of growing the
// buffer -- and the O(n) repaint per keystroke -- without bound.
const maxLineBytes = 2048

// maxSearchQuery bounds one reverse-i-search query. SH.BIN's editor bounded
// its own query buffer; a longer query is simply not extended rather than
// being allowed to grow without limit.
const maxSearchQuery = 64

// History is the recall ring: dup-collapsed, bounded to historyMax, and
// persisted across boots through the share (M69f1 / #1537, History.Load).
// The monitor's HISTORY.TXT is a different file with a different owner; it
// is never read or written from here.
type History struct {
	entries []string
}

// Push appends a submitted line unless it is empty or a dup of the last.
func (h *History) Push(line string) {
	if line == "" {
		return
	}
	if n := len(h.entries); n > 0 && h.entries[n-1] == line {
		return
	}
	h.entries = append(h.entries, line)
	if len(h.entries) > historyMax {
		h.entries = h.entries[len(h.entries)-historyMax:]
	}
}

// Entries returns a copy of the ring in order (oldest first).
func (h *History) Entries() []string {
	out := make([]string, len(h.entries))
	copy(out, h.entries)
	return out
}

// Load seeds the ring from a persisted history file (M69f1 / #1537): UTF-8,
// LF, one command per line, oldest first -- the shape SaveHistory writes.
// Two deliberate tolerances:
//
//   - a truncated last line (no trailing LF, which is what a half-finished
//     append looks like on the share) is SKIPPED rather than costing the
//     whole file, so a single bad append cannot silently erase recall;
//   - each line goes through Push, so an empty or consecutively-duplicated
//     entry is dropped by exactly the rule the live session uses.
func (h *History) Load(data []byte) {
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	if !strings.HasSuffix(text, "\n") {
		i := strings.LastIndexByte(text, '\n')
		if i < 0 {
			return // only a partial line: nothing recoverable
		}
		text = text[:i+1]
	}
	for _, ln := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		h.Push(strings.TrimRight(ln, "\r"))
	}
}

// evKind is what one Feed produced.
type evKind int

const (
	evNone evKind = iota
	EvSubmit
	EvEOF    // Ctrl-D on an empty line
	EvCancel // Ctrl-C: the line was abandoned
)

// EditEvent carries at most one editor outcome per Feed.
type EditEvent struct {
	Kind evKind
	Line string // for EvSubmit, without the newline
}

// editor CSI decode states.
const (
	edGround = iota
	edEsc
	edCSI
)

// Editor is the line editor for one tty session.
type Editor struct {
	prompt   string
	buf      []byte
	cur      int
	hist     *History
	hview    int // -1 = editing the live line
	lastLen  int // painted prompt+line length, for the tail overwrite
	lastTab  bool
	state    int    // edGround / edEsc / edCSI
	csiParam int    // accumulated CSI parameter
	csiGotP  bool   // saw at least one parameter digit
	pending  []byte // unread input after a submit cut a chunk short
	// reverse-i-search (M45 SH3): while searching, every byte feeds the
	// query matcher instead of the line, and the draft line is held so a
	// cancel can put it back. Mirrors user/src/lib/tty.zig's search_* set.
	searching bool
	query     []byte
	draft     []byte
	draftCur  int
	// Complete proposes candidates for the word being completed. first
	// marks the command word (start of the line).
	Complete func(word string, first bool) []string
}

// NewEditor wires an editor over a history ring.
func NewEditor(prompt string, h *History) *Editor {
	return &Editor{prompt: prompt, hist: h, hview: -1}
}

// SetPrompt swaps the prompt (SETTINGS.TXT drives it at startup).
func (e *Editor) SetPrompt(p string) {
	e.prompt = p
	e.lastLen = 0
}

// Repaint renders the current state: the prompt and line from scratch.
func (e *Editor) Repaint() []byte {
	e.lastLen = 0
	return e.paint()
}

// paint composes the repaint: `\r` + prompt + line, spaces over the old
// tail, then `\r` + prompt + the line up to the cursor.
func (e *Editor) paint() []byte {
	content := len(e.prompt) + len(e.buf)
	tail := e.lastLen - content
	if tail < 0 {
		tail = 0
	}
	out := make([]byte, 0, content+tail+2+content)
	out = append(out, '\r')
	out = append(out, e.prompt...)
	out = append(out, e.buf...)
	out = append(out, []byte(strings.Repeat(" ", tail))...)
	out = append(out, '\r')
	out = append(out, e.prompt...)
	out = append(out, e.buf[:e.cur]...)
	e.lastLen = content
	return out
}

// Feed processes the next input chunk and returns the bytes to write back
// to the tty plus at most one event. Input that arrives after a submit in
// the same chunk is held for the next Feed.
func (e *Editor) Feed(chunk []byte) ([]byte, EditEvent) {
	if len(e.pending) > 0 {
		chunk = append(e.pending, chunk...)
		e.pending = nil
	}
	if e.searching {
		// Search mode owns the byte stream (SH.BIN's feed does the same). An
		// accept or cancel ends it mid-chunk, and the REST of the chunk is
		// deferred to the ground loop -- which is what lets a staged
		// `Ctrl+R query CR CR` accept the recall and then submit it.
		var out []byte
		for i := 0; i < len(chunk); i++ {
			w, finished := e.searchByte(chunk[i])
			out = append(out, w...)
			if finished {
				if i+1 < len(chunk) {
					e.pending = append([]byte{}, chunk[i+1:]...)
				}
				return out, EditEvent{}
			}
		}
		return out, EditEvent{}
	}
	var out []byte
	for i := 0; i < len(chunk); i++ {
		b := chunk[i]
		var w []byte
		var ev EditEvent
		switch e.state {
		case edEsc:
			if b == '[' {
				e.state = edCSI
				e.csiParam, e.csiGotP = 0, false
				continue
			}
			// A lone ESC (or ESC followed by anything but '[') is not a
			// sequence this keymap consumes. Drop the ESC and treat THIS byte
			// as ground input: eating it would mean Escape followed by typing
			// a character silently loses the character. The kernel's keymap
			// emits ESC [ X for every arrow/Home/End, so no SS3-style sequence
			// (`ESC O A`) reaches here to be misread as text.
			e.state = edGround
			w, ev = e.keyGround(b)
		case edCSI:
			switch {
			case b >= '0' && b <= '9':
				e.csiParam = e.csiParam*10 + int(b-'0')
				e.csiGotP = true
			case b == '~':
				w, ev = e.keyDelete()
				e.state = edGround
			default:
				// A final byte: A/B/C/D/H/F are the M49 keymap.
				switch b {
				case 'A':
					w, ev = e.histPrev()
				case 'B':
					w, ev = e.histNext()
				case 'C':
					w, ev = e.keyRight()
				case 'D':
					w, ev = e.keyLeft()
				case 'H':
					w, ev = e.keyHome()
				case 'F':
					w, ev = e.keyEnd()
				}
				e.state = edGround
			}
		default:
			w, ev = e.keyGround(b)
		}
		out = append(out, w...)
		if ev.Kind != evNone {
			if i+1 < len(chunk) {
				e.pending = append([]byte{}, chunk[i+1:]...)
			}
			return out, ev
		}
		if e.searching {
			// Ctrl+R took over mid-chunk: the rest of this chunk belongs to
			// the query, not to the line. Defer it (the search branch at the
			// top of Feed consumes it on the next call) — without this, a
			// staged `Ctrl+R status` inserts "status" into the line and
			// searches for nothing.
			if i+1 < len(chunk) {
				e.pending = append([]byte{}, chunk[i+1:]...)
			}
			return out, EditEvent{}
		}
	}
	return out, EditEvent{}
}

// Pending reports whether the editor is still holding input that arrived
// after a submit in the same chunk. Feed returns at most one event per call,
// so a caller that reads a *burst* of bytes (the serial front-end can return
// several whole lines in one read) must keep calling Feed — with a nil chunk
// — until this is false, or the rest of the burst sits unread forever.
func (e *Editor) Pending() bool { return len(e.pending) > 0 }

// -- reverse-i-search (M45 SH3, SH.BIN's search_* semantics) --------------

// searchEnter opens reverse-i-search, saving the draft line for a cancel.
// Returns the paint for the search prompt.
func (e *Editor) searchEnter() []byte {
	e.draft = append(e.draft[:0], e.buf...)
	e.draftCur = e.cur
	e.searching = true
	e.query = e.query[:0]
	return e.searchPaint()
}

// searchPaint renders `(reverse-i-search)`query`: match` and loads the match
// as the live line, so an accept needs no further swap. An empty query shows
// `_` and cannot match, exactly as SH.BIN's redraw does.
func (e *Editor) searchPaint() []byte {
	shown := string(e.query)
	if shown == "" {
		shown = "_"
	}
	out := []byte("\r\n(reverse-i-search)`" + shown + "`: ")
	if m, ok := e.searchMatch(string(e.query)); ok {
		out = append(out, m...)
		e.buf = append(e.buf[:0], m...)
		e.cur = len(e.buf)
	} else {
		out = append(out, "(no match)"...)
	}
	// The search line is its own paint; the next ground paint starts from a
	// clean slate rather than overwriting a tail it never measured.
	e.lastLen = 0
	e.lastTab = false
	return out
}

// searchMatch finds the NEWEST history entry containing query (a substring
// match, newest-first, the same rule SH.BIN used). An empty query matches
// nothing rather than everything.
func (e *Editor) searchMatch(query string) (string, bool) {
	if query == "" || e.hist == nil {
		return "", false
	}
	ents := e.hist.Entries() // oldest first
	for i := len(ents) - 1; i >= 0; i-- {
		if strings.Contains(ents[i], query) {
			return ents[i], true
		}
	}
	return "", false
}

// searchByte handles one byte in search mode, returning the bytes to write
// and whether search mode ended (accept or cancel).
//
// Three bytes are deliberately NOT handled, and the map is one-way on
// purpose: a repeat Ctrl+R (0x12) is IGNORED, so search is newest-match-only
// rather than walking to older hits — `tty.zig`'s search byte handler ignores
// 0x12 in search mode the same way, so there is no walk state to port. Ctrl+G
// (0x07) is ignored too: only Enter/Esc/Ctrl-C leave search mode, in both
// codebases. Every other control byte is not query text.
//
// One deliberate DIVERGENCE from the reference: a full query rings the bell
// (`0x07`) instead of dropping the byte silently, so the bound is visible to
// the person typing. The bound itself is the same (maxSearchQuery).
func (e *Editor) searchByte(b byte) ([]byte, bool) {
	switch {
	case b == 0x1b, b == 0x03: // Esc / Ctrl-C: cancel and restore the draft
		return e.searchExit(false), true
	case b == '\r', b == '\n': // Enter: accept the current match
		return e.searchExit(true), true
	case b == 0x7f, b == 0x08: // Backspace: trim the query
		if n := len(e.query); n > 0 {
			e.query = e.query[:n-1]
			return e.searchPaint(), false
		}
		return nil, false
	case b == 0x0c: // Ctrl-L: ignored inside search (SH.BIN's behavior)
		return nil, false
	case b >= 0x20 && b != 0x7f: // a query byte
		if len(e.query) >= maxSearchQuery {
			return []byte{0x07}, false // query full: bell, no append
		}
		e.query = append(e.query, b)
		return e.searchPaint(), false
	}
	return nil, false // other control bytes are not query text
}

// searchExit leaves search mode. On accept the line keeps whatever the last
// match loaded; on cancel the saved draft comes back. It repaints either way,
// so the caller never has to.
func (e *Editor) searchExit(accept bool) []byte {
	e.searching = false
	if !accept {
		e.buf = append(e.buf[:0], e.draft...)
		e.cur = e.draftCur
	}
	e.lastLen = 0
	return append([]byte("\r\n"), e.paint()...)
}

// keyGround handles one non-CSI byte in the ground state.
func (e *Editor) keyGround(b byte) ([]byte, EditEvent) {
	switch b {
	case 0x1b:
		e.state = edEsc
		return nil, EditEvent{}
	case '\r', '\n':
		line := string(e.buf)
		out := []byte("\r\n")
		e.buf = e.buf[:0]
		e.cur = 0
		e.hview = -1
		e.lastLen = 0
		e.hist.Push(line)
		e.lastTab = false
		// The next prompt is part of the same write so the grid never
		// shows an unprompted line.
		return append(out, e.paint()...), EditEvent{Kind: EvSubmit, Line: line}
	case 0x7f, 0x08: // DEL / backspace
		return e.keyBackspace()
	case 0x01: // Ctrl-A
		return e.keyHome()
	case 0x05: // Ctrl-E
		return e.keyEnd()
	case 0x0b: // Ctrl-K: kill to end
		e.buf = e.buf[:e.cur]
		e.lastTab = false
		return e.paint(), EditEvent{}
	case 0x15: // Ctrl-U: kill to start
		e.buf = append([]byte{}, e.buf[e.cur:]...)
		e.cur = 0
		e.lastTab = false
		return e.paint(), EditEvent{}
	case 0x17: // Ctrl-W: kill the word before the cursor
		j := e.cur
		for j > 0 && e.buf[j-1] == ' ' {
			j--
		}
		for j > 0 && e.buf[j-1] != ' ' {
			j--
		}
		e.buf = append(e.buf[:j], e.buf[e.cur:]...)
		e.cur = j
		e.lastTab = false
		return e.paint(), EditEvent{}
	case 0x0c: // Ctrl-L: clear the screen and repaint
		e.lastTab = false
		return append([]byte("\x1b[2J\x1b[H"), e.paint()...), EditEvent{}
	case 0x12: // Ctrl+R: reverse-i-search through history (M45 SH3)
		return e.searchEnter(), EditEvent{}
	case 0x03: // Ctrl-C: abandon the line
		e.buf = e.buf[:0]
		e.cur = 0
		e.hview = -1
		e.lastLen = 0
		e.lastTab = false
		out := append([]byte("^C\r\n"), e.paint()...)
		return out, EditEvent{Kind: EvCancel}
	case 0x04: // Ctrl-D on an empty line: EOF
		if len(e.buf) == 0 {
			return nil, EditEvent{Kind: EvEOF}
		}
		return nil, EditEvent{}
	case '\t':
		return e.keyTab()
	}
	if b < 0x20 || b >= 0x7f {
		return nil, EditEvent{} // other control bytes are not text
	}
	if len(e.buf) >= maxLineBytes {
		return []byte{0x07}, EditEvent{} // line full: bell, no insert
	}
	// Printable: insert at the cursor.
	e.buf = append(e.buf, 0)
	copy(e.buf[e.cur+1:], e.buf[e.cur:])
	e.buf[e.cur] = b
	e.cur++
	e.lastTab = false
	return e.paint(), EditEvent{}
}

func (e *Editor) keyBackspace() ([]byte, EditEvent) {
	if e.cur == 0 {
		return nil, EditEvent{}
	}
	e.buf = append(e.buf[:e.cur-1], e.buf[e.cur:]...)
	e.cur--
	e.lastTab = false
	return e.paint(), EditEvent{}
}

func (e *Editor) keyDelete() ([]byte, EditEvent) {
	if e.cur < len(e.buf) {
		e.buf = append(e.buf[:e.cur], e.buf[e.cur+1:]...)
		e.lastTab = false
		return e.paint(), EditEvent{}
	}
	return nil, EditEvent{}
}

func (e *Editor) keyLeft() ([]byte, EditEvent) {
	if e.cur > 0 {
		e.cur--
		e.lastTab = false
		return e.paint(), EditEvent{}
	}
	return nil, EditEvent{}
}

func (e *Editor) keyRight() ([]byte, EditEvent) {
	if e.cur < len(e.buf) {
		e.cur++
		e.lastTab = false
		return e.paint(), EditEvent{}
	}
	return nil, EditEvent{}
}

func (e *Editor) keyHome() ([]byte, EditEvent) {
	e.cur = 0
	e.lastTab = false
	return e.paint(), EditEvent{}
}

func (e *Editor) keyEnd() ([]byte, EditEvent) {
	e.cur = len(e.buf)
	e.lastTab = false
	return e.paint(), EditEvent{}
}

// histPrev/histNext walk the history ring. Leaving the live line for the
// ring starts at the newest entry; walking past the oldest returns to it.
func (e *Editor) histPrev() ([]byte, EditEvent) {
	n := len(e.hist.entries)
	if n == 0 {
		return nil, EditEvent{}
	}
	if e.hview == -1 {
		e.hview = n - 1
	} else if e.hview > 0 {
		e.hview--
	}
	e.buf = append(e.buf[:0], e.hist.entries[e.hview]...)
	e.cur = len(e.buf)
	e.lastTab = false
	return e.paint(), EditEvent{}
}

func (e *Editor) histNext() ([]byte, EditEvent) {
	if e.hview == -1 {
		return nil, EditEvent{}
	}
	if e.hview < len(e.hist.entries)-1 {
		e.hview++
		e.buf = append(e.buf[:0], e.hist.entries[e.hview]...)
		e.cur = len(e.buf)
	} else {
		e.hview = -1
		e.buf = e.buf[:0]
		e.cur = 0
	}
	e.lastTab = false
	return e.paint(), EditEvent{}
}

// keyTab completes the word before the cursor from Complete's candidates:
// one candidate completes it outright, several complete to the common
// prefix, and a second Tab with nothing left to add lists the candidates.
func (e *Editor) keyTab() ([]byte, EditEvent) {
	if e.Complete == nil {
		return nil, EditEvent{}
	}
	start := e.cur
	for start > 0 && e.buf[start-1] != ' ' {
		start--
	}
	word := string(e.buf[start:e.cur])
	cands := e.Complete(word, start == 0)
	if len(cands) == 0 {
		e.lastTab = false
		return nil, EditEvent{}
	}
	prefix := commonPrefix(cands)
	if len(prefix) > len(word) {
		return e.ins([]byte(prefix[len(word):]))
	}
	if len(cands) == 1 && strings.HasSuffix(cands[0], " ") {
		// A command candidate: complete it with a trailing space.
		return e.ins([]byte(cands[0][len(word):]))
	}
	if e.lastTab {
		e.lastTab = false
		out := []byte("\r\n" + strings.Join(stripSpaces(cands), "  ") + "\r\n")
		return append(out, e.paint()...), EditEvent{}
	}
	e.lastTab = true
	return []byte{0x07}, EditEvent{} // bell: candidates exist but need another Tab
}

// ins inserts ins at the cursor unless that would pass the line cap, in
// which case it answers with a bell and leaves the line alone.
func (e *Editor) ins(ins []byte) ([]byte, EditEvent) {
	if len(e.buf)+len(ins) > maxLineBytes {
		return []byte{0x07}, EditEvent{}
	}
	e.buf = insertAt(e.buf, e.cur, ins)
	e.cur += len(ins)
	e.lastTab = false
	return e.paint(), EditEvent{}
}

// insertAt inserts ins into buf at index at (0 <= at <= len(buf)).
func insertAt(buf []byte, at int, ins []byte) []byte {
	buf = append(buf, make([]byte, len(ins))...)
	copy(buf[at+len(ins):], buf[at:len(buf)-len(ins)])
	copy(buf[at:], ins)
	return buf
}

// commonPrefix returns the longest common prefix of the candidates.
func commonPrefix(cands []string) string {
	if len(cands) == 0 {
		return ""
	}
	p := cands[0]
	for _, c := range cands[1:] {
		for !strings.HasPrefix(c, p) {
			p = p[:len(p)-1]
			if p == "" {
				return ""
			}
		}
	}
	return p
}

// stripSpaces trims the trailing-space hint each command candidate carries.
func stripSpaces(cands []string) []string {
	out := make([]string, len(cands))
	for i, c := range cands {
		out[i] = strings.TrimSuffix(c, " ")
	}
	return out
}
