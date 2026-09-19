// The notepad's text buffer, caret and view model: M66c (issue #1445), the Go
// successor to the Zig notepad that #1485 retired.
//
// Deliberately import-free. The editing surface is where the bugs live (line
// joins, column memory across lines, the caret at a clip boundary), so it is
// pure byte-slice work that `go test ./note` exercises on the host — the split
// user/go/calc uses for its engine, and the reason user/go/fart's synthesis
// carries no `math`. The guest runtime's ported surface also stays tiny, which
// is not academic: GOEDIT's header records that pulling the full webrender
// package in blew the kernel's 16-region sbrk budget at runtime init.
//
// This is a notepad, not an editor: no find/replace, no selection, no undo
// (the card's non-goals — GOEDIT owns the arms race).

package main

// MaxBytes is the notepad's own buffer bound. The host file channel would carry
// more; this is a UI limit, and it is what makes "the buffer is full" an
// honest, testable state instead of a guess at how much memory we have.
const MaxBytes = 32 * 1024

// Buffer is the text plus a caret offset. Every edit is a slice operation on
// one backing array that grows to MaxBytes and no further.
type Buffer struct {
	buf []byte
	cur int // caret: a byte offset, 0..len(buf)
}

// NewBuffer returns an empty buffer. The capacity is a first guess, not a
// limit; Insert grows to MaxBytes and then refuses.
func NewBuffer() *Buffer { return &Buffer{buf: make([]byte, 0, 4096)} }

// Len is the text length in bytes.
func (b *Buffer) Len() int { return len(b.buf) }

// Bytes is the text to save. The caller must not mutate it.
func (b *Buffer) Bytes() []byte { return b.buf }

// Cursor is the caret's byte offset, 0..Len inclusive (Len is the insertion
// point after the last byte).
func (b *Buffer) Cursor() int { return b.cur }

// SetCursor moves the caret, clamped into range. Out-of-range is clamped
// rather than refused: the only caller is a resize/relayout path where a
// stale offset is possible and a refusal would strand the caret.
func (b *Buffer) SetCursor(i int) { b.cur = clamp(i, 0, len(b.buf)) }

// Load replaces the text with src and leaves the caret at the start. CRLF
// becomes LF, a bare CR (the old-Mac convention) becomes LF too, and a NUL is
// dropped — it is not text and the frame cannot draw it. So a file from a host
// editor opens with the line structure the frame draws, and a round-trip of
// text this app wrote is byte-stable. Returns the bytes accepted: MaxBytes
// exactly when the file was longer, which the caller reports rather than
// silently truncating.
func (b *Buffer) Load(src []byte) int {
	b.buf = b.buf[:0]
	b.cur = 0
	n := 0
	for i := 0; i < len(src); i++ {
		c := src[i]
		if c == '\r' {
			if i+1 < len(src) && src[i+1] == '\n' {
				continue // the LF of a CRLF pair carries the break
			}
			c = '\n'
		}
		if c == 0 {
			continue
		}
		if n >= MaxBytes {
			break
		}
		b.buf = append(b.buf, c)
		n++
	}
	return n
}

// Insert puts ch at the caret and advances it. It returns false, changing
// nothing, when the buffer is full.
func (b *Buffer) Insert(ch byte) bool {
	if len(b.buf) >= MaxBytes {
		return false
	}
	b.buf = append(b.buf, 0)
	copy(b.buf[b.cur+1:], b.buf[b.cur:])
	b.buf[b.cur] = ch
	b.cur++
	return true
}

// InsertText inserts each byte of s until the buffer is full, returning how
// many went in (a short count is the caller's cue to report the bound).
func (b *Buffer) InsertText(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		if !b.Insert(s[i]) {
			break
		}
		n++
	}
	return n
}

// Newline inserts a line break at the caret.
func (b *Buffer) Newline() bool { return b.Insert('\n') }

// Backspace removes the byte before the caret. At the start of a line that
// byte is the '\n', so the lines join — the caret lands at the end of the
// joined line, which is what a typist expects.
func (b *Buffer) Backspace() bool {
	if b.cur == 0 {
		return false
	}
	copy(b.buf[b.cur-1:], b.buf[b.cur:])
	b.buf = b.buf[:len(b.buf)-1]
	b.cur--
	return true
}

// Delete removes the byte at the caret without moving it.
func (b *Buffer) Delete() bool {
	if b.cur >= len(b.buf) {
		return false
	}
	copy(b.buf[b.cur:], b.buf[b.cur+1:])
	b.buf = b.buf[:len(b.buf)-1]
	return true
}

// Left, Right, Up, Down, Home and End move the caret and report whether they
// moved it, so a key handler can repaint only when something changed. Up and
// Down keep the byte column where the target line is long enough and clamp to
// its end where it is not — the caret never wraps to the next line.
func (b *Buffer) Left() bool {
	if b.cur == 0 {
		return false
	}
	b.cur--
	return true
}

