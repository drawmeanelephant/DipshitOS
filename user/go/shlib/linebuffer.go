package shlib

// LineBuffer is the pure, bounded single-line editing core shared by the
// tty editor and GUI text fields. It owns bytes plus a caret; transport
// decoding, history, completion, and repainting stay with their callers.
type LineBuffer struct {
	buf []byte
	cur int
	max int
}

// NewLineBuffer returns an empty buffer bounded to max bytes. A non-positive
// max is unbounded, which is useful for small pure callers and tests.
func NewLineBuffer(max int) LineBuffer {
	return LineBuffer{max: max}
}

// Value returns the current line contents.
func (b *LineBuffer) Value() string { return string(b.buf) }

// Caret returns the byte offset of the insertion point.
func (b *LineBuffer) Caret() int { return b.cur }

// SetValue replaces the line and places the caret at its end. Overlong input
// is clipped to the declared bound, just like an interactive insert.
func (b *LineBuffer) SetValue(s string) {
	if b.max > 0 && len(s) > b.max {
		s = s[:b.max]
	}
	b.buf = append(b.buf[:0], s...)
	b.cur = len(b.buf)
}

// Clear empties the line and resets the caret.
func (b *LineBuffer) Clear() {
	b.buf = b.buf[:0]
	b.cur = 0
}

// InsertByte inserts one byte at the caret. It reports false without changing
// the buffer when the bound would be exceeded.
func (b *LineBuffer) InsertByte(ch byte) bool {
	if b.max > 0 && len(b.buf) >= b.max {
		return false
	}
	b.buf = append(b.buf, 0)
	copy(b.buf[b.cur+1:], b.buf[b.cur:])
	b.buf[b.cur] = ch
	b.cur++
	return true
}

// Backspace removes the byte before the caret.
func (b *LineBuffer) Backspace() bool {
	if b.cur == 0 {
		return false
	}
	b.buf = append(b.buf[:b.cur-1], b.buf[b.cur:]...)
	b.cur--
	return true
}

// Delete removes the byte at the caret.
func (b *LineBuffer) Delete() bool {
	if b.cur >= len(b.buf) {
		return false
	}
	b.buf = append(b.buf[:b.cur], b.buf[b.cur+1:]...)
	return true
}

// Left moves the caret one byte toward the beginning.
func (b *LineBuffer) Left() bool {
	if b.cur == 0 {
		return false
	}
	b.cur--
	return true
}

// Right moves the caret one byte toward the end.
func (b *LineBuffer) Right() bool {
	if b.cur >= len(b.buf) {
		return false
	}
	b.cur++
	return true
}

// Home moves the caret to the beginning.
func (b *LineBuffer) Home() bool {
	if b.cur == 0 {
		return false
	}
	b.cur = 0
	return true
}

// End moves the caret to the end.
func (b *LineBuffer) End() bool {
	if b.cur == len(b.buf) {
		return false
	}
	b.cur = len(b.buf)
	return true
}