func (b *Buffer) Right() bool {
	if b.cur >= len(b.buf) {
		return false
	}
	b.cur++
	return true
}

func (b *Buffer) Up() bool {
	line := b.Line()
	if line <= 1 {
		return false
	}
	at := b.Col()
	s, e := b.lineBounds(line - 1)
	if at > e-s {
		at = e - s
	}
	b.cur = s + at
	return true
}

func (b *Buffer) Down() bool {
	line := b.Line()
	if line >= b.LineCount() {
		return false
	}
	at := b.Col()
	s, e := b.lineBounds(line + 1)
	if at > e-s {
		at = e - s
	}
	b.cur = s + at
	return true
}

func (b *Buffer) Home() bool {
	s, _ := b.lineBounds(b.Line())
	if b.cur == s {
		return false
	}
	b.cur = s
	return true
}

func (b *Buffer) End() bool {
	_, e := b.lineBounds(b.Line())
	if b.cur == e {
		return false
	}
	b.cur = e
	return true
}

// Line is the 1-based line the caret is on.
func (b *Buffer) Line() int {
	line := 1
	for i := 0; i < b.cur; i++ {
		if b.buf[i] == '\n' {
			line++
		}
	}
	return line
}

// Col is the caret's 0-based byte column within its line.
func (b *Buffer) Col() int {
	start := 0
	for i := 0; i < b.cur; i++ {
		if b.buf[i] == '\n' {
			start = i + 1
		}
	}
	return b.cur - start
}

// LineCount counts lines. A trailing newline opens an (empty) last line, so a
// file ending in '\n' has one more line than it has breaks — the caret can sit
// there and type.
func (b *Buffer) LineCount() int {
	n := 1
	for i := 0; i < len(b.buf); i++ {
		if b.buf[i] == '\n' {
			n++
		}
	}
	return n
}

// lineBounds returns the start and end (exclusive) offsets of 1-based line n.
// Past the last line it returns an empty line at the end of the text, which is
// the same thing the frame draws there.
func (b *Buffer) lineBounds(n int) (int, int) {
	if n < 1 {
		n = 1
	}
	line, start := 1, 0
	for i := 0; i <= len(b.buf); i++ {
		atEnd := i == len(b.buf)
		if !atEnd && b.buf[i] != '\n' {
			continue
		}
		if line == n {
			return start, i
		}
		line++
		start = i + 1
	}
	return len(b.buf), len(b.buf)
}

// Follow returns the scroll top (the 1-based number of the first visible line)
// that keeps the caret's line inside a viewport of rows rows. It is the whole
// vertical-scroll rule as one pure function: it never scrolls past the caret,
// and a resize therefore cannot lose it. top is returned unchanged when the
// caret is already visible.
func (b *Buffer) Follow(top, rows int) int {
	if rows <= 0 {
		return 0
	}
	if top < 1 {
		top = 1
	}
	line := b.Line()
	if line < top {
		return line
	}
	if line >= top+rows {
		return line - rows + 1
	}
	return top
}

// ViewLine is one drawn row.
type ViewLine struct {
	Text string
	Line int // 1-based logical line number
	Col  int // the caret's column on this row, or -1 when the caret is elsewhere
}

// View builds the rows to draw: rows of them starting at 1-based line top,
// each clipped to width columns. A line longer than the viewport is CLIPPED at
// the right edge rather than wrapped — a named limit of this app, recorded in
// docs/testing.md — because wrapping would make one logical line two rows and
// the caret's row a function of the canvas width. The caret is still reported
// in absolute columns by Col(), and `note: cursor` prints those, so nothing
// about the caret is hidden by the clip.
//
// At most rows strings are built, and the scan stops as soon as the window is
// full, so a frame over a large file costs what the viewport costs.
func (b *Buffer) View(top, rows, width int) []ViewLine {
	if top < 1 {
		top = 1
	}
	if rows <= 0 {
		return nil
	}
	out := make([]ViewLine, 0, rows)
	caretLine, caretCol := b.Line(), b.Col()
	line, start := 1, 0
	for i := 0; i <= len(b.buf) && len(out) < rows; i++ {
		atEnd := i == len(b.buf)
		if !atEnd && b.buf[i] != '\n' {
			continue
		}
		if line >= top {
			text := string(b.buf[start:i])
			if width > 0 && len(text) > width {
				text = text[:width]
			}
			vl := ViewLine{Text: text, Line: line, Col: -1}
			if line == caretLine {
				vl.Col = caretCol
			}
			out = append(out, vl)
		}
		line++
		start = i + 1
	}
	return out
}

// clamp is int min/max without importing anything.
func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
